import Foundation
import Darwin

/// Uses macOS libarchive's ZIP/RAR readers, extracting only regular image entries.
public actor ComicArchive {
    public init() {}
    public func extract(source: URL, destination: URL) throws -> [URL] {
        let api = try ArchiveAPI()
        guard let archive = api.create() else { throw ReadingError.missingLibrary }
        defer { _ = api.free(archive) }
        _ = api.supportFilter(archive); _ = api.supportFormat(archive)
        guard api.open(archive, source.path, 65_536) == 0 else { throw ReadingError.invalidArchive(api.message(archive)) }
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        var images: [URL] = []
        var total: Int64 = 0
        var entry: OpaquePointer?
        while true {
            let status = api.next(archive, &entry)
            if status == 1 { break } // ARCHIVE_EOF
            guard status >= -20, let entry else { throw ReadingError.invalidArchive(api.message(archive)) }
            guard let pathPointer = api.path(entry) else { throw ReadingError.invalidArchive("条目没有文件名") }
            let path = String(cString: pathPointer)
            // Validate all paths, even entries whose extension is not an image.
            let normalized = path.hasSuffix("/") ? String(path.dropLast()) : path
            if normalized.isEmpty { continue }
            let output = try DownloadPaths.safeURL(relativePath: normalized, root: destination)
            guard api.fileType(entry) == 0o100000 else { _ = api.skip(archive); continue }
            guard api.symlink(entry) == nil, api.hardlink(entry) == nil else { throw ReadingError.invalidArchive("压缩包包含文件链接") }
            guard !path.split(separator: "/").contains(where: { $0.hasPrefix(".") || $0 == "__MACOSX" }),
                  ["jpg", "jpeg", "png", "gif", "webp", "heic", "avif", "bmp", "tiff"].contains(output.pathExtension.lowercased()) else { _ = api.skip(archive); continue }
            let declared = api.size(entry)
            guard declared >= 0, declared <= 128 * 1024 * 1024, images.count < 30_000 else { throw ReadingError.oversizedArchive }
            try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: output.path, contents: nil)
            let handle = try FileHandle(forWritingTo: output)
            var buffer = [UInt8](repeating: 0, count: 65_536)
            var written: Int64 = 0
            do {
                while true {
                    let count = buffer.withUnsafeMutableBytes { api.read(archive, $0.baseAddress, $0.count) }
                    if count == 0 { break }
                    guard count > 0 else { throw ReadingError.invalidArchive(api.message(archive)) }
                    written += Int64(count); total += Int64(count)
                    guard written <= 128 * 1024 * 1024, total <= 2 * 1024 * 1024 * 1024 else { throw ReadingError.oversizedArchive }
                    try handle.write(contentsOf: Data(buffer.prefix(count)))
                }
                try handle.close()
            } catch { try? handle.close(); throw error }
            guard written == declared else { throw ReadingError.invalidArchive("条目大小不匹配") }
            images.append(output)
        }
        guard !images.isEmpty else { throw ReadingError.invalidArchive("压缩包中没有可显示的图片") }
        return Self.naturallySorted(images)
    }
    public static func naturallySorted(_ urls: [URL]) -> [URL] {
        urls.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }
}

