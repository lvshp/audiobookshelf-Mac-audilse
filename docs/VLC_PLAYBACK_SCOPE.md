# VLC 实际产品调用范围

本页 build/ 链接是随本地交付材料保存的历史证据，不包含在 Git 仓库中；技术调用分析以文中日期为准。

2026-10-15，只读当前源码及既有证据；没有测试、构建、UI、网络请求或二进制复扫。结论：当前应用没有将远端 HTTP/HTTPS 播放 URL 传入 VLC 的产品分支。新框架的 HTTPS 插件存在门禁可复用，但无需为了这个未调用的插件另造远端 TLS 播放验收；实际远端产品路径的网络验收仍属于 AVFoundation/URLSession 范围。

| 路径 | 实际条件和来源 |
| --- | --- |
| VLC兼容格式选择 | [LocalCompatibilityEngine.swift:46](../Sources/ShelfPlayback/LocalCompatibilityEngine.swift#L46)先要求`isLocal`，再按扩展名决定。控制器[初始选择:599](../Sources/ShelfPlayback/PlaybackController.swift#L599)、[AV不可播放回退:618](../Sources/ShelfPlayback/PlaybackController.swift#L618)、[运行失败回退:760](../Sources/ShelfPlayback/PlaybackController.swift#L760)三处均只对本地轨道进入兼容引擎。初始`isPlayable`探测仅对本地执行；远端失败在:772重新加载原路径，不切VLC。 |
| VLC最终输入门禁 | [NativePCMCompatibilityEngine.swift:38](../Sources/ShelfPlayback/NativePCMCompatibilityEngine.swift#L38)同时要求`isLocal`、`file:` URL及文件存在；:60只传`url.path`。[:331](../Sources/ShelfPlayback/NativePCMCompatibilityEngine.swift#L331)绑定`libvlc_media_new_path`，[:390](../Sources/ShelfPlayback/NativePCMCompatibilityEngine.swift#L390)用路径创建media；没有`libvlc_media_new_location`产品调用。PCM经transcode/smem送原生AVAudioEngine。 |
| 普通ABS远端播放 | [ABSPlaybackService.swift:16](../Sources/ShelfPlayback/ABSPlaybackService.swift#L16)构造远端轨道，`PlaybackTrack`的[默认isLocal=false:40](../Sources/ShelfPlayback/PlaybackModels.swift#L40)。直连文件走:25授权URL；HLS保留会话URL，并由[HLSReadinessGate.swift:43](../Sources/ShelfPlayback/HLSReadinessGate.swift#L43)的URLSession探测就绪。控制器[makeAsset:648](../Sources/ShelfPlayback/PlaybackController.swift#L648)为普通ABS创建AVURLAsset，[:630](../Sources/ShelfPlayback/PlaybackController.swift#L630)创建AVPlayerItem。 |
| 匿名分享例外 | 这里不是直接HTTP AVURLAsset：[PublicSharePlaybackService.swift:23](../Sources/ShelfMac/PublicSharing/PublicSharePlaybackService.swift#L23)构造非本地合成scheme，:44返回受控资源源；:77经`readTrackRange`读字节。[PublicShareClient.swift:261](../Sources/ShelfCore/PublicSharing/PublicShareClient.swift#L261)调用[PublicShareTransport.swift:40](../Sources/ShelfCore/PublicSharing/PublicShareTransport.swift#L40)的临时URLSession；[PlaybackResourceLoader.swift:25](../Sources/ShelfPlayback/PlaybackResourceLoader.swift#L25)将字节交AVURLAsset，限制嵌入引用，仍不走VLC。 |
| 已下载媒体（在线也可能选用） | [AppStore.swift:871](../Sources/ShelfMac/State/AppStore.swift#L871)优先使用readyTracks并标`isLocal:true`；离线/队列恢复也从已准备本地轨道构造。故“VLC仅本地”不等于“仅离线模式”。原件下载本身由[DownloadTransfer.swift:32](../Sources/ShelfCore/Downloads/DownloadTransfer.swift#L32)的URLSession完成；兼容引擎接收到的是下载后的文件。控制器[playOffline:173](../Sources/ShelfPlayback/PlaybackController.swift#L173)另检查文件URL及可读性。 |

边界：`isLocal`误标的远端URL也会被兼容引擎的`isFileURL`门禁拒绝，未找到远端失败后切VLC的例外。这里证明的是产品顶层输入路由，不是libVLC网络沙箱证明；本次未追踪任意本地容器嵌入引用、播放列表或网络挂载文件的底层行为，不凭推测把这些变成新交付阻断。未来若新增VLC远端URL入口，再针对变化补实际TLS验证。

复用[实际候选审查](../build/vlc-source-delivery/license-audit/plugin-exclusion-plan/ActualCandidateReview.md)的232入口、295链接输入及PCM/HTTPS模块保留结果；[播放差异报告](../build/vlc-source-delivery/license-audit/plugin-exclusion-plan/playback-difference-20261015/REPORT.md)确实未执行VLC TLS请求，仍按其本地解码/播放边界解释。9fe签后加载和c915资源更新后的框架字节不变见[资源记录](../build/release-evidence/vlc-notices-resource-20261015/ResourceUpdate.json)。本项关闭的是B7中“是否应为VLC插件新增远端TLS验收”的调用面问题，不替代最终原窗口受影响播放操作或其他平台证据。
