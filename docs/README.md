# 文档索引

## 纳入 Git

- [GitHub Actions 自动打包](GITHUB_ACTIONS.md)

- [当前状态与待改进](STATUS.md)
- [技术范围](PLAN.md)
- [本地化](LOCALIZATION.md)、[搜索契约](SEARCH.md)、[年度回顾](YEAR_IN_REVIEW.md)
- [管理收听会话](ADMIN_PLAYBACK_SESSIONS.md)、[备份恢复](RESTORE_RECOVERY.md)
- [原生公开分享设计](design/PUBLIC_SHARE_NATIVE.md)
- [VLC 播放范围](VLC_PLAYBACK_SCOPE.md)、[VLC 对应源码与交付](VLC_DISTRIBUTION.md)
- [第三方声明](THIRD_PARTY_NOTICES.md)

技术文档中的历史验证段落仅说明当时覆盖范围；最新待改进以 STATUS.md 为准。

## 只保存在本地

旧检查点、阶段验收、历史功能矩阵及缺项审计保留原路径，由 .gitignore 逐项排除，方便复用证据。docs/local/ 保存整理前快照。build/ 包含本机交付包、审查记录及 VLC 大文件材料；Vendor/ 是本地导入框架，均不进入 Git。

仅克隆仓库不包含 VLC 二进制及完整对应源码材料，必须按根 README 和 VLC_DISTRIBUTION.md 单独取得并校验；分发应用时不能因 Git 忽略而省略必要第三方材料。

当前没有提交、远程仓库或公开发布。旧安装包及历史源码归档不会随当前 LICENSE 更新而自动改变。
