<div align="center">

<h1>DuoMonitor</h1>
<p>在 Windows 悬浮窗和任务栏实时查看行情与系统状态</p>

[![Release](https://img.shields.io/github/v/release/Jaron-admin/DuoMonitor)](https://github.com/Jaron-admin/DuoMonitor/releases/latest)
[![Downloads](https://img.shields.io/github/downloads/Jaron-admin/DuoMonitor/total)](https://github.com/Jaron-admin/DuoMonitor/releases)
[![License](https://img.shields.io/github/license/Jaron-admin/DuoMonitor)](LICENSE)
![Platform](https://img.shields.io/badge/platform-Windows%2010%2F11-blue)

**简体中文** · [English](README.en.md) · [下载](https://github.com/Jaron-admin/DuoMonitor/releases/latest) · [使用文档](docs/usage.md) · [更新日志](CHANGELOG.md)

</div>

> **界面预览待补充：** 任务栏效果 / 桌面悬浮窗。
<!-- TODO: 用户提供真实截图后，替换文字占位：docs/images/taskbar.png、docs/images/panel.png。 -->

## ✨ 核心功能

- 在任务栏查看 CPU、内存、GPU、网速和磁盘读写等系统指标。
- 在桌面悬浮窗查看加密货币、美股与部分 A 股行情，两处可独立选择内容和布局。
- 自定义 HTTPS JSON API、显示字段和文字模板，与默认行情同时显示。
- 便携免安装，也可选择系统数据目录；API 密钥在本地使用 Windows DPAPI 保护。
- 支持中英文、浅深主题、系统字体、透明度和多列布局。

## 📦 下载与安装

1. 从 [Releases](https://github.com/Jaron-admin/DuoMonitor/releases/latest) 下载 `DuoMonitor-Windows-x64-<版本>.zip`。
2. 解压整个文件夹，保留运行库、`data` 与任务栏辅助程序。
3. 运行 `duomonitor.exe`。

**系统要求：Windows 10/11 x64。目前不支持 macOS / Linux。**

## 🧭 功能详情

右键悬浮窗或托盘图标打开设置；双击悬浮窗隐藏，单击托盘图标恢复。
设置中先选择“悬浮窗”或“任务栏”，再调整关注内容和外观。

行情来源、独立显示布局、自定义 API、系统监测及窗口操作见 [使用文档](docs/usage.md)。

## ❓ 常见问题

### Windows 提示“已保护你的电脑”怎么办？

程序目前未进行代码签名。确认下载来自本仓库，并核对发行页的 SHA-256 后，可点“更多信息 → 仍要运行”。

### 配置和数据存在哪？

默认在程序旁的 `user_data`；“设置 → 导入与数据位置”可切换到 `%APPDATA%\DuoMonitor`。
程序记住所选位置；便携数据随文件夹移动，系统目录的数据独立于程序目录。详见 [数据位置 FAQ](docs/usage.md#storage)。

### 怎么升级而不丢配置？

退出旧版并备份当前数据目录，再完整解压新包。便携模式把 `user_data` 复制到新程序旁；系统模式在新程序中选择原系统数据位置，并点 **不复制，只切换**。
换电脑或 Windows 账户后需要重新输入 API 密钥。详见 [升级与迁移](docs/usage.md#upgrade)。

### 任务栏不显示或显示异常怎么办？

确认设置中已开启任务栏显示，并留出足够空白。当前面向主屏标准 Windows 任务栏；布局无法确认时会暂停显示。
可先使用悬浮窗，再按 [任务栏说明](docs/usage.md#taskbar) 检查设置；反馈问题时附 Windows 版本、缩放比例和截图。

### API Key 安全吗？

密钥请求头使用 Windows DPAPI 加密，配置中保存引用，密钥绑定当前用户和电脑。
普通设置、缓存和日志并非整体加密；分享前请检查内容。详见 [密钥说明](docs/usage.md#secrets)。

## 🛠 从源码构建

使用 Flutter 3.47.7 / Dart 3.13.4 和 Visual Studio C++ 桌面工具链，在 Windows 上运行。低于 3.47 的 Flutter 会因框架内部 API 变更导致编译失败，不要降级：

```powershell
git clone https://github.com/Jaron-admin/DuoMonitor.git
cd DuoMonitor/flutter_app
./tool/build_windows.ps1
```

环境准备、构建参数与测试命令见 [开发文档](flutter_app/README.md)。

## 🤝 参与贡献

欢迎提交 [问题或建议](https://github.com/Jaron-admin/DuoMonitor/issues) 和 PR，开始前请阅读 [贡献指南](CONTRIBUTING.md)。
安全问题请按 [安全政策](SECURITY.md) 私下报告。

## 📄 许可证

[MIT](LICENSE) · 第三方依赖、字体及数据服务说明见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。
