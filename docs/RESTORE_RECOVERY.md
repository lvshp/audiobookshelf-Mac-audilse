# 备份恢复后的客户端隔离与重建

2026-10-13：客户端恢复管线已实现，并完成下述 Core、跨进程持久化和正式 AppStore 方法夹具验证。原应用随后在专用可丢弃本机 2.37.1 服务完成唯一恢复确认、隔离面板、JSON 保存导出、客户端重启门禁和人工确认服务端重启后的即时B0读取。随后发现旧保存会话的refresh session被回滚、access到期后续期401，不能将该次读取记作长期认证闭环。新恢复认证修复已完成定向验证，2026-10-14又在新本机实例的原窗口验证401保门禁、重新登录及应用重启恢复；细节见末节。用户真实服务器未执行恢复，活跃播放或下载中的恢复仍未验收。下述较早应用包检查点与本轮原窗口证据分开记录。

## 已实现的状态流转

1. 用户确认恢复或收到当前连接的 `backup_applied` 后，先在主 SQLite 库持久化 `collecting` 门禁。范围为同一规范化服务器地址的全部已知 profile；相同端点的待处理批次合并新增 profile，另一个服务器不归档。启动/登录先查门禁，不能在重启后先载入旧缓存或自动同步旧队列。
2. 旧 ABSClient 永久退役，失效 REST/OIDC 会话、取消刷新并排空已登记的凭据写入；保留令牌。关闭播放器、阅读器和暂停下载，允许受控的最终本机 checkpoint 写入尚未封存的数据库；普通旧缓存、队列读取和同步已受门禁限制。
3. 主库与阅读库分别在事务中封存原始行及 receipt。主库归档缓存（含 resume）、离线音频会话和冲突；阅读库归档支持服务端进度的阅读位置，包括已同步行。未知格式或无法解码的阅读 payload 保守归档，原始字节和标志不丢失。下载记录/原件与明确为 MOBI/AZW3 的本机位置保留。
4. 两份 receipt 范围匹配后进入 `awaitingReconnect`。旧数据库实例的 epoch 永久失效；完成恢复后也不能重新写入。旧认证来源另有弱生命周期记录，完成后的迟到 cleanup 仍不能删除新客户端保留的凭据。
5. 自身申请的恢复只在本次确认路径提交一次 apply；发送前持久记录不确定状态。超时、401/503、关闭重开、准备重试或重启客户端不会自动重发 apply。事件来源也必须匹配当前账号/连接。
6. 用户明确确认管理员已重启服务器后，复用保存会话须先检查status，强制refresh并持久保存新凭据，再用renewed access单次读取账户，随后读取库与进度，才完成两库门禁并安装新实例。refresh401/无可用续期凭据保门禁并引导重新登录，503可重试；不会自动重发apply。fresh密码/OIDC登录不另旋转已新建凭据；只对确证为永久legacy JWT且身份匹配的情况允许无refresh账户检查。主库完成而阅读库提交失败可在当前进程或下次启动补齐，不重发 apply。

同一地址的判定保留反向代理子路径；不猜测不同域名、别名或不同子路径是同一服务。数据库中的 profile ID 本身没有服务器地址，范围由协调层传入的已知 profile 与端点门禁共同确定。

## 归档与导出

批次包含 UUID、规范化地址、profile 列表、创建时间、来源（requested/observed/uncertain）、原因、backup ID、状态及两库 receipt。归档条目保留类别、profile/user、原行 key、原始 `Data` payload、时间和 pending 等标志，JSON 导出保留这些字节及字段。

实现提供历史批次列表及 JSON 导出入口。归档一直保存在本机；没有自动回灌旧进度，也没有原生归档导入/恢复功能。可恢复的数据原件与“已提供导入 UI”是不同状态。本轮已在原应用通过系统 Save 窗口保存专用本机服务的归档；此次归档只有缓存，没有待同步离线音频会话，不能扩大为全部归档类别的原窗口验收。

