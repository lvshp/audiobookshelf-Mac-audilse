<p align="center">
  <img src="Packaging/AppIcon.png" width="128" alt="Audilse icon">
</p>

<h1 align="center">Audilse</h1>

<p align="center">在 Mac 上收听你的 Audiobookshelf 书库。</p>

<p align="center">
  <img src="https://img.shields.io/badge/macOS-14%2B-111111?logo=apple" alt="macOS 14 or later">
  <img src="https://img.shields.io/badge/Apple_Silicon-arm64-007AFF" alt="Apple Silicon">
  <img src="https://img.shields.io/badge/Swift-6-F05138?logo=swift&logoColor=white" alt="Swift 6">
</p>

<p align="center">
  <a href="#安装">安装</a> ·
  <a href="#功能">功能</a> ·
  <a href="#从源码构建">从源码构建</a> ·
  <a href="https://github.com/lvshp/audiobookshelf-Mac-audilse/issues">反馈问题</a>
</p>

Audilse 是使用 Swift、SwiftUI 和 AppKit 编写的原生 macOS 客户端，连接你自己的 [Audiobookshelf](https://github.com/advplyr/audiobookshelf) 服务器，支持有声书、播客和电子书。

这是一个独立客户端项目，与 Audiobookshelf 官方没有隶属关系。使用前需要已有的 Audiobookshelf 服务器和账号。

## 功能

- **有声书播放**：在线收听、章节跳转、书签、倍速、睡眠定时和待播队列。
- **离线收听**：下载到 Mac，断网后继续播放；重新联网后同步收听进度。
- **macOS 播放控制**：菜单栏播放器、系统媒体控制，关闭主窗口后继续播放。
- **书库浏览**：封面网格与列表、搜索、排序、筛选，以及作者、系列、集合和播放列表。
- **播客订阅**：搜索节目、添加 RSS、导入导出 OPML、选择单集下载和自动追更。
- **电子书阅读**：EPUB、PDF、CBZ、CBR，以及无 DRM 的 MOBI/AZW3 基础阅读。
- **收听记录**：历史记录、收听统计和年度回顾。
- **内容管理**：编辑元数据、封面、章节和音轨，上传文件，管理书库。
- **服务器管理**：用户与权限、会话、API 密钥、备份、日志及服务器设置。可用操作取决于账号权限。
- **多账号与语言**：切换服务器和账号，支持简体中文与 English。

## 安装

| 项目 | 要求 |
| --- | --- |
| 系统 | macOS 14 或更新版本 |
| 芯片 | Apple Silicon（M 系列） |
| 服务器 | Audiobookshelf 2.26+；功能适配基线为 2.37.1 |

从 [Releases](https://github.com/lvshp/audiobookshelf-Mac-audilse/releases/latest) 下载 Apple Silicon 版 DMG，打开后将 **Audilse.app** 拖入 **Applications（应用程序）**。

安装包采用 ad-hoc 签名，未经过 Apple 公证。首次打开时：

1. 在「应用程序」中双击 Audilse。如果 macOS 提示无法验证开发者或无法检查恶意软件，先关闭提示。
2. 打开「系统设置 → 隐私与安全性」，向下找到 Audilse 的拦截提示，点击「仍要打开」。
3. 按系统提示完成验证，再点击「打开」。之后即可正常双击启动。

操作说明：[Apple 官方帮助](https://support.apple.com/zh-cn/102445)。

## 连接服务器

1. 打开 Audilse，选择 **连接服务器**。
2. 输入服务器地址，例如 `https://books.example.com`。如果使用子路径，请包含完整路径，例如 `https://example.com/audiobookshelf`。
3. 使用服务器账号登录，选择书库即可开始收听。

收听进度通过你的 Audiobookshelf 服务器同步。音频下载到 Mac 后可以离线播放；本机账号凭据加密保存，登录密码不保留。

点击窗口左上角的关闭按钮后，音频会继续播放。可以通过菜单栏图标重新打开窗口；按 `⌘Q` 退出应用。

### 添加播客

在播客书库中点击 **订阅节目**，按名称搜索，或粘贴 RSS 地址。订阅后打开 **管理节目与单集 → RSS 选集**，选择要下载的节目。

播客单集先由 Audiobookshelf 下载到服务器。需要在 Mac 上离线收听时，再下载到本机。「自动检查并下载新单集」用于后续追更。

## 从源码构建

需要完整的 Xcode、Swift 6.1 或更新工具链，以及本项目使用的修补版 VLCKit 3.7.3。VLC 框架和对应源码材料单独提供，不包含在 Git 仓库中，准备方式见 [依赖说明](BUILDING.md#首次准备依赖) 和 [VLC 构建说明](Packaging/VLC/portable/README.md)。

导入已校验的框架后，在项目根目录运行：

```bash
bash scripts/build-app.sh
```

应用生成在 `build/Audilse.app`。生成 DMG：

```bash
bash scripts/package-dmg.sh build/Audilse.app build/delivery
```

运行测试：

```bash
bash scripts/test.sh
```

也可以使用 Xcode 打开 `Audilse.xcodeproj`，选择 `AudilseApp` scheme。

[GitHub Actions](https://github.com/lvshp/audiobookshelf-Mac-audilse/actions/workflows/build-macos.yml) 会运行测试并生成 DMG。构建产物位于成功运行的 **Artifacts** 中，仓库配置方法见 [自动打包说明](BUILDING.md)。

## 反馈与贡献

遇到问题或有功能建议，欢迎提交 [Issue](https://github.com/lvshp/audiobookshelf-Mac-audilse/issues)。请附上 macOS、Audilse 和服务器版本，以及复现步骤；播放问题请注明音频格式和在线／离线状态。日志中请去掉密码、令牌及私人服务器信息。

欢迎提交修复、翻译和界面改进。简体中文和英文的语言资源位于 `Sources/Audilse/Resources/`。

## 许可证

项目原创部分采用 [PolyForm Noncommercial License 1.0.0](LICENSE)，允许按条款进行非商业使用、修改和分发。许可用途及非商业组织的适用范围见 [协议原文](https://polyformproject.org/licenses/noncommercial/1.0.0)。

这是限制商业用途的源码可用许可证，不属于 OSI 认可的开源许可证。历史发布版本以其随附的 LICENSE 为准。

第三方组件遵循各自的许可证，详见 [第三方声明](Packaging/THIRD_PARTY_NOTICES.md)。分发包含 VLC 的应用时，请同时提供 [对应源码与许可材料](Packaging/VLC_DISTRIBUTION.md)。

感谢 [Audiobookshelf](https://github.com/advplyr/audiobookshelf)、[VideoLAN](https://www.videolan.org/)、[GRDB](https://github.com/groue/GRDB.swift)、[Socket.IO-Client-Swift](https://github.com/socketio/socket.io-client-swift) 和 [EPUB.js](https://github.com/futurepress/epub.js) 等项目。
