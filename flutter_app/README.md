# DuoMonitor 开发文档

**简体中文** · [English](README.en.md)

安装和日常使用见 [根目录 README](../README.md) 与 [使用文档](../docs/usage.md)。

## 环境与构建

构建使用 Flutter 3.47.7 / Dart 3.13.4、Windows 10/11 x64，以及 Visual Studio 的 C++ 桌面工具、MSVC、CMake 和 Windows SDK。低于 3.47 的 Flutter 会因框架内部 API 变更导致编译失败，换机器时先确认版本。按 [Flutter Windows 配置文档](https://docs.flutter.dev/platform-integration/windows/setup)准备工具链。

```powershell
git clone https://github.com/Jaron-admin/DuoMonitor.git
cd DuoMonitor/flutter_app
flutter pub get
flutter run -d windows
```

代码检查与发布构建：

```powershell
flutter analyze
flutter test
flutter build windows --release
```

生成完整发布包：

```powershell
./tool/build_windows.ps1 -PackageName DuoMonitor-Windows-x64-1.6.0
```

发布目录和 ZIP 写入 `dist/`，包含 `duomonitor.exe`、`duomonitor_taskbar.exe`、中英文使用说明、更新记录、项目许可证和第三方许可文本。脚本从全新暂存目录打包，只复制白名单中的程序、运行库和 Flutter 资源，不复制 `user_data`、日志或测试临时文件；任一必需宿主缺失都会终止打包。目标目录或 ZIP 已存在时会报错，请更换 `-PackageName`，脚本不会覆盖或清空已有程序目录。调试信息保存在独立目录，分享时使用生成的 ZIP。Flutter 未加入 PATH 时，可以传入 `-Flutter` 指定本机 Flutter 命令路径。

公开发布应从中性路径构建，并检查成品中的个人路径和敏感数据。可把源码根目录映射为未占用的盘符（例如 `subst M: <源码根目录>`），在 `M:\flutter_app` 构建；完成后用 `subst M: /D` 移除映射。映射只能减少构建路径暴露，仍需对最终 ZIP 做隐私检查并计算 SHA256。不要把调试符号目录作为发行包上传。

脚本在 Windows 无符号连接权限时，会在项目生成目录创建插件目录连接，无需修改系统开发者模式。构建 macOS/Linux 需要相应平台的开发环境，并补齐平台窗口、受保护存储与字体资源适配。Android/iOS 尚未生成项目。

## 平台开发范围

当前发行包仅面向 Windows 10/11 x64。真实多屏跨 DPI 拖动、屏幕断开恢复等行为还取决于显示器与系统配置。

## 开源协议

DuoMonitor 自有源码使用 [MIT License](../LICENSE)。允许使用、修改、分发和商业使用；分发时请保留版权声明及许可文本。

依赖、图标字体和外部数据分别遵循各自的许可与服务条款，见 [第三方许可说明](../THIRD_PARTY_NOTICES.md)。Windows 发布包保留 Flutter 生成的 `data/flutter_assets/NOTICES.Z`，并附有解压后的 `THIRD_PARTY_LICENSES.txt`。

## 插件链接准备

如果 `flutter pub get` 提示插件需要符号链接权限，执行已有脚本并重试：

```powershell
./tool/prepare_plugin_links.ps1
flutter pub get
```

## 原生检查

原生检查与 Flutter 测试分开运行；将参数替换为实际 MSVC 工具目录：

```powershell
./tool/test_taskbar_host.ps1 -CompilerRoot '<MSVC Tools 版本目录>' -CompileHelper
./tool/test_monitor_channel.ps1 -CompilerRoot '<MSVC Tools 版本目录>'
```

其他脚本位于 `tool/` 和 `windows/runner/tests/`。隐藏窗口与离屏检查不能替代 Explorer、多显示器和缩放的实机验收，相关检查需在获准的桌面环境进行。既有记录见 [验证文档](../docs/verification)。

## 发行文档与校验值

中英文使用说明从 `docs/usage.md` / `docs/usage.en.md` 打包，开发说明不随使用说明分发。`-Flutter` 可指定 Flutter 命令路径；`-PackageName` 例子中的版本取自 `pubspec.yaml`，去掉 `+构建号`。脚本生成 ZIP，不生成 SHA-256；发布工作流或 `Get-FileHash -Algorithm SHA256` 负责计算校验值。

## 目录结构

| 目录 | 用途 |
| --- | --- |
| `lib/app/`、`lib/features/` | 应用和设置界面 |
| `lib/domain/`、`lib/data/` | 数据模型、行情与存储 |
| `lib/platform/` | 平台调用；见 [平台边界](lib/platform/README.md) |
| `lib/l10n/` | 中英文资源 |
| `assets/`、`test/` | 图标等资源及 Flutter 测试 |
| `windows/runner/` | Windows 适配；见 [任务栏说明](windows/runner/TASKBAR.md) |
| `tool/` | 构建与原生检查脚本 |
| `linux/`、`macos/` | 保留、尚不支持的平台骨架 |

贡献流程见 [CONTRIBUTING.md](../CONTRIBUTING.md)。
