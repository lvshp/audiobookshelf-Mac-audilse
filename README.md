# Audisle

使用 Swift、SwiftUI 与 AppKit 开发的 Audiobookshelf macOS 客户端。最低 macOS14，界面以书库与持续收听为中心，支持多服务器账号和本地下载。

Audisle（原 ShelfMac）为源码可用、仅限非商业使用的项目。商业使用需获得相关权利人的另行书面许可，见 [LICENSE](LICENSE)。当前功能及已知待改进见 [实施状态](docs/STATUS.md)，文档入口见 [文档索引](docs/README.md)。

## 自动打包

已提供 GitHub Actions 的 Apple Silicon DMG 自动打包配置，支持 main 推送、v* 标签与手动触发。首次需配置修补版 VLC 依赖归档的下载地址和校验值，见 [自动打包说明](docs/GITHUB_ACTIONS.md)。

## 构建与运行

需要 Xcode 和对应的命令行工具。首次构建需要联网获取固定版本的 Swift 依赖；音频库使用固定 VLCKit3.7.3 基线的本项目修补版，不再自动下载旧官方二进制。

迁移项目时需同时携带 `build/vlc-source-delivery/` 中的源码材料与已验证候选包。首次安装音频依赖时运行：

```bash
/usr/bin/python3 -I scripts/import-patched-vlc.py --source build/vlc-source-delivery/exclusion-candidate-20261015/VLCKit.xcframework --apply
```

该候选框架与当前 `Packaging/VLC/patched-lock.json` 配对；采用记录见 `build/vlc-source-delivery/exclusion-candidate-20261015/HANDOFF.md`。旧 `candidate/` 仅保留为历史材料，不用于当前导入。导入会校验临时副本并备份旧 Vendor。随后构建应用；若原路径应用正在运行，先正常退出，或使用下方独立输出目录：

```bash
bash scripts/build-app.sh
```

应用输出到 `build/Audisle.app`。本机开发可使用 Debug 构建：

```bash
CONFIGURATION=debug bash scripts/build-app.sh
```

保留正在运行的应用并生成待验收包：

```bash
SHELFMAC_APP_PATH="$PWD/build/staging/ShelfMac.app" bash scripts/build-app.sh
```

打包、测试和 Xcode 工程会校验修补版库，缺失或不匹配时停止，不回退旧库。离线源码重建入口与实际验证的工具链见 [构建说明](Packaging/VLC/portable/README.md)，完整材料清单见 [交付说明](docs/VLC_DISTRIBUTION.md)。本机 `build/` 下的大文件不会自动随源码仓库分发；当前没有公开下载地址。

脚本使用本机运行所需的临时（ad-hoc）签名。本项目不做 Developer ID 正式签名、Apple 公证或相应发布流程，这些不是交付验收条件。跨电脑安装时 macOS 可能提示应用未经验证；请按系统提示确认可信来源后打开，不建议关闭系统安全保护。应用尚未公开发布。

也可生成 Xcode 工程，打开 `ShelfMac.xcodeproj`，选择 `ShelfMacApp` scheme：

```bash
python3 scripts/generate-xcode-project.py
```

## 使用

启动后选择“连接服务器”，输入自己的 Audiobookshelf 地址和账号。访问令牌和刷新令牌按账户加密保存在本机，登录密码仅用于认证，项目不包含预置账号或密码。

凭据目录为 `~/Library/Application Support/ShelfMac/Credentials`，目录权限0700、文件0600。加密密钥也保存在该目录；请勿单独删除或移动 `master.key`。本地加密结合文件权限保护其他本机用户的访问，不能防御以同一用户身份运行并能读取目录的软件。新版不访问或迁移旧钥匙串条目，需要重新登录一次。

