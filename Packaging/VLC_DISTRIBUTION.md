# VLCKit 对应源码与交付材料

更新：2026-10-16。本说明适用于ShelfMac当前源码采用的插件排除配置；它记录材料与交付状态，不声明全部功能或法律合规已经完成。正式Developer ID签名、Apple公证及公开发布按用户要求不纳入；对应源码与许可原文可随本地项目交付，不要求另建公开托管站点。

## 当前版本与通知状态

| 对象 | 当前事实 |
| --- | --- |
| 项目Vendor及正式框架锁 | 已配对采用新配置；未签名原始框架SHA-256为`2b2a63528e3f26549c0cdc3e5a15843a9636c10c559d26376402a779e555d011` |
| 固定源码 | VLCKit提交`319ed2c0724e3d4c4d34889a62fef1ae269491bc`；VLC基线`79128878ddb2c280bbb6c89c76a46b31a80ade1c`，保留47个上游补丁及ShelfMac copy-drain修改 |
| 运行时身份 | `3.0.23 Vetinari` / `3.0.23-shelf-copy-drain-input1-0-g536397a`；配置变体另由recipe/policy/包哈希区分，不靠不变的changeset冒充不同源码版本 |
| 新实际输入 | 两架构各232插件、295静态输入路径；60个contrib库来自44来源包，构建选包45项（存在同源别名） |
| 通知源 | `Packaging/Licenses/VLC-Contrib/`现有123份，含已独审整合的最终12补件和3份IJG材料 |
| 当前原路径应用 | 已采用排除配置框架、123份VLC-Contrib通知及独立3份VLC-Modules材料；当前包身份、部署与核验记录见当前交付检查点（本地记录：`CURRENT_CHECKPOINT.md`） |
| 历史新框架暂存输入 | `9fe17df361592d742f7a33c7b30f3544893e631aee7d71f3de1e96df79183cda`，含108份contrib通知，当时未部署；本9fe输入副本仍为108份，保留为资源更新前检查点 |

历史资源更新产物c915为`build/staging-vlc-notices/ShelfMac.app`：从9fe输入复制，仅更新许可与两文档，含123份contrib和3份VLC-Modules材料，不重新编译。当时原路径73c应用未因此替换，c915也未单独部署；这些是该次资源更新的历史状态，不代表当前部署状态。资源与临时签名/字节差异记录见随项目`build/release-evidence/vlc-notices-resource-20261015/ResourceUpdate.json`。

签名会改变Mach-O字节；包内签后加载证据与未签名框架hash分别保存。最新包身份与部署状态统一以随项目的当前交付检查点（本地记录：`CURRENT_CHECKPOINT.md`）及其release-evidence为准；本说明记录当前材料配置，不随每次应用重签重复写入动态包哈希，也不把通知源数量当作已部署资源数量。

已定位的8个GPL源相关插件、SFTP/ssh2和两个Chromecast插件已从新产物实际输入/指定入口中排除，不再列为当前配置缺口；旧源码归档仍保留它们是历史来源保存，不表示重新纳入。transcode/smem和PCM/HTTPS所需模块保留。实际构建、输入/符号审查与限定播放差异证据均已保存，不等于所有格式、设备和原窗口验收。

## 许可选择、原文与修改

VLCKit的LGPL正文不是全部静态依赖的统一许可。44来源包逐项映射、主声明及具体已识别内嵌例外见源码目录`build/vlc-source-delivery/license-audit/final-applicability-candidate/FinalApplicability.json`；该文件含来源归档身份、两架构新输入、通知位置与独立审查入口。

- FreeType 2.13.1明确选择FTL，完整FTL、原LICENSE选择说明、二进制致谢及BDF/PCF/fthash/ft-hb额外原文均已保留。软件基于FreeType Team工作。实际`builds/unix/freetype2.in`的pkg_static字段合并由`final-applicability-candidate/source-distribution/FREETYPE-CHANGES.md`和两份diff说明，随对应源交付。
- FFmpeg三处IJG原头与二进制致谢保留；历史6a/v4完整README、来源层级及完整修改diff已独审。它们是有依据的历史比较版本，不宣称唯一导入revision。相关README和修改说明已整合通知源，diff/源码随`ijg-source-closure-20261015/`交付，不只留临时路径。
- BLAKE2明确采用CC0路径并保留官方固定来源全文；soxr的实际x86 PFFFT及两架构Ooura、ebml实际utf8-cpp、HarfBuzz ms-use/Unicode、FriBidi Unicode、libxml2 hash/list等具体例外均有原文和适用证据。Unicode V3注明为当前官方公布授权，不冒称历史数据包原附文本。PNG致谢为鼓励而非强制；modplug公有领域说明不附加新限制。
- VLC `revmodel.hpp`与`transcode.h`的官方模块范围来源补证位于`license-audit/vlc-header-provenance/`。**两头独立审查已通过，具体来源未定位项已关闭**；依据为官方模块范围重授权、拆分/导入关系和原Freeverb来源，不自动以邻文件声明覆盖，也不宣称整个框架法律保证。随包另附`Licenses/VLC-Modules/`来源说明、原Freeverb文本与审查报告，不计入123份contrib。

