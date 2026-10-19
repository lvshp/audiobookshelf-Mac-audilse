# 年度回顾

本轮补齐个人年度回顾图片和服务器年度回顾原生入口。契约以固定 Audiobookshelf 2.26.0、2.36.1、2.37.1 的服务端及 Web 源码为准；这些版本已存在年度统计接口，本轮没有另造接口。

## 使用入口与图片

- 个人：进入“统计”，选择年份，在年度统计下选择“收听亮点”“听完的书”“作者与分类”或“简版横幅”。
- 服务器：活动的管理员或根账户在线进入服务器管理，选择“服务器年度回顾”；提供“新增书籍”“作者与旁白”“作者与分类”三种图片，以及独立的当前存储统计。
- 当前图片可保存为 PNG、复制图片或由系统分享菜单交给用户选择的目标。预览、保存、复制和分享复用同一份已渲染 PNG；应用不会自动外发图片，也不会创建公开 ABS 分享。

渲染器使用 `ImageRenderer`，固定 `scale = 2`。个人前三种及服务器三种版式逻辑尺寸为 800 × 800，输出 1600 × 1600 像素；个人横幅为 600 × 200，输出 1200 × 400。界面及图片支持简体中文、英文切换。

封面通过当前账户的已授权请求读取缩略图，去重后最多 25 张、最多 3 个并发请求；不把令牌写入分享图片。授权失败、封面缺失或图片损坏时保留数值并使用无封面版式，显示部分封面不可用提示。封面读取和图片生成有加载状态。

## 契约与兼容边界

| 用途 | 既有方法与路由 | 返回类型 |
| --- | --- | --- |
| 个人年度统计 | `yearlyStatistics(year:)` → `GET /api/me/stats/year/:year` | `YearlyStatistics` |
| 服务器年度统计 | `adminYearlyStatistics(year:)` → `GET /api/stats/year/:year` | `AdminYearlyStatistics` |
| 当前服务器存储 | `serverStorageStatistics()` → `GET /api/stats/server` | `ServerStorageStatistics` |

服务器接口允许管理员和根账户，不仅限根账户。服务端接受公历年份 2000…9999；无权限、无接口或服务错误按错误处理，不把失败伪装为空统计。个人累计统计与年度统计、服务器年度统计与存储统计分别发布结果，单项失败不清空另一项成功结果。

服务器年度返回全部 13 个字段：`numListeningSessions`、`numBooksAdded`、`numAuthorsAdded`、`totalBooksAddedSize`、`totalBooksAddedDuration`、`booksAddedWithCovers`、`totalBooksSize`、`totalBooksDuration`、`totalListeningTime`、`numBooks`、`topAuthors`、`topNarrators`、`topGenres`。容量为字节，时长为秒；排行榜保留服务端顺序。该接口没有月份或用户排行榜，客户端没有虚构这些字段。

个人 `mostListenedMonth.month` 为 0…11；`longestAudiobookFinished.id` 是内部书籍 ID，不能当作封面条目 ID。封面数组使用 library-item ID。服务器会随机选取最多 25 张年度新增书籍封面，数量不代表年度新增总数。

本轮对既有统计类型增加公开初始化器，方便调用方和无窗口渲染夹具构造完整数据；保留原字段、严格解码和接口行为。空年度的完整零值响应合法，缺必需字段或类型错误仍抛出解码错误。

年份选择和月份显示显式使用 Gregorian 公历，不随系统佛历等偏好变成错误的 API 年份。个人默认当前年；服务器按 Web 约定，在可选范围内于 12 月前默认上一年、12 月默认当前年，并保留用户主动选择。

### 上游年度馆藏总量限制

三版固定 `server/utils/queries/adminStats.js` 的馆藏总量查询均含 `li.createdAt < ":nextYear-01-01"`。实际 Sequelize 替换不会处理该带引号的占位内容，因此 `numBooks`、`totalBooksSize`、`totalBooksDuration` 可能包含所选年份之后新增的书籍。

这三个值按服务端原样保留，并标为“服务端馆藏总计/大小/时长”，附限制说明；不能称为可靠的年末快照。年度新增、会话、收听时长、排行榜与封面使用各自年度条件。隔离服务的 2000 年实际读取已证实：年度活动为空，但这三个汇总仍可能非零。客户端没有据此推算或改写服务端数据。

## 来源和取消门禁

个人年度结果绑定账户分区、客户端实例、所选年份和请求世代；切换年份时不会把旧结果重新标成新年份。封面另检查在线、连接状态及用户活动状态。服务器来源还绑定配置、账户类型和身份，拒绝离线、演示模式、连接中或无权限上下文。

每次异步发布均核对捕获的来源；取消、旧账户迟回、旧年份迟回及已取消任务晚入场不能覆盖当前结果。图片版本包含来源、年份、数据、封面版本、版式和语言，过期或仍在准备中的图片不能通过当前保存、复制或分享控件操作。

## 已执行验证

以下是本轮实际执行记录。`/private/tmp` 为本机临时证据目录，不属于交付资源。临时验证仅使用合成凭据；真实凭据不写入脚本、日志或项目文档。