/// Verifies expanded EPUB contents before an in-memory JavaScript ZIP reader sees them.
public actor EbookArchiveInspector {
    public init() {}
    public func validateEPUB(source: URL, maximumEntryBytes: Int64 = 128 * 1024 * 1024, maximumTotalBytes: Int64 = 512 * 1024 * 1024, maximumEntries: Int = 10_000) throws {
        let api = try ArchiveAPI()
        guard let archive = api.create() else { throw ReadingError.missingLibrary }
        defer { _ = api.free(archive) }
        _ = api.supportFilter(archive); _ = api.supportFormat(archive)
        guard api.open(archive, source.path, 65_536) == 0 else { throw ReadingError.invalidArchive(api.message(archive)) }
        var entry: OpaquePointer?
        var entries = 0
        var total: Int64 = 0
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            let status = api.next(archive, &entry)
            if status == 1 { break }
            guard status >= -20, let entry, let pathPointer = api.path(entry) else { throw ReadingError.invalidArchive(api.message(archive)) }
            entries += 1
            guard entries <= maximumEntries else { throw ReadingError.oversizedArchive }
            let path = String(cString: pathPointer)
            let normalized = path.hasSuffix("/") ? String(path.dropLast()) : path
            if !normalized.isEmpty { _ = try DownloadPaths.safeURL(relativePath: normalized, root: source.deletingLastPathComponent()) }
            guard api.symlink(entry) == nil, api.hardlink(entry) == nil else { throw ReadingError.invalidArchive("压缩包包含文件链接") }
            let declared = api.size(entry)
            guard declared >= 0, declared <= maximumEntryBytes, total <= maximumTotalBytes - declared else { throw ReadingError.oversizedArchive }
            var expanded: Int64 = 0
            while true {
                let count = buffer.withUnsafeMutableBytes { api.read(archive, $0.baseAddress, $0.count) }
                if count == 0 { break }
                guard count > 0 else { throw ReadingError.invalidArchive(api.message(archive)) }
                expanded += Int64(count)
                guard expanded <= maximumEntryBytes, total <= maximumTotalBytes - expanded else { throw ReadingError.oversizedArchive }
            }
            guard expanded == declared else { throw ReadingError.invalidArchive("条目大小不匹配") }
            total += expanded
        }
        guard entries > 0 else { throw ReadingError.invalidArchive("压缩包为空") }
    }
}

private final class ArchiveAPI {
    typealias Create = @convention(c) () -> OpaquePointer?
    typealias Status = @convention(c) (OpaquePointer?) -> Int32
    typealias Open = @convention(c) (OpaquePointer?, UnsafePointer<CChar>?, Int) -> Int32
    typealias Next = @convention(c) (OpaquePointer?, UnsafeMutablePointer<OpaquePointer?>?) -> Int32
    typealias Path = @convention(c) (OpaquePointer?) -> UnsafePointer<CChar>?
    typealias FileMode = @convention(c) (OpaquePointer?) -> UInt32
    typealias Size = @convention(c) (OpaquePointer?) -> Int64
    typealias Read = @convention(c) (OpaquePointer?, UnsafeMutableRawPointer?, Int) -> Int
    let library: UnsafeMutableRawPointer
    let create: Create; let free: Status; let supportFilter: Status; let supportFormat: Status
    let open: Open; let next: Next; let path: Path; let fileType: FileMode; let symlink: Path; let hardlink: Path
    let size: Size; let read: Read; let skip: Status; let error: Path
    init() throws {
        guard let library = dlopen("/usr/lib/libarchive.2.dylib", RTLD_NOW | RTLD_LOCAL) else { throw ReadingError.missingLibrary }
        self.library = library
        func symbol<T>(_ name: String, _ type: T.Type) throws -> T {
            guard let pointer = dlsym(library, name) else { throw ReadingError.missingLibrary }
            return unsafeBitCast(pointer, to: type)
        }
        do {
            create = try symbol("archive_read_new", Create.self); free = try symbol("archive_read_free", Status.self)
            supportFilter = try symbol("archive_read_support_filter_all", Status.self); supportFormat = try symbol("archive_read_support_format_all", Status.self)
            open = try symbol("archive_read_open_filename", Open.self); next = try symbol("archive_read_next_header", Next.self)
            path = try symbol("archive_entry_pathname", Path.self); fileType = try symbol("archive_entry_filetype", FileMode.self)
            symlink = try symbol("archive_entry_symlink", Path.self); hardlink = try symbol("archive_entry_hardlink", Path.self)
            size = try symbol("archive_entry_size", Size.self); read = try symbol("archive_read_data", Read.self)
            skip = try symbol("archive_read_data_skip", Status.self); error = try symbol("archive_error_string", Path.self)
        } catch { dlclose(library); throw error }
    }
    deinit { dlclose(library) }
    func message(_ archive: OpaquePointer) -> String { error(archive).map(String.init(cString:)) ?? "未知压缩格式错误" }
}
