#include "win32_window.h"

#include <dwmapi.h>
#include <flutter_windows.h>
#include <commctrl.h>
#include <windowsx.h>

#include <algorithm>
#include <cmath>

#include "resource.h"
#include "dpi_diagnostics.h"

namespace {

/// Window attribute that enables dark mode window decorations.
///
/// Redefined in case the developer's machine has a Windows SDK older than
/// version 10.0.22000.0.
/// See: https://docs.microsoft.com/windows/win32/api/dwmapi/ne-dwmapi-dwmwindowattribute
#ifndef DWMWA_USE_IMMERSIVE_DARK_MODE
#define DWMWA_USE_IMMERSIVE_DARK_MODE 20
#endif

constexpr const wchar_t kWindowClassName[] = L"FLUTTER_RUNNER_WIN32_WINDOW";
constexpr UINT kSettingsOutsideClick = WM_APP + 0x37;
constexpr UINT kExplicitExit = WM_APP + 0x38;
// WH_MOUSE_LL invokes the hook on its installing thread. The application has
// one settings host; no callback state crosses the window thread boundary.
thread_local Win32Window* g_settings_mouse_owner = nullptr;

/// Registry key for app theme preference.
///
/// A value of 0 indicates apps should use dark mode. A non-zero or missing
/// value indicates apps should use light mode.
constexpr const wchar_t kGetPreferredBrightnessRegKey[] =
  L"Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize";
constexpr const wchar_t kGetPreferredBrightnessRegValue[] = L"AppsUseLightTheme";

// The number of Win32Window objects that currently exist.
static int g_active_window_count = 0;

class DpiDepthScope {
 public:
  DpiDepthScope(unsigned& depth, bool increment) : depth_(depth), increment_(increment) {
    if (increment_) ++depth_;
  }
  ~DpiDepthScope() { if (increment_) --depth_; }
 private:
  unsigned& depth_;
  bool increment_;
};

using EnableNonClientDpiScaling = BOOL __stdcall(HWND hwnd);

// Scale helper to convert logical scaler values to physical using passed in
// scale factor
int Scale(int source, double scale_factor) {
  return static_cast<int>(std::lround(source * scale_factor));
}

double MonitorScale(HMONITOR monitor) {
  return std::max(1.0, FlutterDesktopGetDpiForMonitor(monitor) / 96.0);
}

HMONITOR PrimaryMonitor() {
  return MonitorFromPoint(POINT{0, 0}, MONITOR_DEFAULTTOPRIMARY);
}

struct DisplaySearch {
  const std::wstring* id;
  HMONITOR result = nullptr;
};

BOOL CALLBACK FindDisplay(HMONITOR monitor, HDC, LPRECT, LPARAM parameter) {
  auto search = reinterpret_cast<DisplaySearch*>(parameter);
  MONITORINFOEXW info{};
  info.cbSize = sizeof(info);
  if (GetMonitorInfoW(monitor, reinterpret_cast<MONITORINFO*>(&info)) &&
      *search->id == info.szDevice) {
    search->result = monitor;
    return FALSE;
  }
  return TRUE;
}

RECT VisibleBounds(RECT desired, HMONITOR monitor, double scale) {
  MONITORINFO info{};
  info.cbSize = sizeof(info);
  if (!GetMonitorInfoW(monitor, &info)) return desired;
  const LONG work_width = info.rcWork.right - info.rcWork.left;
  const LONG work_height = info.rcWork.bottom - info.rcWork.top;
  if (work_width <= 0 || work_height <= 0) return desired;
  const LONG width = std::min(
      work_width, std::max(static_cast<LONG>(Scale(320, scale)),
                           desired.right - desired.left));
  const LONG height = std::min(
      work_height, std::max(static_cast<LONG>(Scale(180, scale)),
                            desired.bottom - desired.top));
  const LONG left = std::clamp(desired.left, info.rcWork.left,
                              info.rcWork.right - width);
  const LONG top = std::clamp(desired.top, info.rcWork.top,
                             info.rcWork.bottom - height);
  return RECT{left, top, left + width, top + height};
}

// Dynamically loads the |EnableNonClientDpiScaling| from the User32 module.
// This API is only needed for PerMonitor V1 awareness mode.
void EnableFullDpiSupportIfAvailable(HWND hwnd) {
  HMODULE user32_module = LoadLibraryA("User32.dll");
  if (!user32_module) {
    return;
  }
  auto enable_non_client_dpi_scaling =
      reinterpret_cast<EnableNonClientDpiScaling*>(
          GetProcAddress(user32_module, "EnableNonClientDpiScaling"));
  if (enable_non_client_dpi_scaling != nullptr) {
    enable_non_client_dpi_scaling(hwnd);
  }
  FreeLibrary(user32_module);
}

}  // namespace

