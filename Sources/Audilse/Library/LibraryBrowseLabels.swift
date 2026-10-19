import Foundation
import AudilseCore

extension LibraryBrowseSort {
    var title: String {
        switch self {
        case .title: L10n.tr("标题")
        case .authorFirstLast: L10n.tr("作者（名 · 姓）")
        case .authorLastFirst: L10n.tr("作者（姓 · 名）")
        case .podcastAuthor: L10n.tr("作者")
        case .publishedYear: L10n.tr("出版年份")
        case .addedAt: L10n.tr("添加时间")
        case .size: L10n.tr("文件大小")
        case .duration: L10n.tr("时长")
        case .fileCreated: L10n.tr("文件创建时间")
        case .fileModified: L10n.tr("文件修改时间")
        case .progress: L10n.tr("进度更新时间")
        case .progressStarted: L10n.tr("开始时间")
        case .progressFinished: L10n.tr("完成时间")
        case .random: L10n.tr("随机")
        case .sequence: L10n.tr("系列顺序")
        case .episodeCount: L10n.tr("单集数量")
        }
    }
}
extension LibraryBrowseFilter {
    func title(metadata: LibraryFilterMetadata?) -> String {
        switch self {
        case .all: L10n.tr("全部内容")
        case .genre(let v): L10n.format("类型：%1$@", String(describing: v))
        case .tag(let v): L10n.format("标签：%1$@", String(describing: v))
        case .series(let v): L10n.format("系列：%1$@", String(describing: metadata?.series.first { $0.id == v }?.name ?? L10n.tr("已选系列")))
        case .noSeries: L10n.tr("无系列")
        case .author(let v): L10n.format("作者：%1$@", String(describing: metadata?.authors.first { $0.id == v }?.name ?? L10n.tr("已选作者")))
        case .narrator(let v): L10n.format("演播者：%1$@", String(describing: v))
        case .publisher(let v): L10n.format("出版社：%1$@", String(describing: v))
        case .publishedDecade(let v): L10n.format("出版年代：%1$@", String(describing: v))
        case .language(let v): L10n.format("语言：%1$@", String(describing: v))
        case .progress(let v): v.title
        case .missing(let v): L10n.format("缺少%1$@", String(describing: v.title))
        case .tracks(let v): v.title
        case .ebooks(let v): v.title
        case .abridged: L10n.tr("删节版")
        case .issues: L10n.tr("存在文件问题")
        case .feedOpen: L10n.tr("已开启 RSS")
        case .explicit: L10n.tr("成人内容")
        case .shareOpen: L10n.tr("已开启分享")
        case .recent: L10n.tr("最近更新")
        }
    }
}
extension LibraryProgressFilter {
    var title: String {
        switch self {
        case .finished: L10n.tr("已完成")
        case .inProgress: L10n.tr("进行中")
        case .notStarted: L10n.tr("未开始")
        case .notFinished: L10n.tr("未完成")
        case .audioInProgress: L10n.tr("正在收听")
        case .ebookInProgress: L10n.tr("正在阅读")
        case .ebookFinished: L10n.tr("已读完")
        }
    }
}
extension LibraryMissingField {
    var title: String {
        switch self {
        case .asin: "ASIN"
        case .isbn: "ISBN"
        case .authors: L10n.tr("作者")
        case .chapters: L10n.tr("章节")
        case .cover: L10n.tr("封面")
        case .description: L10n.tr("简介")
        case .genres: L10n.tr("类型")
        case .language: L10n.tr("语言")
        case .narrators: L10n.tr("演播者")
        case .publishedYear: L10n.tr("出版年份")
        case .publisher: L10n.tr("出版社")
        case .series: L10n.tr("系列")
        case .subtitle: L10n.tr("副标题")
        case .tags: L10n.tr("标签")
        }
    }
}
extension LibraryTrackFilter {
    var title: String { switch self { case .none: L10n.tr("无音轨"); case .single: L10n.tr("单音轨"); case .multi: L10n.tr("多音轨") } }
}
extension LibraryEbookFilter {
    var title: String { switch self { case .ebook: L10n.tr("有主电子书"); case .noEbook: L10n.tr("无主电子书"); case .supplementary: L10n.tr("有补充电子书"); case .noSupplementary: L10n.tr("无补充电子书") } }
}
