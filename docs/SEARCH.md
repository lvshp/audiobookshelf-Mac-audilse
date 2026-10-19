# 本地书库分类搜索契约

原生首页和书库的搜索框已接入八类搜索结果，支持当前书库或全部可访问书库。旧的 `libraryItems(search:)` 保持原契约，其他功能页面仍使用各自搜索流程。原应用已观察书籍、作者、系列、朗读者与临时筛选，剩余覆盖见 `UI_ACCEPTANCE_2026-10-13.md`。

## 固定版本依据

核对 ABS v2.26.0、v2.36.1、v2.37.1 的下列源码：

- `server/controllers/LibraryController.js` 的 `search`。
- `server/utils/queries/libraryItemFilters.js` 的 `search` 分发。
- `libraryItemsBookFilters.js`、`libraryItemsPodcastFilters.js` 和 `authorFilters.js` 的 `search`。
- Web 的 `client/components/controls/GlobalSearch.vue` 及 `client/pages/library/_library/search.vue`。

三版上述五段服务端搜索实现去除空白后逐段一致。此接口不需要按版本切换路由或响应模型。

## 请求与范围

`GET /api/libraries/:id/search?q=<query>&limit=<limit>` 搜索一个当前用户可访问的书库。服务端默认每分类上限为 12，Web 自动补全使用 3；完整搜索页面也使用默认上限。Web 名为 `GlobalSearch` 的控件仍只搜索当前书库。

客户端公开：

```swift
ABSClient.searchLibrary(libraryID: String, query: String, limit: Int = 12)
    async throws -> LibrarySearchResponse
```

客户端对查询去除首尾空白，空查询直接返回空响应，不发送请求；每分类 `limit` 限制在 1...500。库 ID 和查询分别使用现有路径组件、URL query 编码，保留反向代理 base path 和字面量 `+`。

服务端没有跨书库聚合路由。客户端“全部书库”从 `libraries()` 返回的可访问书库中发起最多三个并发请求，按书库原顺序分别发布结果及失败，保留来源库和分类身份。`/api/search/books`、`/api/search/authors` 等路由属于外部元数据匹配，不能用于本地书库搜索。

## 八类响应

`LibrarySearchResponse` 的缺失或 null 分类解码为空数组；已知分类的结构错误会抛出，避免把服务异常显示成没有结果。

| Swift 字段 | Wire 字段及条目 | 含义与导航 |
| --- | --- | --- |
| `books` | `book: [{libraryItem: expandedItem}]` | 书籍详情；匹配标题、副标题、ASIN、ISBN |
| `podcasts` | `podcast: [{libraryItem: expandedItem}]` | 节目详情；匹配标题、作者、iTunes ID／artist ID |
| `episodes` | `episodes: [{libraryItem: expandedParent + recentEpisode}]` | 单集结果，详情打开父节目，播放必须传精确单集 ID；匹配单集标题 |
| `authors` | `authors: [Author]`，含 `numBooks` | 作者详情；匹配作者姓名 |
| `series` | `series: [{series: Series, books: [LibraryItem]}]` | 系列详情；匹配系列名 |
| `tags` | `tags: [{name, numItems}]` | 来源库的标签筛选 |
| `genres` | `genres: [{name, numItems}]` | 来源库的类型筛选 |
| `narrators` | `narrators: [{name, numBooks}]` | 来源库的朗读者筛选 |

书库返回书籍、作者、系列、标签、类型、朗读者；播客库返回节目、单集、标签、类型。作者名字命中不等于书籍分类也会命中。

书籍／节目／单集使用 `LibrarySearchItemMatch.libraryItem: LibraryBrowseEntry`，保留顶层 `recentEpisode` 以及同节目不同单集的身份。搜索返回的父节目 `media.episodes` 为空，不能用它代替完整节目详情。系列使用 `LibrarySearchSeriesMatch`；其中 `books` 是预览，服务端会清除其作者和系列关系，不能代替完整系列详情。

## 分页和计数边界