// Manages the Win32Window's window class registration.
class WindowClassRegistrar {
 public:
  ~WindowClassRegistrar() = default;

  // Returns the singleton registrar instance.
  static WindowClassRegistrar* GetInstance() {
    if (!instance_) {
      instance_ = new WindowClassRegistrar();
    }
    return instance_;
  }

  // Returns the name of the window class, registering the class if it hasn't
  // previously been registered.
  const wchar_t* GetWindowClass();

  // Unregisters the window class. Should only be called if there are no
  // instances of the window.
  void UnregisterWindowClass();

 private:
  WindowClassRegistrar() = default;

  static WindowClassRegistrar* instance_;

  bool class_registered_ = false;
};

WindowClassRegistrar* WindowClassRegistrar::instance_ = nullptr;

const wchar_t* WindowClassRegistrar::GetWindowClass() {
  if (!class_registered_) {
    WNDCLASS window_class{};
    window_class.hCursor = LoadCursor(nullptr, IDC_ARROW);
    window_class.lpszClassName = kWindowClassName;
    window_class.style = CS_HREDRAW | CS_VREDRAW;
    window_class.cbClsExtra = 0;
    window_class.cbWndExtra = 0;
    window_class.hInstance = GetModuleHandle(nullptr);
    window_class.hIcon =
        LoadIcon(window_class.hInstance, MAKEINTRESOURCE(IDI_APP_ICON));
    window_class.hbrBackground = 0;
    window_class.lpszMenuName = nullptr;
    window_class.lpfnWndProc = Win32Window::WndProc;
    RegisterClass(&window_class);
    class_registered_ = true;
  }
  return kWindowClassName;
}

void WindowClassRegistrar::UnregisterWindowClass() {
  UnregisterClass(kWindowClassName, nullptr);
  class_registered_ = false;
}

Win32Window::Win32Window() {
  ++g_active_window_count;
}

Win32Window::~Win32Window() {
  --g_active_window_count;
  Destroy();
}

bool Win32Window::Create(const std::wstring& title,
                         const Point& origin,
                         const Size& size,
                         const DpiDiagnostics::Options& diagnostics) {
  Destroy();
  probe_composition_ = DpiProbeComposition::kDefault;
  if (diagnostics.enabled && diagnostics.isolated &&
      (diagnostics.composition == DpiProbeComposition::kOpaqueLayered ||
       diagnostics.composition == DpiProbeComposition::kOpaqueNonLayered)) {
    probe_composition_ = diagnostics.composition;
  }

  const wchar_t* window_class =
      WindowClassRegistrar::GetInstance()->GetWindowClass();

  const POINT target_point = {static_cast<LONG>(origin.x),
                              static_cast<LONG>(origin.y)};
  HMONITOR monitor = MonitorFromPoint(target_point, MONITOR_DEFAULTTONEAREST);
  UINT dpi = FlutterDesktopGetDpiForMonitor(monitor);
  if (dpi == 0) dpi = 96;
  current_dpi_ = dpi;
  logical_width_ = size.width;
  logical_height_ = size.height;
  double scale_factor = dpi / 96.0;

  const DWORD extended_style = WS_EX_TOOLWINDOW |
      (probe_composition_ == DpiProbeComposition::kOpaqueNonLayered ? 0 : WS_EX_LAYERED);
  HWND window = CreateWindowEx(
      extended_style, window_class, title.c_str(),
      WS_POPUP | WS_THICKFRAME | WS_MINIMIZEBOX | WS_CLIPCHILDREN,
      origin.x, origin.y,
      Scale(static_cast<int>(size.width), scale_factor),
      Scale(static_cast<int>(size.height), scale_factor),
      nullptr, nullptr, GetModuleHandle(nullptr), this);

  if (!window) {
    return false;
  }

  UpdateTheme(window);
  // Commit the frameless client rectangle before creating the Flutter child.
  // Otherwise the initial frame can remain cached until the first resize.
  SetWindowPos(window, nullptr, 0, 0, 0, 0,
               SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE |
                   SWP_FRAMECHANGED);
  SetOpacity(0.96);
  ClampToVisibleWorkArea();

  return OnCreate();
}

