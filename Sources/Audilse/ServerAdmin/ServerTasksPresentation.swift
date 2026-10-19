import Foundation
import AudilseCore

@MainActor enum ServerTasksPresentation {
    // Whitelisted official message keys. Unknown server text stays verbatim.
    private static let messages: [String: (String, Int)] = [
        "MessageNoItemsFound": ("未找到任何项目", 0),
        "MessageTaskAudioFileNotWritable": ("音频文件 “%1$@” 不可写", 1),
        "MessageTaskCanceledByUser": ("任务已被用户取消", 0),
        "MessageTaskDownloadingEpisodeDescription": ("正在下载剧集 “%1$@”", 1),
        "MessageTaskEmbeddingMetadata": ("嵌入元数据", 0),
        "MessageTaskEmbeddingMetadataDescription": ("在有声读物 “%1$@” 中嵌入元数据", 1),
        "MessageTaskEncodingM4b": ("编码 M4B", 0),
        "MessageTaskEncodingM4bDescription": ("将有声读物 “%1$@” 编码为单个 m4b 文件", 1),
        "MessageTaskFailed": ("失败", 0),
        "MessageTaskFailedToBackupAudioFile": ("无法备份音频文件 “%1$@”", 1),
        "MessageTaskFailedToCreateCacheDirectory": ("无法创建缓存目录", 0),
        "MessageTaskFailedToEmbedMetadataInFile": ("无法将元数据嵌入文件 “%1$@”", 1),
        "MessageTaskFailedToMergeAudioFiles": ("无法合并音频文件", 0),
        "MessageTaskFailedToMoveM4bFile": ("无法移动 m4b 文件", 0),
        "MessageTaskFailedToWriteMetadataFile": ("无法写入元数据文件", 0),
        "MessageTaskMatchingBooksInLibrary": ("在库中匹配图书 “%1$@”", 1),
        "MessageTaskNoFilesToScan": ("没有要扫描的文件", 0),
        "MessageTaskOpmlImport": ("OPML 导入", 0),
        "MessageTaskOpmlImportDescription": ("通过 %1$@ RSS 源创建播客", 1),
        "MessageTaskOpmlImportFeed": ("OPML 导入源", 0),
        "MessageTaskOpmlImportFeedDescription": ("正在导入 RSS 源 “%1$@”", 1),
        "MessageTaskOpmlImportFeedFailed": ("无法获取播客信息", 0),
        "MessageTaskOpmlImportFeedPodcastDescription": ("正在创建播客 “%1$@”", 1),
        "MessageTaskOpmlImportFeedPodcastExists": ("播客已存在于路径中", 0),
        "MessageTaskOpmlImportFeedPodcastFailed": ("无法创建播客", 0),
        "MessageTaskOpmlImportFinished": ("已添加 %1$@ 播客", 1),
        "MessageTaskScanItemsAdded": ("%1$@ 已添加", 1),
        "MessageTaskScanItemsMissing": ("%1$@ 已缺失", 1),
        "MessageTaskScanItemsUpdated": ("%1$@ 已更新", 1),
        "MessageTaskScanNoChangesNeeded": ("无需改变", 0),
        "MessageTaskScanningFileChanges": ("正在扫描文件更改 “%1$@”", 1),
        "MessageTaskScanningLibrary": ("扫描 “%1$@” 库", 1),
        "MessageTaskTargetDirectoryNotWritable": ("目标目录不可写", 0),
    ]
    static func message(raw: String?, key: String?, substitutions: [ABSDiagnosticValue]?) -> String {
        guard let key, let (template, count) = messages[key] else { return raw ?? "" }
        let values = substitutions ?? []
        guard values.count >= count else { return raw ?? "" }
        var arguments: [CVarArg] = []
        for value in values.prefix(count) {
            switch value {
            case .string(let text): arguments.append(text)
            case .number(let number) where number.isFinite:
                arguments.append(number.formatted(.number.grouping(.never).locale(AppLanguageStore.shared.selection.locale)))
            case .bool(let value): arguments.append(value ? "true" : "false")
            default: return raw ?? ""
            }
        }
        return String(format: L10n.tr(template), locale: AppLanguageStore.shared.selection.locale, arguments: arguments)
    }
    static func title(_ task: ServerTask) -> String {
        let text = message(raw: task.title, key: task.titleKey, substitutions: task.titleSubs)
        return text.isEmpty ? (task.action ?? L10n.tr("任务")) : text
    }
    static func description(_ task: ServerTask) -> String {
        message(raw: task.description, key: task.descriptionKey, substitutions: task.descriptionSubs)
    }
    static func error(_ task: ServerTask) -> String {
        message(raw: task.error, key: task.errorKey, substitutions: task.errorSubs)
    }
    static func scanSummary(_ task: ServerTask) -> String? {
        guard case .object(let data) = task.data?["scanResults"] else { return nil }
        var parts: [String] = []
        for (field, key) in [("added", "MessageTaskScanItemsAdded"), ("updated", "MessageTaskScanItemsUpdated"), ("missing", "MessageTaskScanItemsMissing")] {
            if case .number(let value) = data[field], value.isFinite, value > 0 { parts.append(message(raw: nil, key: key, substitutions: [.number(value)])) }
        }
        if case .number(let value) = data["removed"], value.isFinite, value > 0 {
            parts.append(L10n.format("移除 %1$@ 项", value.formatted(.number.grouping(.never).locale(AppLanguageStore.shared.selection.locale))))
        }
        if parts.isEmpty { parts.append(message(raw: nil, key: "MessageTaskScanNoChangesNeeded", substitutions: nil)) }
        if case .number(let elapsed) = data["elapsed"], elapsed.isFinite, elapsed >= 0 {
            parts.append(L10n.format("耗时 %1$@", Duration.seconds(elapsed / 1_000).formatted(.time(pattern: .hourMinuteSecond))))
        }
        return parts.joined(separator: " · ")
    }
}
