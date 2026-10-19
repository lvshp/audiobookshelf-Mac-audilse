import Foundation
import Testing
@testable import AudilseCore

private func zipFixture(_ entries: [(String, Data)]) -> Data {
    var archive = Data(); var central = Data()
    func word(_ value: UInt16) -> Data { withUnsafeBytes(of: value.littleEndian) { Data($0) } }
    func dword(_ value: UInt32) -> Data { withUnsafeBytes(of: value.littleEndian) { Data($0) } }
    func crc(_ bytes: Data) -> UInt32 {
        var value: UInt32 = 0xffffffff
        for byte in bytes {
            value ^= UInt32(byte)
            for _ in 0..<8 { value = (value & 1) != 0 ? (value >> 1) ^ 0xedb88320 : value >> 1 }
        }
        return ~value
    }
    for (path, bytes) in entries {
        let name = Data(path.utf8); let offset = UInt32(archive.count); let checksum = crc(bytes)
        archive.append(dword(0x04034b50)); archive.append(word(20)); archive.append(word(0)); archive.append(word(0)); archive.append(word(0)); archive.append(word(0))
        archive.append(dword(checksum)); archive.append(dword(UInt32(bytes.count))); archive.append(dword(UInt32(bytes.count))); archive.append(word(UInt16(name.count))); archive.append(word(0)); archive.append(name); archive.append(bytes)
        central.append(dword(0x02014b50)); central.append(word(20)); central.append(word(20)); central.append(word(0)); central.append(word(0)); central.append(word(0)); central.append(word(0))
        central.append(dword(checksum)); central.append(dword(UInt32(bytes.count))); central.append(dword(UInt32(bytes.count))); central.append(word(UInt16(name.count)))
        central.append(word(0)); central.append(word(0)); central.append(word(0)); central.append(word(0)); central.append(dword(0)); central.append(dword(offset)); central.append(name)
    }
    let offset = UInt32(archive.count)
    archive.append(central); archive.append(dword(0x06054b50)); archive.append(word(0)); archive.append(word(0)); archive.append(word(UInt16(entries.count))); archive.append(word(UInt16(entries.count))); archive.append(dword(UInt32(central.count))); archive.append(dword(offset)); archive.append(word(0))
    return archive
}

@Test func comicArchiveExtractsImagesInNaturalNumericOrder() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("shelf-comic-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("book.cbz")
    try zipFixture([("page10.png", Data([10])), ("page2.png", Data([2])), ("__MACOSX/._page1.png", Data([0])), ("notes.txt", Data([0]))]).write(to: file)
    let pages = try await ComicArchive().extract(source: file, destination: root.appendingPathComponent("pages"))
    #expect(pages.map(\.lastPathComponent) == ["page2.png", "page10.png"])
    #expect(try Data(contentsOf: pages[0]) == Data([2]))
}

@Test func comicArchiveRejectsTraversalBeforeCreatingOutsideFiles() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("shelf-comic-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("malicious.cbz")
    try zipFixture([("../escape.png", Data([1]))]).write(to: file)
    await #expect(throws: OfflineStorageError.self) { try await ComicArchive().extract(source: file, destination: root.appendingPathComponent("pages")) }
    #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("escape.png").path))
}

@Test func epubArchiveInspectionEnforcesExpandedTotalAndEntryCount() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("shelf-epub-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("book.epub")
    try zipFixture([("mimetype", Data([1, 2, 3])), ("OEBPS/chapter.xhtml", Data([4, 5, 6]))]).write(to: file)
    try await EbookArchiveInspector().validateEPUB(source: file, maximumEntryBytes: 3, maximumTotalBytes: 6, maximumEntries: 2)
    await #expect(throws: ReadingError.self) { try await EbookArchiveInspector().validateEPUB(source: file, maximumEntryBytes: 3, maximumTotalBytes: 5) }
    await #expect(throws: ReadingError.self) { try await EbookArchiveInspector().validateEPUB(source: file, maximumEntries: 1) }
    await #expect(throws: ReadingError.self) { try await EbookArchiveInspector().validateEPUB(source: file, maximumEntryBytes: 2) }
}