bool Win32Window::Show() {
  return ShowWindow(window_handle_, SW_SHOWNORMAL);
}

// static
LRESULT CALLBACK Win32Window::WndProc(HWND const window,
                                      UINT const message,
                                      WPARAM const wparam,
                                      LPARAM const lparam) noexcept {
  if (message == WM_NCCREATE) {
    auto window_struct = reinterpret_cast<CREATESTRUCT*>(lparam);
    SetWindowLongPtr(window, GWLP_USERDATA,
                     reinterpret_cast<LONG_PTR>(window_struct->lpCreateParams));

    auto that = static_cast<Win32Window*>(window_struct->lpCreateParams);
    EnableFullDpiSupportIfAvailable(window);
    that->window_handle_ = window;
  } else if (Win32Window* that = GetThisFromHandle(window)) {
    return that->MessageHandler(window, message, wparam, lparam);
  }

  return DefWindowProc(window, message, wparam, lparam);
}

LRESULT
Win32Window::MessageHandler(HWND hwnd,
                            UINT const message,
                            WPARAM const wparam,
                            LPARAM const lparam) noexcept {
  const DpiDepthScope dpi_depth(dpi_message_depth_, message == WM_DPICHANGED);
  RecordDpiMessage(message, wparam, lparam, false);
  switch (message) {
    case WM_CLOSE: {
      // The taskbar close command and Alt+F4 must not bypass draft saving.
      // Keep the host alive until Dart has completed the requested action.
      const auto callback = close_request_;
      if (callback) callback();
      return 0;
    }
    case kExplicitExit:
      DestroyWindow(hwnd);
      return 0;
    case kSettingsOutsideClick: {
      if (wparam != settings_click_generation_) return 0;
      settings_click_pending_ = false;
      if (settings_mode_ && settings_outside_click_ &&
          !HasSettingsModalDialog()) {
        // Copy before invoking: the callback is allowed to close settings.
        const auto callback = settings_outside_click_;
        callback();
      }
      return 0;
    }
    case WM_NCCALCSIZE:
      // Retain the resize style while Flutter paints the complete client area.
      return 0;

    case WM_NCHITTEST:
      return ResizeHitTest(lparam);

    case WM_GETMINMAXINFO: {
      auto info = reinterpret_cast<MINMAXINFO*>(lparam);
      const HMONITOR monitor = MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST);
      // WM_DPICHANGED updates the window DPI before its old rectangle has
      // moved. Looking up that rectangle's monitor can apply the old minimum.
      const double scale = current_dpi_ / 96.0;
      LONG min_width = Scale(320, scale);
      LONG min_height = Scale(settings_mode_ ? 360 : 180, scale);
      MONITORINFO work_area{};
      work_area.cbSize = sizeof(work_area);
      if (GetMonitorInfoW(monitor, &work_area)) {
        min_width = std::min(min_width,
                            work_area.rcWork.right - work_area.rcWork.left);
        min_height = std::min(min_height,
                             work_area.rcWork.bottom - work_area.rcWork.top);
      }
      info->ptMinTrackSize.x = min_width;
      info->ptMinTrackSize.y = min_height;
      return 0;
    }

    case WM_DESTROY:
      window_handle_ = nullptr;
      Destroy();
      if (quit_on_close_) {
        PostQuitMessage(0);
      }
      return 0;

    case WM_GETDPISCALEDSIZE: {
      if (!lparam) return FALSE;
      // An explicit SetWindowPos already supplies target-DPI dimensions. Do
      // not scale that request again when Windows moves it between displays.
      if (!applying_bounds_) {
        *reinterpret_cast<SIZE*>(lparam) =
            ScaledWindowSize(static_cast<UINT>(wparam));
      }
      return TRUE;
    }

    case WM_DPICHANGED: {
      current_dpi_ = LOWORD(wparam);
      if (current_dpi_ == 0) current_dpi_ = 96;
      if (applying_bounds_ || !lparam) return 0;
      RECT suggested = *reinterpret_cast<RECT*>(lparam);
      const SIZE size = ScaledWindowSize(current_dpi_);
      suggested.right = suggested.left + size.cx;
      suggested.bottom = suggested.top + size.cy;
      const RECT visible = VisibleBounds(suggested,
          MonitorFromRect(&suggested, MONITOR_DEFAULTTONEAREST),
          current_dpi_ / 96.0);
      applying_bounds_ = true;
      SetWindowPos(hwnd, nullptr, visible.left, visible.top,
                   visible.right - visible.left, visible.bottom - visible.top,
                   SWP_NOZORDER | SWP_NOACTIVATE);
      applying_bounds_ = false;
      return 0;
    }
    case WM_SIZING: {
      const auto rect = reinterpret_cast<const RECT*>(lparam);
      if (!applying_bounds_ && rect) {
        logical_width_ = (rect->right - rect->left) * 96.0 / current_dpi_;
        logical_height_ = (rect->bottom - rect->top) * 96.0 / current_dpi_;
      }
      return TRUE;
    }
    case WM_SIZE: {
      RECT rect = GetClientArea();
      if (child_content_ != nullptr) {
        // Size and position the child window.
        auto& diagnostics = DpiDiagnostics::Process();
        const auto sample = diagnostics.BeginChildResize(child_content_);
        const BOOL resized = MoveWindow(child_content_, rect.left, rect.top,
            rect.right - rect.left, rect.bottom - rect.top, TRUE);
        diagnostics.EndChildResize(sample, child_content_, rect.right - rect.left,
                                   rect.bottom - rect.top, resized != FALSE);
      }
      return 0;
    }

    case WM_ACTIVATE:
      if (LOWORD(wparam) != WA_INACTIVE && child_content_ != nullptr) {
        SetFocus(child_content_);
      }
      return 0;

    case WM_DWMCOLORIZATIONCOLORCHANGED:
    case WM_DWMCOMPOSITIONCHANGED:
    case WM_THEMECHANGED:
      UpdateTheme(hwnd);
      return 0;

    case WM_DISPLAYCHANGE:
      ClampToVisibleWorkArea();
      return 0;

    case WM_SETTINGCHANGE:
      if (wparam == SPI_SETWORKAREA) ClampToVisibleWorkArea();
      break;
  }

  return DefWindowProc(window_handle_, message, wparam, lparam);
}