- `limit` 分别应用于每类结果，服务端始终使用 offset 0。请求 `page` 或 `offset` 不会获得下一页。
- 响应没有 `page`、`total` 或 `hasMore`。模型没有虚构这些字段。
- 增大 `limit` 是重新获取前缀，不是真实分页。部分查询没有显式稳定排序；系列还会在 limit 之后过滤空系列或不可访问书籍，因此返回数量不足 limit 也不能证明搜索已穷尽。
- 作者和标签／类型／朗读者的计数查询不完全应用条目细权限。`numBooks`、`numItems` 是服务端给出的目录计数，不保证等于当前用户可访问的结果总量。书库访问权限由路由 middleware 检查，条目和系列子书另有细权限过滤。
- 不进行客户端相关度重排来模拟服务端不存在的统一排名。离线已访问条目缓存也不代表完整的跨书库搜索索引。

## 当前实现与验证范围

Core 实现位于 `Sources/ShelfCore/Features/LibrarySearchModels.swift`、`ABSClientLibrarySearch.swift`，原生协调及界面位于 `Sources/ShelfMac/Search/`。输入防抖350毫秒，每分类上限可选12/24/60/120/250/500；每个书库选择结果分类，每次最多创建六行普通原生视图。这里的页码只浏览已返回结果，不代表服务端搜索分页。

缓存按服务器／账户、书库、精确查询和上限隔离。离线无对应缓存会单独提示，已缓存的空响应才表示这次查询没有结果；在线失败可显示原缓存及失败信息，缓存写入失败不抹掉实时结果。没有建立完整离线索引。

书籍和节目打开详情；单集播放与加入待播使用精确单集身份，离线合并本机最新完成状态。作者／系列在线打开完整关联列表，离线只有完整关联缓存才允许打开，搜索预览或只有计数的作者缓存不代替详情。标签／类型／朗读者打开其来源书库的临时筛选；临时排序、方向和系列折叠独立于原有偏好，显示方式和封面外观仍可保存。离开后重进书库恢复普通偏好，明确选择或清除筛选则按用户选择保存。

账号、客户端、书库、修订、查询、范围、上限、连接及活动状态变更会立即使旧结果操作失效；异步迟回同样核对快照。临时导航只消费一次，已取消的旧视图任务不能消费新导航。

验证范围：

- `Tests/ShelfCoreTests/LibrarySearchTests.swift` 的9项测试已纳入最近175项集中测试，覆盖固定响应形状、单节目双集身份、缓存往返、缺失分类、异常结构、三版同一路由、Unicode／加号／代理路径、上限、空查询和 HTTP 失败。
- `scripts/library-search-smoke.sh` 实际编译正式 Model，14组检查通过，包含最大三并发、逐库发布、部分失败、SQLite跨进程恢复、精确缓存、十三类身份迟回及取消。HTTP由URLProtocol拦截，不访问真实服务器。
- 正式 Search Actions／Model 的38个定向场景通过，覆盖精确单集、离线完成态、完整缓存要求及十四类身份旧点击／迟回；AppStore／player在该夹具中是路由记录器，不代表原生播放引擎验收。
- 临时导航11组行为检查通过，直接编译正式导航／偏好源码，并从当前AppStore及View提取实际方法体，前后哈希一致；覆盖来源库、一次性消费、取消及账号隔离、临时方向/排序、普通偏好字节不变。View方法在普通状态包装器中执行，未执行SwiftUI生命周期，实际保存触发另经静态审查。
- 183项冻结搜索版本的Release打包、深层签名校验及Xcode Release双架构构建通过（不包含后续多行输入修正）；183项源码／测试／脚本／工程／资源在构建前后保持一致。应用内直接资源及SwiftPM bundle中的双语文件与源码逐字节一致。

上述CLI不访问真实服务器。随后原应用已实际只读观察搜索分类、作者／系列详情、全部范围和上限菜单、朗读者来源库筛选及退出后普通偏好恢复；当前真实账户只有一个可访问书库，实际多库、播客分类、搜索显示分页和离线界面仍待验收。未提交服务器配置或启动真实内容播放；正常账户恢复和后台同步不属于CLI的禁网声明。