两 SQLite 文件各自事务原子，不是跨库原子事务；主库持久门禁和匹配 receipt 用于中断修复。归档不能撤回已发至服务器的请求，客户端退役也不能保证撤销已到 wire 的写入。

## 分层验证证据

| 层次 | 实际覆盖 | 数量及证据 |
| --- | --- | --- |
| Core/Playback 集中测试 | 249 项检查点的正式 Core 与 Playback 全套；未为受限环境容量异常放宽下载校验 | 226 Core + 23 Playback = **249 项**，授权环境 `bash scripts/test.sh` 退出码 0；`/private/tmp/shelf-restore-root-check/all-tests-authorized.log` |
| Core 归档与持久门禁 | 多 profile/用户、其他端点、原始未知 payload、下载/Kindle 保留、最终 checkpoint、receipt、增量 scope、事务回滚、网络迟回阻断 | 新增 7 个定义/8 个场景（含参数化），加 Storage 5 项及 ReadingSync 3 项，合计 **15 个测试定义**通过；`/private/tmp/shelf-restore-archive-check/tests-run.log` |
| Core 跨进程 | collecting 持久化、重新打开后禁止普通旧读/同步、封存、awaiting 门禁、显式完成与永久归档 | **4 个实际独立进程**通过，日志 `process-persistence.log`（同上目录）；不证明服务端重启 |
| ABSClient 退役 | 旧 REST/刷新/凭据写入排空、退役后拒绝旧请求；原协议行为复验 | 新增 6 个定义/18 个场景（含参数化），加既有 18 个定义，**24 个测试定义**通过；`/private/tmp/shelf-client-retirement-check/{tests-run.log,result.log}` |
| AppStore 协调层 | 正式 20 个方法、生命周期类型与管理上下文提取；真实 SQLite/ABSClient；唯一 apply、双库提交失败修复、profile 扩围、来源取消、凭据 drain、完成后的旧 cleanup 与弱记录释放 | **20 个定向场景组 + 4 个实际独立进程**，strict Swift 6 编译/执行退出码 0；`/private/tmp/shelf-restore-root-check/testing/result.log` |
| 迟到凭据清理回归 | 相同条件在旧实现删除新客户端保留凭据，修正后拒绝旧 cleanup，正常 live 来源 cleanup 仍可用 | `testing/BeforeLateCleanupFix/late-cleanup-result.log` 为红；`testing/late-cleanup-result.log` 为绿 |
| 恢复认证契约 | 未到期旧access也强制续期、返回非空refresh及active身份、严格legacy永久JWT、401/503、凭据保存/取消与不重放 | 新增8定义/37场景，加既有APIClient18定义/20场景与退役6定义/18场景，共 **32定义/75场景**通过；`/private/tmp/shelf-recovery-auth-check/tests-run.log` |
| 恢复认证AppStore门禁 | 正式20方法提取、真实Core/SQLite；oldaccess GET200但refresh401的旧实现红/修后绿、保存屏障、续期503/缺refresh、epoch/cancel、fresh库503 | **7组**通过；`/private/tmp/shelf-restore-authentication-check/{PLAN.md,RunResults.json,before/result.log,after/result.log}`；路由spy与全拦截HTTP，不是原窗口 |
| 三版真实服务恢复 | 新的一次性官方 2.26.0/2.36.1/2.37.1 实例，真实备份/导出/删除/上传/唯一 apply、磁盘检查与受控服务端重启后完整回读 | 每版磁盘 13 项和重启后 API 15 类；`/private/tmp/shelf-backup-restore-run/{RESULTS.md,final-result.json}` |