void Win32Window::Destroy() {
  StopSettingsMouseHook();
  OnDestroy();

  if (window_handle_) {
    DestroyWindow(window_handle_);
    window_handle_ = nullptr;
  }
  if (g_active_window_count == 0) {
    WindowClassRegistrar::GetInstance()->UnregisterWindowClass();
  }
}

Win32Window* Win32Window::GetThisFromHandle(HWND const window) noexcept {
  return reinterpret_cast<Win32Window*>(
      GetWindowLongPtr(window, GWLP_USERDATA));
}

void Win32Window::SetChildContent(HWND content) {
  child_content_ = content;
  SetParent(content, window_handle_);
  SetWindowSubclass(content, ChildSubclassProc, 1,
                    reinterpret_cast<DWORD_PTR>(this));
  RECT frame = GetClientArea();

  MoveWindow(content, frame.left, frame.top, frame.right - frame.left,
             frame.bottom - frame.top, true);

  SetFocus(child_content_);
}

LRESULT CALLBACK Win32Window::ChildSubclassProc(
    HWND window, UINT message, WPARAM wparam, LPARAM lparam,
    UINT_PTR subclass_id, DWORD_PTR reference_data) {
  auto owner = reinterpret_cast<Win32Window*>(reference_data);
  if (message == WM_PAINT || message == WM_ERASEBKGND) {
    DpiDiagnostics::Process().CountChildPaint(message);
  }
  owner->RecordDpiMessage(message, wparam, lparam, true);
  if (message == WM_NCHITTEST && owner->ResizeHitTest(lparam) != HTCLIENT) {
    return HTTRANSPARENT;
  }
  if (message == WM_NCDESTROY) {
    RemoveWindowSubclass(window, ChildSubclassProc, subclass_id);
  }
  return DefSubclassProc(window, message, wparam, lparam);
}