## 本地源码获取与重建入口

收到ShelfMac完整项目材料的用户，可直接从项目根读取以下目录；无需账号、开发机`/private/tmp`路径或额外公开下载承诺：

1. `build/vlc-source-delivery/SourceMaterials.tar`及`SourceMaterialManifest.json`：固定原始/准备源码、上游及本项目补丁、62份依赖归档、来源清单与历史配置。原tar保持不变，不因排除部分组件删除历史来源。
2. `Packaging/VLC/portable/`、`Packaging/VLC/source-lock.json`、`Packaging/VLC/patched-lock.json`及相关`scripts/`：当前配方、身份与重建/校验/导入流程。操作说明见源码目录`Packaging/VLC/portable/README.md`；应使用独立新工作目录。
3. `build/vlc-source-delivery/exclusion-candidate-20261015/`：实际新框架、BuildReceipt、采用后的`adopted-recipe/`与`AdoptedRecipeManifest.json`、构建日志/配置和复制清单。这里`recipe/`的旧seed仅为历史材料，不能用来校验或导入新框架。
4. `build/vlc-source-delivery/license-audit/`：七批通知原件/审查、最终适用补件、IJG历史材料与修改diff、FreeType变更记录、VLC两头补证，以及新配置实际输入/符号/播放/正式接线证据。随项目保留完整目录，避免证据链接只指向已清理的tmp。

SourceMaterials.tar的历史固定SHA-256为`74c0155c93ddf1bb7312048c25a56e9693f2e86f7c68289f3a829ff0f38e489d`；新构建配方SHA-256为`975ce67dc44d9fc9366539e42d663a1fa458471c039f36dc880f01a3b7395a7a`。这些是版本身份，不表示本次文档任务重算了旧材料。不同路径/工具链可能改变二进制字节，不承诺跨环境逐字节复现。

同源码重建后若字节改变，使用受审`scripts/create-patched-vlc-lock.py`生成独立candidate lock，完成该工具必要检查后，再将框架与已审锁成对采用。不要关闭验证、冒用旧锁或额外限制用户为调试库修改进行的修改/逆向工程。若改变VLC源码，应记录补丁、源码身份及相应运行时预期；不能仅改常量假装取得新源码身份。

## 随应用与随项目交付

应用`Contents/Resources/`应包含本说明、`THIRD_PARTY_NOTICES.md`、项目LICENSE和完整`Licenses/`（含最终123份VLC-Contrib原文，以及独立的3份VLC-Modules来源材料）；Reader许可随相应Reader资源保留。独立应用副本中的源码路径是“随项目材料的位置说明”，不伪称tar在app内部。

随应用提供的本地项目交付目录应包括ShelfMac源码/构建脚本与上述完整`build/vlc-source-delivery/`，尤其当前采用配方/锁、各实际源码归档、修改记录和适用表。只发app加一段“上游可下载”不能替代本项目选择的本地源码交付方式。

当前应用已采用上述123份通知与3份模块材料；具体包内核验以当前交付检查点所链接记录为准。历史c915资源交付采用当时已审两文档与模块材料，复用9fe暂存应用的可执行内容和框架，仅更新资源并临时重签。该次123份通知、3份模块材料、两文档及签名前后可执行/框架变化由ResourceUpdate.json记录；外层签名若改变主二进制字节，应与重新编译区分。旧73c与108份通知的9fe输入保留其历史状态。该次资源交付未重复已通过构建、尾帧或播放，也不声明完整ABS目标完成。

## 历史材料

排除前243插件/307输入/61 contrib库/45来源包、官方二进制和早期`INCOMPLETE`源码审查包是历史检查点；其结论不能代替新配置的实际表。旧`candidate/`、旧recipe/seed与cast协议来源原文继续保留但不作为当前链接清单。历史记录也不因新配置完成局部补证而回写成当时已通过。