上述层次相互补充，数量不相加成另一套“总测试”。AppStore 的 20 组是场景组，不是 Swift Testing 定义数。其播放器/阅读器关闭、下载暂停、实时传输、configure/cache/refresh 为路由 spy；没有据此验证真实 AV 播放或 SwiftUI 生命周期。该 AppStore 夹具的 HTTP 全部由 synthetic URLProtocol 拦截，无用户凭据或真实外网请求。

该 AppStore 夹具检查点前后提取校验通过，44 个 Core 源哈希匹配；14 个 harness 文件与 6 个证据哈希匹配。两编译日志为空。该检查点 AppStore SHA256 为 `179cd2a9cf0b4c49dabea825ffe425ea80b20aa266bf645a7b4aca59e3280a23`。独立进程确实通过 Process 启动，但不能证明真实服务器进程已重启或上游 LRU 已失效。

先前一次受限环境集中运行中，卷服务 Important/Opportunistic 容量返回 0，旧下载诊断测试因此在发请求前收到 `storage.insufficientSpace`；standard/statfs 仍约 283 GB。正常环境同一二进制 Important 容量约 300 GB、6 项通过，随后授权环境全套 249 项通过。产品阈值、原件长度、Range/validator 校验均未改。对照证据为 `/private/tmp/shelf-diagnostic-capacity-check/{root-restricted-run.log,default-run.log}`。

## 上游服务端限制

三版实际 apply 后磁盘均回到 B0，但同一 Node 进程中的 User 模块 LRU 仍使 fresh 登录读到用户、书签、进度 B1；受控服务端重启后 15 类 API 才完整回到 B0。客户端页面刷新、新建 client、apply 200 或收到 `backup_applied` 都不能证明已清除该缓存。当前流程要求人工确认管理员已重启服务器，再执行 fresh 读取；客户端没有可靠的重启自动证明。

备份还会回滚sessions表。旧access JWT在到期前可能仍通过GET，不能据此证明保存的refresh仍有对应会话。第五个本机原窗口实例实际在约1小时后出现Session not found/401；恢复完成条件现新增续期验证，不删除失败的保存令牌，由用户明确重新登录。修复只约束新的待完成恢复，不自动重开既有completed历史，也不在每次启动额外强制refresh。三版CLI在服务端重启后使用全新登录回读，证明磁盘/API数据恢复，不证明恢复前保存会话的续期耐久。

三版最终各用新 UUID 实例且每实例只 apply 一次。另有最初 2.26 诊断实例的一次 apply：3 秒历史被官方启动清理规则删除，失败保留后另建实例用 10 秒基线验证。上述三版 CLI 工作共 4 个不同实例各一次 apply，没有单实例重放；这些实例的临时服务、凭据、数据库和备份包已清理。后续原窗口使用第五个独立本机实例，另记于末节；均不涉及用户真实服务恢复。上游恢复为 metadata 合并等原有行为，不能推断未覆盖的 watcher/cron 热重载或跨版本恢复通过。

## 原应用与应用包边界

- 较早真实服务原窗口只看到备份列表/目录；点击 Restore 以打开确认时被自动审批拦截，理由涉及可能覆盖真实服务数据，未重试。随后改用下述专用可丢弃本机服务验证恢复确认/隔离/导出及即时B0读取；用户真实服务器仍没有执行恢复。
- 个人阅读器设备 sheet 的打开、名称/邮箱 setValue 绑定、Esc/Cancel、重开空草稿，以及 API Key 表单重复打开、Esc/圆形关闭已通过；均未保存真实资料。这不等于电子书正文阅读器、设备发送、密钥写入或恢复 UI 通过。
- 249 项测试对应的较早检查点双语各 **1574** 项。该检查点 AppStore 永久生命周期标记修正后的 Release 打包、深层签名校验及 Xcode Release 均退出码 0，Xcode 可执行文件含 x86_64/arm64；225 项最终源码/工程/测试/脚本/资源哈希无变化，Core/Playback/Tests 相对集中 249 项版本未变。原路径和 staging 两包的双语直接/bundle 共 8 份资源与当时源码逐字匹配。日志 `/private/tmp/shelf-restore-root-check/{release-final.log,xcode-final.log}`，清单 `FinalSourceHashes.json`、部署记录 `Deployment.json`；原包已更新且旧包保留。此处不预记后续书库统计/百分比修复的集中测试或应用包结果。
- 本轮原窗口恢复只使用专用可丢弃本机服务，已检查持久提示、跨进程门禁、归档查看/保存、人工重启确认和恢复后状态重建；没有在原窗口覆盖恢复期间的权限变化、活跃播放器或下载中恢复，不使用真实服务制造恢复或冲突。