void Win32Window::RecordDpiMessage(UINT message, WPARAM wparam, LPARAM lparam,
                                  bool child) {
  auto& diagnostics = DpiDiagnostics::Process();
  if (!diagnostics.enabled()) return;
  DpiNativeEvent event;
  UINT message_dpi = 0;
  const RECT* suggested = nullptr;
  switch (message) {
    case WM_DPICHANGED:
      if (child) return;
      event = DpiNativeEvent::kParentDpi;
      message_dpi = LOWORD(wparam);
      suggested = reinterpret_cast<const RECT*>(lparam);
      dpi_trace_click_pending_ = true;
      break;
    case WM_SIZE:
      event = child ? DpiNativeEvent::kChildSize : DpiNativeEvent::kParentSize;
      break;
    case WM_ENTERSIZEMOVE:
      if (child) return;
      event = DpiNativeEvent::kEnterMove;
      dpi_trace_click_pending_ = true;
      break;
    case WM_EXITSIZEMOVE:
      if (child) return;
      event = DpiNativeEvent::kExitMove;
      break;
    case WM_WINDOWPOSCHANGED:
      if (child) return;
      event = DpiNativeEvent::kWindowPosition;
      break;
    case 0x02E2:  // WM_DPICHANGED_BEFOREPARENT
      if (!child) return;
      event = DpiNativeEvent::kChildBeforeParent;
      break;
    case 0x02E3:  // WM_DPICHANGED_AFTERPARENT
      if (!child) return;
      event = DpiNativeEvent::kChildAfterParent;
      break;
    case WM_LBUTTONDOWN:
    case WM_RBUTTONDOWN:
    case WM_MBUTTONDOWN:
    case WM_NCLBUTTONDOWN:
      if (!dpi_trace_click_pending_) return;
      dpi_trace_click_pending_ = false;
      event = DpiNativeEvent::kMouseDown;
      break;
    default:
      return;
  }
  diagnostics.RecordNative(event, window_handle_, child_content_, current_dpi_,
      applying_bounds_, dpi_message_depth_, message_dpi, suggested);
}

LRESULT Win32Window::ResizeHitTest(LPARAM screen_point) const {
  RECT rect{};
  if (!GetWindowRect(window_handle_, &rect)) return HTCLIENT;
  const LONG border = Scale(
      8, MonitorScale(MonitorFromWindow(window_handle_, MONITOR_DEFAULTTONEAREST)));
  const LONG x = GET_X_LPARAM(screen_point);
  const LONG y = GET_Y_LPARAM(screen_point);
  const bool left = x >= rect.left && x < rect.left + border;
  const bool right = x < rect.right && x >= rect.right - border;
  const bool top = y >= rect.top && y < rect.top + border;
  const bool bottom = y < rect.bottom && y >= rect.bottom - border;
  if (top && left) return HTTOPLEFT;
  if (top && right) return HTTOPRIGHT;
  if (bottom && left) return HTBOTTOMLEFT;
  if (bottom && right) return HTBOTTOMRIGHT;
  if (left) return HTLEFT;
  if (right) return HTRIGHT;
  if (top) return HTTOP;
  if (bottom) return HTBOTTOM;
  return HTCLIENT;
}

