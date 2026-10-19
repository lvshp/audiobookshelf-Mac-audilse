# GitHub Actions 自动打包

工作流：`.github/workflows/build-macos.yml`。推送到 `main`、推送 `v*` 标签或手动 Run workflow 时执行；只有文档变更的分支推送会跳过。使用 GitHub 的 `macos-26` Apple Silicon runner，运行 Core/Playback 测试、构建 Release、生成并校验 arm64 DMG。默认 runner 的完整 Xcode 工具链必须支持 Swift tools 6.1 或以上。

不需要 Apple Developer 证书或公证凭据。产物使用 ad-hoc 签名，存为 Actions artifact，保留30天；v* 标签构建成功后自动创建 GitHub Release。构建任务仅申请仓库读取权限，标签发布任务单独申请 contents: write。

## 首次准备依赖

修补版 VLCKit 不在 Git 中，也没有内置公开下载地址。必须提供本项目已经验证的依赖包，不能替换为官方旧二进制。

在具有当前 Vendor 和 build/vlc-source-delivery 的本机项目目录运行：

```bash
python3 scripts/ci-vlc-bundle.py create
```

生成 `build/ci-inputs/Audilse-vlc-dependencies.tar.gz` 和 `.sha256` 文件。包内含经过 patched-lock 校验的未重新签名 XCFramework，以及完整本地 VLC 对应源码、补丁和许可材料。脚本拒绝覆盖已有包；需要更新时先移走旧包。

1. 将该归档上传到你控制的 HTTPS 下载位置（例如专门的 GitHub Release 附件或对象存储）。链接必须能直接下载文件；私有位置可使用有效期足够长的签名 URL。这里需要人工上传，不会把本机材料自动发布。
2. 在仓库 **Settings → Secrets and variables → Actions** 中设置：

   | 类型 | 名称 | 内容 |
   |---|---|---|
   | Secret | `VLC_BUNDLE_URL` | 依赖归档的 HTTPS 下载链接 |
   | Variable | `VLC_BUNDLE_SHA256` | 脚本输出的64位小写 SHA-256 |

3. 将项目提交、推送到 GitHub，进入 **Actions → Build Audilse for Apple Silicon → Run workflow**。手动运行选择版本标签时也会在构建成功后发布 Release。

整个归档先校验 SHA-256 再解包；随后框架逐文件、架构切片及对应源码再次按仓库 lock 校验；补充源码/许可和采用后的构建配方按 ci-materials-lock.json 逐文件核对。URL 只用于下载自己生成的归档；不要为未知来源归档填写校验值。配置缺失或依赖不匹配会明确失败，不会生成缺少 VLC 的应用。

## 取回安装包

成功运行后，下载页面底部 `Audilse-arm64-运行编号` 附件，包含：

- `Audilse-版本-build编号-arm64.dmg` 及 SHA-256。
- 当前 checkout 的 `Audilse-source.tar.gz`、源码校验值、项目 LICENSE 与第三方声明。
- `Audilse-vlc-dependencies.tar.gz`：对应的 VLC 框架与源码交付材料。

保留完整附件，分发时按 VLC_DISTRIBUTION.md 同时提供必要源码和许可材料。应用版本取自 Packaging/Info.plist；打新版本前更新版本号和 build 编号，tag 本身不会覆盖它们。GitHub 自带的源码下载不含被忽略的 Vendor/build 目录。

## 本地复用打包

```bash
bash scripts/build-app.sh
bash scripts/package-dmg.sh build/Audilse.app build/delivery
```

本地脚本也会验证严格签名及主程序 arm64，并为 DMG生成校验文件。GitHub 的真实执行结果以 Actions 日志为准；本机静态检查和打包检查不能替代 runner 上运行。