其他阅读器、菜单栏、网络中断和双设备 UI 缺口继续以 验收清单（本地记录：`ACCEPTANCE.md`） 及 功能矩阵（本地记录：`FEATURE_MATRIX.md`） 为准。

## 15:25 换包后的原窗口复验

15:23:39 更新原路径包后，通过 `cua.getApp` 按完整应用路径启动；15:25 首页自动恢复真实账号，显示 7 项续听、9 项最近内容和 6 项系列内容，播放器空闲。账户→管理→API Keys→创建显示完整名称、身份、30天及启用表单；Esc 返回可操作列表，再次打开完整表单、圆形关闭返回列表，完成后回首页。未填值、提交真实密钥或修改设置，原路径应用当时留在首页。点击 API 列表时曾单次收到 ScreenCaptureKit `-3812`，下一次 AX 读取确认已经进入列表，此后上述操作正常；不据此声称长期无工具错误。相对 14:51 原窗口包，仅 AppStore 源码变化；个人阅读器名称/邮箱 setValue、Esc/Cancel 的记录仍是 14:51 复验，本次没有重跑。15:25 记录本身不验证恢复 UI；后续专用本机验收另记如下。

## 专用本机服务的原窗口即时恢复与续期缺陷

原应用连接固定官方 2.37.1 的 `http://127.0.0.1:13385/ui-restore`，专用运行 UUID 为 `df282883-5a77-4439-8fd5-c8c58ebc2d5d`。全部账号、书库、音频和阅读数据均为可丢弃合成内容；用户真实服务器本轮未恢复。

1. 原窗口首页和详情先显示 B1 库/标题、61 秒位置和两个书签。随后在本机备份确认界面确认唯一一次 B0 恢复；服务日志记录 `16:09:57.990` 一次 apply，fixture 脚本没有发送 apply。
2. 恢复页出现后，旧书库和账户展示清空，重新连接按钮禁用。通过原生 Save 窗口导出 **13,254 字节、0600** 的 JSON，包含同一端点一个 profile、6 条缓存原始行及主库/阅读库 2 份 receipt；旧 progress/user 缓存中的 61 秒仍原样保存在归档中。本轮没有待同步离线音频会话，不能据此声称已在原窗口验收其归档或阻断上传。
3. Cmd-Q 退出后，`pgrep` 返回 1，未发现 ShelfMac 进程；重新启动仍显示持久恢复门禁，管理员重启确认框未勾选（AX 值 0），重新连接按钮仍禁用，没有自动重新 apply 或载入 B1 旧缓存。
4. 经明确授权，专用 Node 进程仅重启一次，从 PID **39000 → 44964**。fresh 登录/API 与只读 SQLite 确认 B0，原始 WAV/EPUB 和两份备份归档哈希匹配；新客户端本身不被当作服务端 LRU 已清理的证明。
5. 原窗口勾选管理员已重启并确认结果后重新连接，显示 B0 书库/标题、11 秒详情和唯一 `B0@7` 书签；账户中的本机恢复记录显示“已重新连接”。旧缓存归档继续保留，没有自动回灌旧进度。