Win32Window::Bounds Win32Window::GetWindowBounds() const {
  Bounds bounds;
  GetWindowRect(window_handle_, &bounds.rect);
  const HMONITOR monitor =
      MonitorFromWindow(window_handle_, MONITOR_DEFAULTTONEAREST);
  MONITORINFOEXW info{};
  info.cbSize = sizeof(info);
  if (GetMonitorInfoW(monitor, reinterpret_cast<MONITORINFO*>(&info))) {
    bounds.display_id = info.szDevice;
  }
  bounds.scale = current_dpi_ / 96.0;
  return bounds;
}

void Win32Window::ApplyWindowBounds(const Bounds& bounds) {
  ApplyLogicalBounds(bounds,
      (bounds.rect.right - bounds.rect.left) / std::max(0.5, bounds.scale),
      (bounds.rect.bottom - bounds.rect.top) / std::max(0.5, bounds.scale));
}

void Win32Window::ApplyLogicalBounds(const Bounds& bounds, double width,
                                     double height) {
  HMONITOR monitor = nullptr;
  if (!bounds.display_id.empty()) {
    DisplaySearch search{&bounds.display_id};
    EnumDisplayMonitors(nullptr, nullptr, FindDisplay,
                        reinterpret_cast<LPARAM>(&search));
    monitor = search.result;
  } else {
    monitor = MonitorFromRect(&bounds.rect, MONITOR_DEFAULTTONULL);
  }
  // A stale desktop layout can leave saved coordinates beyond every display,
  // even when its former display device name is still enumerated.
  if (!MonitorFromRect(&bounds.rect, MONITOR_DEFAULTTONULL)) {
    monitor = PrimaryMonitor();
  }
  if (!monitor) monitor = PrimaryMonitor();
  logical_width_ = width;
  logical_height_ = height;
  current_dpi_ = static_cast<UINT>(std::lround(MonitorScale(monitor) * 96.0));
  const SIZE size = ScaledWindowSize(current_dpi_);
  RECT desired = bounds.rect;
  desired.right = desired.left + size.cx;
  desired.bottom = desired.top + size.cy;
  const RECT visible = VisibleBounds(desired, monitor, current_dpi_ / 96.0);
  const bool was_applying_bounds = applying_bounds_;
  applying_bounds_ = true;
  SetWindowPos(window_handle_, nullptr, visible.left, visible.top,
               visible.right - visible.left, visible.bottom - visible.top,
               SWP_NOZORDER | SWP_NOACTIVATE);
  applying_bounds_ = was_applying_bounds;
}

void Win32Window::ClampToVisibleWorkArea() {
  RECT current{};
  if (!GetWindowRect(window_handle_, &current)) return;
  HMONITOR monitor = MonitorFromRect(&current, MONITOR_DEFAULTTONULL);
  if (!monitor) monitor = PrimaryMonitor();
  current_dpi_ = static_cast<UINT>(std::lround(MonitorScale(monitor) * 96.0));
  RECT desired = current;
  const SIZE size = ScaledWindowSize(current_dpi_);
  desired.right = desired.left + size.cx;
  desired.bottom = desired.top + size.cy;
  const RECT visible = VisibleBounds(desired, monitor, current_dpi_ / 96.0);
  if (EqualRect(&current, &visible)) return;
  const bool was_applying_bounds = applying_bounds_;
  applying_bounds_ = true;
  SetWindowPos(window_handle_, nullptr, visible.left, visible.top,
               visible.right - visible.left, visible.bottom - visible.top,
               SWP_NOZORDER | SWP_NOACTIVATE);
  applying_bounds_ = was_applying_bounds;
}

SIZE Win32Window::ScaledWindowSize(UINT dpi) const {
  const double scale = (dpi == 0 ? 96 : dpi) / 96.0;
  return SIZE{static_cast<LONG>(std::lround(logical_width_ * scale)),
              static_cast<LONG>(std::lround(logical_height_ * scale))};
}

bool Win32Window::SetAlwaysOnTop(bool enabled) {
  return SetWindowPos(window_handle_, enabled ? HWND_TOPMOST : HWND_NOTOPMOST,
                      0, 0, 0, 0,
                      SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE) != FALSE;
}

