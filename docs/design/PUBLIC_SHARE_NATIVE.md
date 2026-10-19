# 公开分享原生接入：实施约束

状态：实施中，尚未进入已验证的22a8候选包。当前分享发布/撤销/复制/外部打开继续保留。

固定2.26与2.37.1的实际入口均是代理前缀下 `/public/share/:slug`。首次GET建立 `share_session_id`，资源和进度请求使用该匿名cookie。30天cookie不保证服务端内存会话持续存在；分享撤销、到期或服务器重启必须作为可见状态处理，不尝试账户登录或复用账户令牌。分享服务当前公开解析只支持book，不能仅凭发布接口接收podcastEpisode宣称匿名消费支持播客。

## 分工与数据边界

- Core新增PublicShareClient、严格URL与typed响应、独立加密状态仓库；所有匿名网络由独立ephemeral会话手动管理cookie，无共享凭据、无重定向、无账户数据库写入。
- 播放层用可选PlaybackResourceSource和custom-scheme AVAssetResourceLoader读取progressive媒体。每次读取最多1MiB，严格检查范围、总长度、取消与迟回；不将cookie交给AVFoundation默认HTTP存储。
- SDK明确AVURLAssetHTTPCookiesKey只是补充默认cookie，不能据此保证账户cookie隔离，因此不使用它作为本接线的隔离方案。
- AppStore保留账户player；独立PublicShareCoordinator持有匿名player、本机收据与打开状态。通用底栏、菜单栏和播放命令使用activePlayer；个人书签、内容队列、下载同步及管理会话仍只操作账户player。

## 播放控制与生命周期

切换前对旧播放上下文执行checkpointForTransition并验证收据，不仅pause；这样同时取消旧prepare/load代际并保留失败时重试能力。不同分享的候选加载失败时不主动破坏正在使用的播放上下文；同源同链接重开行为见下方检查点。账户播放请求与匿名打开请求使用可失效的交接标识，迟到结果不能抢回播放权。

系统媒体控制只有一个owner。所有权覆盖remote command注册与迟到Task、NowPlaying设置和清空、封面迟回、命令参数配置及sleep/wake恢复；不能只移除按键target。公开播放的倍速设置不写个人账户偏好。

退出须分别保存账户与匿名收据，再释放控制器；任一持久化失败均保留对应上下文和错误供重试。匿名sync只发送currentTime，不向账户会话端点发送timeListened。没有公开close端点时，不伪造账户close请求。

## 验证要求

Core契约/来源与cookie隔离、坏数据/有限超时、撤销及恢复、不同slug/端口/前缀、分享身份改变后不继承旧位置；使用全新本机官方实例，管理员仅准备合成分享，匿名客户端不得得到管理员凭据。

播放层验证真实AV自定义资源读取、范围与EOF、取消/迟回、系统控制权切换；AppStore验证交接中账号/分享变化和退出失败重试。原生窗口验收仍需解锁后在原应用进行，不用模型或编译结果替代。

## 当前实现检查点（2026-10-14）

原生独立分享窗口已接入应用窗口场景，文件菜单和菜单栏可打开；通用底栏、菜单栏与播放快捷键读取 activePlayer。匿名状态下隐藏账户队列入口，账户内容入口仍经过 AppStore 保存与交接门禁。关闭分享窗口只取消未采用的打开任务及文件导出，已经采用的播放上下文由应用持有。

同源同链接重开先通过账户保存门禁，再保存并退役旧匿名上下文，最后重新加载最新本机状态，避免 CAS 基线过期。若重开网络失败，旧上下文已安全停止，位置仍有本机收据；不承诺此情况下旧播放继续。不同分享则先取得候选响应，再交接。打开任务串行取消，待前次清理完成才建立新客户端。

实际 Coordinator 与 adapter 六组定向验证及独立审查通过：两版官方服务同链接播放重开、交接门禁拒绝保留旧对象、慢请求取消及快速重开、本机持久化故障重试、retire 失败后同句柄恢复。证据 `/private/tmp/shelf-public-coordinator-check/IndependentReview-astra.json`。这不覆盖 AppStore 双账户退出和原生窗口交互。

加入窗口、控件和导出源后的完整 `swift build --product ShelfMac` 已退出 0，日志 `/private/tmp/shelf-public-share-integration-build-3.log`。尚未完成新增代码的全部测试、Release/Xcode 构建、最终整合审查和原窗口验收；未替换已部署包或22a8暂存包。

账户书签隔离指匿名播放位置不能自动写入账户书签或收听记录；用户显式编辑原账户书籍的书签仍可用。真正播放交接前后重新核对连接、恢复和管理会话门禁，避免等待中的请求绕过新开始的操作。此竞态还需实际 AppStore 回归。