准备、唯一 apply 和服务端重启证据见 `/private/tmp/shelf-ui-restore-acceptance/HANDOFF.md` 及 UUID 目录的 `artifacts/{ui-apply-log-count.json,checked-B0-1791879544082.json}`。原生保存文件为同级 `ShelfMac-restore-b8ac6826-3ef0-4f84-80f8-586ae308b033.json`，已核对字节数、权限及条目/receipt 数。原窗口交互记录来自本轮 CUA；此次多屏坐标需要按工具实际比例校正，不据此声明所有桌面/显示器配置通过。

这次通过的范围是空闲播放器状态下的即时B0读取、隔离、导出与重启门禁；长期认证没有通过。约1小时后旧access过期，服务端refresh记录Session not found/401，证明原门禁完成条件不足。统计中英文窗口验收前已显式重新登录，不能将那次手工登录计为新恢复认证修复通过。活跃播放、下载传输中恢复、pending 离线会话/阅读待同步记录的原窗口行为及恢复期间权限变化仍待验；它们的 Core/CLI 证据保持上述独立范围。

## 认证修正检查点与原窗口结果（2026-10-14）

`validateServerRecoveryAuthentication()` 已接入保存会话重新连接路径；上述Core32定义/75场景与actual AppStore7组红绿均通过并独审。ConnectionView补重新登录入场校验。认证检查点250 Core + 23 Playback = **273项**集中测试、Release打包及Xcode Release均退出0，日志 `/private/tmp/shelf-recovery-auth-final-{tests,release,xcode}.log`，冻结输入239项。已于2026-10-13 17:35部署原路径，旧包保留；部署记录 `/private/tmp/shelf-recovery-auth-final-deployment.json`，可执行SHA256 `970190467132f706262a1ba69102dccafd23a5555ffcd841b2e78a7d698077a5`。

新UUID `7491b276-965c-42cf-a880-cc5fa66c48a6` 使用同一专用loopback地址。fixture只准备B0备份与B1种子，没有发送apply；唯一apply由原ShelfMac确认。B0为11/90秒，B1为61/90秒，API/live与备份SQLite核对，位置PATCH不带isFinished。用户已明确授权后续测试。

- B1原窗口显示67%。确认唯一恢复后，持久恢复面板出现；专用Node受控重启 **55599 → 98872**，fresh API/只读SQLite确认B0。
- 原窗口勾选重启确认并重连，旧refresh失效后立即打开登录页。地址/用户名/名称预填，密码为空、HTTP同意未勾选；关闭登录后仍显示恢复门禁及401需要重新认证。
- Cmd-Q后无应用进程，重新启动仍在门禁，确认框重置且重连禁用。再明确确认、输入合成账户密码重新登录，进入B0书库，详情显示 **0:11、12%、1个书签**。
- 再次退出并启动，09:25直接回到B0书库12%，没有登录提示；只读会话元数据确认原应用创建了新的刷新会话。未在原窗口等待其access到期，后续续期仍由Core测试覆盖，不能把此记录扩展为长期耐久测试。
- 09:27工具提示有外部用户操作，随后AX显示18.4453%；本路径没有发起播放动作。B0断言取自09:23/09:25，不能声称后续位置始终未变。
- 验证后已从原窗口退出合成账户、恢复原真实profile首页；生命周期工具停止专用Node并删除该UUID服务/凭据目录，保留净化证据。未恢复或写入用户真实服务器。

证据 `/private/tmp/shelf-ui-restore-acceptance/evidence-7491b276-965c-42cf-a880-cc5fa66c48a6/{native-recovery-auth-20261014.json,lifecycle-final.json}`。这次验证了旧会话401时的门禁、关闭/重启保留门禁、fresh密码登录及登录后应用重启。播放器空闲，无下载或pending音频/阅读日志；活跃播放/下载、更多账户/权限变化、503及双库提交失败窗口仍待补。上述273项与1597项双语资源属于此历史部署检查点，不代表之后文件/朗读者/全设备退出增量已整体构建或UI通过。