bool Win32Window::SetOpacity(double opacity) {
  panel_opacity_ = std::clamp(opacity, 0.4, 1.0);
  return ApplyOpacity();
}

bool Win32Window::ApplyOpacity() {
  if (!window_handle_) return false;
  // The nonlayered probe must never enter redirected layered composition,
  // including when settings or restored configuration reapply their opacity.
  if (probe_composition_ == DpiProbeComposition::kOpaqueNonLayered) return true;
  const bool opaque = settings_mode_ ||
      probe_composition_ == DpiProbeComposition::kOpaqueLayered;
  const auto alpha = static_cast<BYTE>(std::lround(
      (opaque ? 1.0 : panel_opacity_) * 255.0));
  return SetLayeredWindowAttributes(window_handle_, 0, alpha, LWA_ALPHA) != FALSE;
}

void Win32Window::SetSettingsMode(bool enabled) {
  if (enabled == settings_mode_) return;
  StopSettingsMouseHook();
  settings_mode_ = enabled;
  UpdateTaskbarPresence();
  ApplyOpacity();
  if (enabled) {
    panel_bounds_ = GetWindowBounds();
    panel_logical_width_ = logical_width_;
    panel_logical_height_ = logical_height_;
    Bounds settings = panel_bounds_;
    settings.rect.right = settings.rect.left + Scale(920, settings.scale);
    settings.rect.bottom = settings.rect.top + Scale(720, settings.scale);
    ApplyWindowBounds(settings);
    StartSettingsMouseHook();
  } else {
    ApplyLogicalBounds(panel_bounds_, panel_logical_width_, panel_logical_height_);
  }
}

void Win32Window::UpdateTaskbarPresence() {
  if (!window_handle_) return;
  LONG_PTR style = GetWindowLongPtrW(window_handle_, GWL_EXSTYLE);
  const LONG_PTR wanted = settings_mode_ ? WS_EX_APPWINDOW : WS_EX_TOOLWINDOW;
  if ((style & (WS_EX_TOOLWINDOW | WS_EX_APPWINDOW)) == wanted) return;
  // Changing taskbar presence used to hide the window first, which flashed
  // black every time settings opened. Frame-changed alone is enough for the
  // style to take effect; the hide/show pair was a cargo-culted requirement.
  style &= ~(WS_EX_TOOLWINDOW | WS_EX_APPWINDOW);
  style |= wanted;
  SetWindowLongPtrW(window_handle_, GWL_EXSTYLE, style);
  SetWindowPos(window_handle_, nullptr, 0, 0, 0, 0,
      SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE | SWP_FRAMECHANGED);
}

void Win32Window::SetCloseRequestCallback(std::function<void()> callback) {
  close_request_ = std::move(callback);
}

void Win32Window::RequestExit() {
  if (window_handle_) PostMessageW(window_handle_, kExplicitExit, 0, 0);
}

void Win32Window::SetSettingsOutsideClickCallback(std::function<void()> callback) {
  StopSettingsMouseHook();
  settings_outside_click_ = std::move(callback);
  StartSettingsMouseHook();
}

void Win32Window::StartSettingsMouseHook() {
  if (!settings_mode_ || !settings_outside_click_ || !window_handle_ ||
      settings_mouse_hook_) return;
  g_settings_mouse_owner = this;
  settings_mouse_hook_ = SetWindowsHookExW(WH_MOUSE_LL, SettingsMouseProc,
      GetModuleHandleW(nullptr), 0);
  if (!settings_mouse_hook_) g_settings_mouse_owner = nullptr;
}

void Win32Window::StopSettingsMouseHook() {
  ++settings_click_generation_;
  settings_click_pending_ = false;
  if (g_settings_mouse_owner == this) g_settings_mouse_owner = nullptr;
  if (settings_mouse_hook_) {
    UnhookWindowsHookEx(settings_mouse_hook_);
    settings_mouse_hook_ = nullptr;
  }
}

bool Win32Window::HasSettingsModalDialog() const {
  // Windows disables a modal dialog's owner, including native file pickers.
  // This also protects a queued outside click while a dialog is opening.
  return !window_handle_ || !IsWindowEnabled(window_handle_);
}

