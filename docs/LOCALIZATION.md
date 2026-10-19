# 客户端本地化

客户端提供简体中文（`zh-Hans`）和英文（`en`）语言包，文件位于 `Sources/ShelfMac/Resources/<语言>.lproj/Localizable.strings`。默认简体中文；从应用“设置”或“个人设置”的“客户端界面语言”下拉框切换，立即更新界面，重启后保留。

客户端语言使用本机 `ShelfMac.interfaceLanguage` 偏好，与服务器 Web 界面的 `language` 配置无关。书名、作者、描述、服务器自定义名称及服务端返回的任意信息保留原文。语言切换不重建账户、播放或编辑表单状态。

Swift 界面文案通过 `L10n.tr` 读取选定的语言包。包含变量时使用 `L10n.format` 和带位置的占位符，例如 `L10n.format("前进 %1$@ 秒", "30")`。翻译必须保留对应位置及类型的占位符。未知 key 回退为 key；原文作为 key，简体中文包也保留一份完整映射。

静态菜单目录保存原始 key，在 View 显示时才调用 `L10n.tr`；不能在静态初始化时缓存翻译。协议字段、枚举 rawValue、书库及账户身份不参与翻译。两个包进入 SwiftPM 资源 bundle，也复制到应用资源目录，供 SwiftPM 和 Xcode 打包分别读取。

UI 收到公开的认证、凭据、离线存储/同步、阅读、播放及管理错误时，通过 `L10n.error` 按类型翻译客户端文案，动态参数保持原样。已经生成的错误字符串快照不会在之后切换语言时重新翻译；下载记录或播放器内已保存的错误也保留原文。系统错误、服务器消息和解包诊断保持原样，尚未统一为可随语言切换的结构化错误。

`scripts/localize-sources.sh inventory` 使用 SwiftSyntax 检查中文文案及插值；`migrate` 是开发工具，会备份源文件并核验读取后的改动，不应在有其他代理编辑源文件时运行。新增文案应直接遵循已有 `L10n` 写法并维护双语包，避免重复迁移。

验证命令：

```bash
bash scripts/localization-smoke.sh
bash scripts/settings-smoke.sh
```

这些脚本不连接真实服务器。实际窗口语言切换、重启及输入方向的验收记录见 `STATUS.md`；自动检查不能替代原生界面验收。