- 侧栏切换书库、下载、作者、系列、集合、播放列表、历史与统计。
- “现在收听”显示服务器的个性化书架，可切换书库、翻阅每架已返回的内容，以及打开作者、系列、电子书或播放指定单集；离线时使用已有首页缓存。此版单架默认请求10项并标出服务端总数。
- 书库顶部提供排序、筛选、系列折叠、网格/列表和封面外观；每页60项，偏好按账户和书库保存。“进度百分比”先排序完整筛选结果再分页；“进度更新时间”按最近更新排序。搜索使用服务器的独立接口，退出搜索后恢复浏览条件；离线只显示已缓存内容。
- 首页和书库搜索支持书籍、节目、单集、作者、系列、标签、类型及朗读者，可选择当前或全部可访问书库。每类上限可调整，页面保留来源库及部分失败；离线只使用相同查询和上限的缓存。标签等结果打开来源库的临时筛选。服务器不提供搜索总量或稳定分页，详见 [搜索说明](docs/SEARCH.md)。原应用已有部分交互验收，当前验证边界见 [实施状态](docs/STATUS.md)。
- 统计页可选择年份，查看有声书/播客收听时长、收听次数、完成书籍及年度排名；累计与年度数据分别加载。个人年度回顾提供四种 PNG 版式，服务器管理提供年度统计、当前存储和三种回顾版式，可保存、复制或打开系统分享菜单；范围与上游限制见 [年度回顾](docs/YEAR_IN_REVIEW.md)。
- 书籍详情可以播放、下载、定位章节、管理书签或打开电子书。
- 详情支持圆形关闭按钮与 `Esc`。长章节、单集和文件列表每页显示80行，可直接选页；读取详情或准备列表期间显示加载提示。
- 完整下载完成后可离线收听。回网时同步本地收听记录；遇到其他设备更新进度时，由用户选择继续位置。
- 主窗口保留原生红黄绿按钮。点击红叉仅关闭窗口，正在播放的音频继续运行。
- 系统菜单栏耳机图标提供播放/暂停、后退/前进、倍速（可在设置中调整）、停止并同步、重新打开窗口与退出。
- 从 Dock 再次打开应用也可恢复主窗口。选择“退出”或按 `⌘Q` 才结束应用，退出前保存最后进度。
- 在“设置”或“个人设置”中选择客户端界面语言，支持简体中文和 English，即时生效并保存在此 Mac。它与管理员设置的服务器 Web 界面语言分别保存。
- 设置中的固定选项使用下拉菜单；服务器语言、日期/时间格式、备份计划、封面来源等保留原有协议值。已有自定义值不会因打开设置而被替换；普通、安全及多行输入统一从左侧显示；修复邻近表单变化后数值框重新靠右的问题。

后台播放会保持应用的播放活动；系统睡眠仍遵循 macOS 设置。

## 验证

```bash
bash scripts/test.sh
```

脚本为播放测试配置显式导入且校验通过的修补版 VLCKit 框架，不需要全局安装 VLC。

书库分页、离线缓存、账户隔离与偏好恢复的真实模型回归：

```bash
bash scripts/library-browser-smoke.sh
```

累计与年度统计的部分失败、切年和账户隔离回归：

```bash
bash scripts/statistics-smoke.sh
```

先运行测试命令生成匹配的 Debug 核心库；此脚本使用本机请求夹具，不连接真实服务器。

语言包、语言持久化与设置选项回归：

```bash
bash scripts/localization-smoke.sh
bash scripts/settings-smoke.sh
```

语言资源与新增翻译方法见 [本地化说明](docs/LOCALIZATION.md)。

本地正文阅读 smoke：

```bash
bash scripts/reader-smoke.sh
```

此脚本生成临时 EPUB、MOBI6 和 KF8/AZW3，并验证本地 WebKit 正文、目录、搜索与阅读位置。

六格式解析与阅读缓存验证：

```bash
bash scripts/reader-formats-smoke.sh
```

额外传入 `--live` 可在预先准备的本机官方2.37.1临时服务验证下载、禁网新进程恢复、同步与冲突；它依赖临时服务fixture配置，不连接用户真实服务器。CBR样本是RAR5 stored，Kindle样本无DRM。

本机播客合成书库由 `scripts/podcast-fixtures.py` 准备，供原应用订阅、选集和队列验收；它只接受专用回环测试服务，不改用户服务器。

本地真实音频引擎 smoke（需要 macOS 音频设备访问）：

```bash
bash scripts/audio-smoke.sh
```

真实服务联调、不同格式、离线闭环和系统版本的验收情况单独记录在实施状态中，单元测试通过不代表全部场景已通过。

## 技术与授权

核心使用 URLSession、Swift actors、GRDB 和 Socket.IO。在线音频使用 AVFoundation，原件下载后的格式兼容使用 VLCKit；阅读使用 PDFKit、libarchive 与本地 WebKit 资源。

项目原创代码使用 Audisle Noncommercial License 1.0，见 [LICENSE](LICENSE)。第三方组件保留各自授权，见 [第三方声明](docs/THIRD_PARTY_NOTICES.md)。

固定 VLCKit/libVLC 源码、上游补丁和 contrib 获取/校验流程见 [VLC 发布材料](docs/VLC_DISTRIBUTION.md)。`scripts/vlc-source-kit.sh` 生成的 INCOMPLETE 审查包属于早期材料，不能替代当前交付清单。当前修补框架已采用，已识别的来源与通知补件已有独立审查；具体源码、修改记录、许可适用范围与保留限制以该说明为准。应用已按确认范围完成本地交付验收，未公开发布；Apple 公证不在本项目范围内。

## 应用名称与兼容标识

应用品牌为Audisle。Swift模块/可执行文件、bundle ID `app.shelfmac.client`、本地Application Support/ShelfMac目录及`shelfmac://oauth`回调保留既有内部标识，避免改名破坏认证、数据分区或OIDC配置。图标原稿为Packaging/AppIcon.png，通过scripts/generate-icon.swift与iconutil生成ICNS。