LRESULT CALLBACK Win32Window::SettingsMouseProc(
    int code, WPARAM wparam, LPARAM lparam) {
  auto owner = g_settings_mouse_owner;
  const bool pressed = wparam == WM_LBUTTONDOWN || wparam == WM_RBUTTONDOWN ||
      wparam == WM_MBUTTONDOWN || wparam == WM_XBUTTONDOWN;
  if (code == HC_ACTION && pressed && lparam && owner &&
      owner->settings_mode_ && !owner->settings_click_pending_ &&
      IsWindowVisible(owner->window_handle_) &&
      !IsIconic(owner->window_handle_) && !owner->HasSettingsModalDialog()) {
    const POINT point = reinterpret_cast<const MSLLHOOKSTRUCT*>(lparam)->pt;
    RECT bounds{};
    if (GetWindowRect(owner->window_handle_, &bounds) && !PtInRect(&bounds, point)) {
      const HWND target = WindowFromPoint(point);
      DWORD process = 0;
      if (target) GetWindowThreadProcessId(target, &process);
      if (target && process != 0 && process != GetCurrentProcessId() &&
          GetAncestor(target, GA_ROOTOWNER) != owner->window_handle_) {
        // Never consume or retain input. Queue only a generation token; all
        // channel work happens after the hook has returned to Windows.
        owner->settings_click_pending_ = PostMessageW(owner->window_handle_,
            kSettingsOutsideClick, owner->settings_click_generation_, 0) != FALSE;
      }
    }
  }
  return CallNextHookEx(nullptr, code, wparam, lparam);
}

bool Win32Window::BeginMoveOrResize(int hit_test) {
  POINT cursor{};
  GetCursorPos(&cursor);
  ReleaseCapture();
  return PostMessage(window_handle_, WM_NCLBUTTONDOWN,
                     static_cast<WPARAM>(hit_test),
                     MAKELPARAM(cursor.x, cursor.y)) != FALSE;
}

RECT Win32Window::GetClientArea() {
  RECT frame;
  GetClientRect(window_handle_, &frame);
  return frame;
}

HWND Win32Window::GetHandle() {
  return window_handle_;
}

void Win32Window::SetQuitOnClose(bool quit_on_close) {
  quit_on_close_ = quit_on_close;
}

bool Win32Window::OnCreate() {
  // No-op; provided for subclasses.
  return true;
}

void Win32Window::OnDestroy() {
  // No-op; provided for subclasses.
}

void Win32Window::UpdateTheme(HWND const window) {
  // Keep WS_THICKFRAME for native resizing, but let Flutter own every pixel
  // of the frame. WM_NCCALCSIZE alone does not control DWM border decoration.
  const DWMNCRENDERINGPOLICY rendering_policy = DWMNCRP_DISABLED;
  DwmSetWindowAttribute(window, DWMWA_NCRENDERING_POLICY,
                        &rendering_policy, sizeof(rendering_policy));

  // Windows 11 has a separate border-color attribute. Its documented numeric
  // value also lets this runner build with older SDKs; Windows 10 ignores it.
  constexpr DWORD kBorderColorAttribute = 34;  // DWMWA_BORDER_COLOR
  constexpr COLORREF kNoBorderColor = 0xFFFFFFFE;  // DWMWA_COLOR_NONE
  DwmSetWindowAttribute(window, kBorderColorAttribute,
                        &kNoBorderColor, sizeof(kNoBorderColor));

  DWORD light_mode;
  DWORD light_mode_size = sizeof(light_mode);
  LSTATUS result = RegGetValue(HKEY_CURRENT_USER, kGetPreferredBrightnessRegKey,
                               kGetPreferredBrightnessRegValue,
                               RRF_RT_REG_DWORD, nullptr, &light_mode,
                               &light_mode_size);

  if (result == ERROR_SUCCESS) {
    BOOL enable_dark_mode = light_mode == 0;
    DwmSetWindowAttribute(window, DWMWA_USE_IMMERSIVE_DARK_MODE,
                          &enable_dark_mode, sizeof(enable_dark_mode));
  }
}
