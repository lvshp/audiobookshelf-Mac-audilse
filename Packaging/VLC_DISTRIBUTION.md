# VLCKit 对应源码与交付材料

更新：2026-10-19。本文说明 Audilse 发布包采用的 VLC 配置、源码材料、许可通知及重建方式。应用要求 macOS 14 或更新版本；兼容性修复不代表已经完成 macOS 14 实机验收。

## 当前框架

- 未签名原始框架 SHA-256：`0154996b41d7aa98910c8aed104c914aaa0fff07050701bed2c6d14388aa66e8`。完整包、架构切片及文件身份以 `Packaging/VLC/patched-lock.json` 为准；应用内签名会改变 Mach-O 字节。
- 固定源码：VLCKit 提交 `319ed2c0724e3d4c4d34889a62fef1ae269491bc`；VLC 基线 `79128878ddb2c280bbb6c89c76a46b31a80ade1c`，保留 47 个上游补丁及 Audilse copy-drain 修改。
- 运行时身份：`3.0.23 Vetinari` / `3.0.23-shelf-copy-drain-input1-0-g536397a`。配方和包哈希区分同源码的构建配置。
- 构建配方 SHA-256：`197a9627824da239d7264034f2fbee5a56000882067755ad7b3b4c8a0d19c889`。macOS 配置禁用 `pipe2` 探测，采用 VLC 现有的 `pipe` 与 close-on-exec 回退；每个架构检查不得导入 `_pipe2`。
- 插件排除配置保留两架构各 232 个注册插件；排除此前识别的 8 个 GPL 源相关插件、SFTP/libssh2 和两个 Chromecast 插件，保留 transcode/smem 及 PCM/HTTPS 所需模块。历史源码归档包含被排除组件，不表示它们仍被链接。

## 对应源码与重建

发布附件中的 VLC 依赖归档包含 `VLCKit.xcframework` 和 `vlc-source-delivery/`；与项目源码一起保留后，可按以下入口检查与重建：

1. `vlc-source-delivery/SourceMaterials.tar` 与 `SourceMaterialManifest.json` 提供固定原始及准备源码、47 个上游补丁、本项目 copy-drain 修改、62 份依赖归档和来源清单。SourceMaterials.tar SHA-256 为 `74c0155c93ddf1bb7312048c25a56e9693f2e86f7c68289f3a829ff0f38e489d`。
2. `vlc-source-delivery/macos14-compat-20261019/` 提供本次框架、`BuildReceipt.json`、`adopted-recipe/`、`AdoptedRecipeManifest.json` 及 `CompatibilityReuse.json`。采用后的配方与锁用于本次重建和验证；较早目录保留历史证据。
3. 项目 `Packaging/VLC/portable/README.md` 说明离线重建、candidate lock 生成和成对替换框架与锁的流程。使用全新工作目录；构建入口默认仅检查参数，显式 `--run` 才执行构建。
4. 项目 `scripts/import-patched-vlc.py` 默认验证包；显式 `--apply` 校验暂存副本、备份旧 Vendor 并替换。不要绕过校验或用旧锁接受新字节。不同工具链与路径可能产生不同二进制，不承诺跨环境逐字节复现。

同固定源码重建后若字节改变，可用 `scripts/create-patched-vlc-lock.py` 生成独立 candidate lock，检查源码、构建日志和实际运行证据后将已审锁与框架成对采用。若改变 VLC 源码，应记录补丁、源码身份及相应运行时预期。项目不额外限制用户为调试库修改进行的修改或逆向工程。

## 许可原文、适用范围与修改记录

VLCKit 的 LGPL 正文不覆盖所有静态依赖的许可。插件排除配置的 60 个 contrib 库映射到 44 个来源包，构建选包为 45 项（存在同源别名）。历史逐项适用表位于 `vlc-source-delivery/license-audit/final-applicability-candidate/FinalApplicability.json`；本次构建与该表的复用关系、身份及差异由 `macos14-compat-20261019/CompatibilityReuse.json` 记录，不将旧二进制证据冒作本次实测。

- FreeType 2.13.1 选择 FTL；软件基于 FreeType Team 的工作。完整 FTL、原许可选择说明、二进制致谢及 BDF/PCF/fthash/ft-hb 原文均保留。实际 pkg-config 字段修改见 `final-applicability-candidate/source-distribution/FREETYPE-CHANGES.md` 与两架构 diff。
- FFmpeg 的 IJG 原头和二进制致谢保留；历史 6a/v4 完整 README、比较来源及修改 diff 位于 `license-audit/ijg-source-closure-20261015/`。它们是有依据的比较版本，不宣称唯一导入 revision。
- BLAKE2 采用 CC0；soxr PFFFT/Ooura、ebml utf8-cpp、HarfBuzz ms-use/Unicode、FriBidi Unicode、libxml2 hash/list 等内嵌例外保留各自原文与适用证据。Unicode V3 标明为当前官方授权文本，不冒称历史归档原附文本。
- VLC `revmodel.hpp` 与 `transcode.h` 的模块范围来源补证位于 `license-audit/vlc-header-provenance/`，依据官方重授权、历史拆分/导入关系和原 Freeverb 来源；这不构成对整个框架的法律保证。

应用 `Contents/Resources/` 包含本文、`THIRD_PARTY_NOTICES.md`、项目 LICENSE 和完整 `Licenses/`，其中有 123 份 VLC-Contrib 通知及独立的 3 份 VLC-Modules 来源材料。Reader 许可随 Reader 资源保留。源码归档位于发布附件，不宣称包含在应用内部。

分发时保留项目源码、构建脚本及完整 `vlc-source-delivery/`，包括采用后的配方/锁、来源归档、修改记录、适用表和补充证据。只有应用和上游链接不能替代这些对应材料。各第三方许可独立适用，项目原创代码许可不取代或限制它们。
