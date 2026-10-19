import Foundation
import Testing
@testable import ShelfCore

struct LibraryProgressOrderingTests {
    private func entry(_ id: String, title: String? = nil) -> LibraryBrowseEntry {
        .init(item: .init(id: id, libraryId: "library", media: .init(metadata: .init(title: title ?? id))))
    }
    private func value(_ id: String, _ fraction: Double, finished: Bool = false, updated: Double? = nil, ebook: Double? = nil) -> MediaProgress {
        .init(libraryItemId: id, progress: fraction, isFinished: finished, lastUpdate: updated, ebookProgress: ebook)
    }

    @Test func combinedPagesSortGloballyBeforeBeingPagedAgain() {
        let pages = [[entry("sixty"), entry("finished"), entry("zero")], [entry("fortyFour"), entry("three"), entry("missing")]]
        let progress = [
            "sixty": value("sixty", 0.60, updated: 1), "finished": value("finished", 0.22, finished: true, updated: 2),
            "zero": value("zero", 0, updated: 900), "fortyFour": value("fortyFour", 0.44, updated: 3),
            "three": value("three", 0.03, updated: 1000)
        ]
        let ascending = LibraryProgressOrdering.sorted(pages.flatMap { $0 }, progress: progress, descending: false)
        #expect(ascending.map { $0.item.id } == ["missing", "zero", "three", "fortyFour", "sixty", "finished"])
        #expect(ascending.prefix(3).map { $0.item.id } == ["missing", "zero", "three"])
        #expect(ascending.dropFirst(3).map { $0.item.id } == ["fortyFour", "sixty", "finished"])
        let descending = LibraryProgressOrdering.sorted(pages.flatMap { $0 }, progress: progress, descending: true)
        #expect(descending.map { $0.item.id } == ["finished", "sixty", "fortyFour", "three", "missing", "zero"])
    }

    @Test func finishedMissingNonfiniteAndOutOfRangeProgressHaveDefinedPositions() {
        let ids = ["nan", "positiveInfinity", "negativeInfinity", "negative", "missing", "middle", "overOne", "finished"]
        let entries = ids.map { entry($0) }
        let progress = [
            "nan": value("nan", .nan), "positiveInfinity": value("positiveInfinity", .infinity),
            "negativeInfinity": value("negativeInfinity", -.infinity), "negative": value("negative", -0.4),
            "middle": value("middle", 0.5), "overOne": value("overOne", 1.8), "finished": value("finished", .nan, finished: true)
        ]
        let sorted = LibraryProgressOrdering.sorted(entries, progress: progress, descending: false)
        #expect(Set(sorted.prefix(5).map { $0.item.id }) == Set(ids.prefix(5)))
        #expect(sorted[5].item.id == "middle")
        #expect(sorted.suffix(2).map { $0.item.id } == ["finished", "overOne"])
        #expect(LibraryProgressOrdering.sorted([], progress: progress, descending: false).isEmpty)
    }

    @Test func equalPercentagesUseNaturalTitleThenIdentityInBothDirections() {
        let entries = [entry("b", title: "Book 2"), entry("ten", title: "Book 10"), entry("a", title: "Book 2")]
        for descending in [false, true] {
            let sorted = LibraryProgressOrdering.sorted(entries, progress: [:], descending: descending)
            #expect(sorted.map { $0.item.id } == ["a", "b", "ten"])
            #expect(LibraryProgressOrdering.sorted(Array(entries.reversed()), progress: [:], descending: descending) == sorted)
        }
    }

    @Test func zeroAudioFallsBackToEbookAndNonzeroAudioTakesPrecedence() {
        let entries = [entry("audio"), entry("ebook")]
        let progress = ["audio": value("audio", 0.4, updated: 1, ebook: 0.99), "ebook": value("ebook", 0, updated: 9999, ebook: 0.95)]
        #expect(LibraryProgressOrdering.fraction(for: progress["audio"]) == 0.4)
        #expect(LibraryProgressOrdering.fraction(for: progress["ebook"]) == 0.95)
        #expect(LibraryProgressOrdering.sorted(entries, progress: progress, descending: false).map { $0.item.id } == ["audio", "ebook"])
        #expect(LibraryProgressOrdering.sorted(entries, progress: progress, descending: true).map { $0.item.id } == ["ebook", "audio"])
        #expect(LibraryProgressOrdering.fraction(for: nil) == 0)
        #expect(LibraryProgressOrdering.fraction(for: value("bad-ebook", 0, ebook: .infinity)) == 0)
        #expect(LibraryProgressOrdering.fraction(for: value("finished-ebook", 0, finished: true, ebook: .nan)) == 1)
        #expect(LibraryProgressOrdering.fraction(for: value("over-ebook", 0, ebook: 2)) == 1)
    }
}