| 范围 | 已执行结果与证据 | 验证边界 |
| --- | --- | --- |
| Core 年度契约 | `AnnualStatisticsTests`：8 项测试、13 个场景通过；`/private/tmp/shelf-annual-stats-check/tests-run.log` | 真实 Core + URLProtocol；覆盖完整字段、单位、编解码、空值与错误区分、三版路径、边界年份及 400/403/503，不等同原生界面验收。 |
| 三版实际 API | 18 项通过；`/private/tmp/shelf-annual-stats-check/actual-run.log`；SQL 替换证据 `upstream-cutoff.log` | 仅固定 loopback 合成服务的认证登录及 GET，使用内存令牌和禁止重定向；无生产、内容、进度或设置写入。 |
| 个人统计模型 | 8 个场景通过；`/private/tmp/shelf-year-review-statistics-model-final.log`；佛历环境同样通过 `shelf-year-review-statistics-model-buddhist.log` | [`scripts/statistics-smoke.swift`](../scripts/statistics-smoke.swift) 编译正式 `FeatureBrowserModel`，以身份 stub、URLProtocol 验证独立失败、来源与取消；不是完整 AppStore 或原生窗口。 |
| 服务器统计模型 | 9 组通过；`/private/tmp/shelf-server-statistics-model/result.log`；佛历环境同样通过 `buddhist-result.log` | 编译正式 `ServerStatisticsModel`，覆盖默认年份、独立失败、权限、身份、年份迟回与取消；fixture/run.sh 在同一临时目录。 |
| 封面与 PNG | 6 个封面门禁场景、56 张图片通过；`/private/tmp/shelf-year-review-smoke-final.log` | 真实封面模型、渲染器及个人/服务器海报；HTTP 全部被合成 URLProtocol 截获，无窗口、无真实网络。 |

56 张图片由个人 4 样式及服务器 3 样式，分别组合 2 种语言和正常、长名称、零数据、无封面 4 组数据组成。验证 PNG 可解码、像素尺寸、内容非空，以及语言、封面、零数据的像素差异；文件与 `manifest.json` 位于 `/private/tmp/shelf-year-review-smoke-current/images`。长名称可生成图片不等于已人工确认每段文字均完整显示。

可复用的图片验证脚本是 [`scripts/year-review-smoke.sh`](../scripts/year-review-smoke.sh) 与 [`scripts/year-review-smoke.swift`](../scripts/year-review-smoke.swift)。包装器仅复制已经匹配的 Debug Core 模块、静态库和资源，并在独立目录运行 `swiftc`，不会自行执行共享 `swift build`：

```bash
# 先由统一构建流程准备匹配的 Debug 模块及 libShelfCore.a。
YEAR_REVIEW_SMOKE_PREBUILT=/path/to/matching-debug \
YEAR_REVIEW_SMOKE_WORKDIR=/private/tmp/shelf-year-review-check \
bash scripts/year-review-smoke.sh
```

## 应用构建和原窗口验证

年度增量的集中测试 183 项（Core 164、Playback 19）、SwiftPM Release 打包、深层签名校验、Xcode Release 均退出 0；Xcode 实际产物含 x86_64/arm64。192 项冻结清单见 `/private/tmp/shelf-year-review-final-source.json`，构建后随后播客地区增量的三个文件和打包输出路径脚本发生变化。年度包两套语言资源各 1393 项，直接资源及 SwiftPM bundle 与源码逐字节一致。

2026-10-13 在原 `build/ShelfMac.app` 中实际切换四种个人版式；通过保存对话框取消一次，再将横幅导出到 `/private/tmp/shelf-year-review-native/ShelfMac-native-2026-banner.png`。文件可解码，实际尺寸 1200 × 400，人工检查真实封面、年份和数值正常。复制操作显示“图片已复制”，系统分享菜单出现隔空投送、邮件等选项，随后关闭；没有向真实目标分享。此项只确认复制成功反馈，未另外读回剪贴板或验收每种外部目标。

服务器管理侧栏中已实际观察到“服务器年度回顾”。点击后电脑控制原生连接返回 `native pipe closed before response`，重连和重置仍相同，因此服务器页面加载、三版式切换及英文原窗口验收仍未计为通过。个人跨年度切换、全部七版式分别保存及来源变化时关闭导出面板，也尚未完成原窗口验证；已有模型和 PNG 夹具不能替代这些检查。详细范围见 原应用验收记录（本地记录：`UI_ACCEPTANCE_2026-10-13.md`）。

随后播客地区继承修正版完成186项集中测试、Release打包、深层签名及Xcode Release双架构，192项最终清单构建后相同，双语资源逐字节一致。该检查点包当时保存在 `build/staging/ShelfMac.app`，未覆盖仍运行的年度包；staging的最新增量以 `STATUS.md` 为准；日志与清单见 `STATUS.md`。最新诊断报告确认电脑控制服务自身触发SIGTRAP，不把工具失败当作ShelfMac崩溃或页面通过。
