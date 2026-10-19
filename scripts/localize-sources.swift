import Foundation
import SwiftParser
import SwiftSyntax
import SwiftSyntaxBuilder

// Compiled against the selected Xcode toolchain's host SwiftSyntax, never project .build.
struct Occurrence: Codable {
    let file: String
    let line: Int
    let arguments: [String]
    let alreadyLocalized: Bool
    let deferredKey: Bool
}
struct InventoryEntry: Codable {
    let key: String
    var occurrences: [Occurrence]
}
struct Inventory: Codable {
    let files: Int
    let occurrences: Int
    let staticKeys: Int
    let formattedKeys: Int
    let entries: [InventoryEntry]
}

func containsChinese(_ value: String) -> Bool {
    value.unicodeScalars.contains { (0x3400...0x9fff).contains($0.value) }
}
func quoted(_ value: String) -> String {
    var output = "\""
    for scalar in value.unicodeScalars {
        switch scalar.value {
        case 0: output += "\\0"
        case 9: output += "\\t"
        case 10: output += "\\n"
        case 13: output += "\\r"
        case 34: output += "\\\""
        case 92: output += "\\\\"
        case 1...31: output += "\\u{\(String(scalar.value, radix: 16))}"
        default: output.unicodeScalars.append(scalar)
        }
    }
    return output + "\""
}
func decoded(_ text: String, pounds: String) -> String {
    let marker = "\\" + pounds
    var index = text.startIndex, output = ""
    while index < text.endIndex {
        guard text[index...].hasPrefix(marker) else { output.append(text[index]); index = text.index(after: index); continue }
        let escape = text.index(index, offsetBy: marker.count)
        guard escape < text.endIndex else { output += marker; break }
        switch text[escape] {
        case "0": output.append("\0")
        case "n": output.append("\n")
        case "r": output.append("\r")
        case "t": output.append("\t")
        case "\\": output.append("\\")
        case "\"": output.append("\"")
        case "'": output.append("'")
        case "\n": break // Swift multiline continuation.
        case "u":
            let brace = text.index(after: escape)
            if brace < text.endIndex, text[brace] == "{", let end = text[brace...].firstIndex(of: "}"),
               let value = UInt32(text[text.index(after: brace)..<end], radix: 16), let scalar = UnicodeScalar(value) {
                output.unicodeScalars.append(scalar); index = text.index(after: end); continue
            }
            output += marker + "u"
        default: output += marker + String(text[escape])
        }
        index = text.index(after: escape)
    }
    return output
}

func directLocalizationCall(_ node: StringLiteralExprSyntax) -> String? {
    guard let argument = node.parent?.as(LabeledExprSyntax.self), argument.expression.id == node.id,
          let call = argument.parent?.parent?.as(FunctionCallExprSyntax.self) else { return nil }
    let name = call.calledExpression.trimmedDescription
    return ["L10n.tr", "L10n.format"].contains(name) ? name : nil
}
func isDemoContent(_ node: StringLiteralExprSyntax) -> Bool {
    var parent = node.parent
    while let current = parent {
        if let declaration = current.as(EnumDeclSyntax.self), declaration.name.text == "DemoLibrary" { return true }
        parent = current.parent
    }
    return false
}
// Catalog labels are keys, not rendered strings. Their picker resolves them in its body.
// Translating a static let here would permanently cache the first selected language.
func isDeferredKey(_ node: StringLiteralExprSyntax) -> Bool {
    var parent = node.parent
    while let current = parent {
        if current.is(EnumCaseElementSyntax.self) { return true } // Raw values are stable identifiers.
        if let declaration = current.as(EnumDeclSyntax.self),
           ["ClientSettingsChoices", "ServerSettingOptions"].contains(declaration.name.text) { return true }
        if let declaration = current.as(ExtensionDeclSyntax.self), declaration.extendedType.trimmedDescription == "ServerLogLevel" { return true }
        parent = current.parent
    }
    return false
}
struct LiteralPlan {
    let key: String
    let arguments: [String]
}
func plan(_ node: StringLiteralExprSyntax) throws -> LiteralPlan? {
    let pounds = node.openingPounds?.text ?? ""
    let hasExpressions = node.segments.contains { $0.is(ExpressionSegmentSyntax.self) }
    var key = "", arguments: [String] = []
    for segment in node.segments {
        if let text = segment.as(StringSegmentSyntax.self) {
            let value = decoded(text.content.text, pounds: pounds)
            key += hasExpressions ? value.replacingOccurrences(of: "%", with: "%%") : value
        } else if let expression = segment.as(ExpressionSegmentSyntax.self) {
            let parts = Array(expression.expressions)
            guard let value = parts.first, value.label == nil else { throw NSError(domain: "Localization", code: 1, userInfo: [NSLocalizedDescriptionKey: "Unsupported interpolation: \(expression.trimmedDescription)"]) }
            let argument: String
            if parts.count == 1 { argument = "String(describing: \(value.expression.trimmedDescription))" }
            else if parts.count == 2, parts[1].label?.text == "specifier" {
                argument = "String(format: \(parts[1].expression.trimmedDescription), locale: Locale(identifier: \"en_US_POSIX\"), \(value.expression.trimmedDescription))"
            } else { throw NSError(domain: "Localization", code: 2, userInfo: [NSLocalizedDescriptionKey: "Unsupported interpolation options: \(expression.trimmedDescription)"]) }
            arguments.append(argument); key += "%\(arguments.count)$@"
        }
    }
    guard containsChinese(key) else { return nil }
    // Current Chinese UI literals are single-line. Do not silently change multiline indentation.
    if node.openingQuote.text == "\"\"\"" { throw NSError(domain: "Localization", code: 3, userInfo: [NSLocalizedDescriptionKey: "Chinese multiline literal requires explicit review"]) }
    return .init(key: key, arguments: arguments)
}

final class Collector: SyntaxVisitor {
    let path: String
    let converter: SourceLocationConverter
    let localizationSource: Bool
    var values: [(String, Occurrence)] = []
    var failures: [String] = []
    init(path: String, tree: SourceFileSyntax) {
        self.path = path; converter = SourceLocationConverter(fileName: path, tree: tree)
        localizationSource = path.contains("/Localization/")
        super.init(viewMode: .sourceAccurate)
    }
    override func visit(_ node: StringLiteralExprSyntax) -> SyntaxVisitorContinueKind {
        guard !isDemoContent(node), !localizationSource || directLocalizationCall(node) != nil else { return .skipChildren }
        do {
            if let literal = try plan(node) {
                values.append((literal.key, .init(file: path, line: converter.location(for: node.positionAfterSkippingLeadingTrivia).line,
                                                 arguments: literal.arguments, alreadyLocalized: directLocalizationCall(node) != nil,
                                                 deferredKey: isDeferredKey(node))))
            }
        } catch { failures.append("\(path):\(converter.location(for: node.positionAfterSkippingLeadingTrivia).line): \(error.localizedDescription)") }
        return .visitChildren
    }
}
final class Migrator: SyntaxRewriter {
    var changed = 0
    override func visit(_ node: StringLiteralExprSyntax) -> ExprSyntax {
        guard !isDemoContent(node), !isDeferredKey(node), directLocalizationCall(node) == nil else { return ExprSyntax(node) }
        // Rewriting children first localizes static ternary branches without changing the outer key.
        let rewritten = super.visit(node).cast(StringLiteralExprSyntax.self)
        guard let literal = try? plan(rewritten) else { return ExprSyntax(rewritten) }
        let invocation: String
        if literal.arguments.isEmpty { invocation = "L10n.tr(\(quoted(literal.key)))" }
        else { invocation = "L10n.format(\(quoted(literal.key)), \(literal.arguments.joined(separator: ", ")))" }
        changed += 1
        return ExprSyntax(stringLiteral: invocation).with(\.leadingTrivia, node.leadingTrivia).with(\.trailingTrivia, node.trailingTrivia)
    }
}

@main struct Main {
    static func main() throws {
        let arguments = CommandLine.arguments
        guard arguments.count >= 3, ["inventory", "migrate"].contains(arguments[1]) else {
            FileHandle.standardError.write(Data("Usage: localize-sources inventory|migrate PROJECT_ROOT [INVENTORY_JSON]\n".utf8)); exit(2)
        }
        let mode = arguments[1], root = URL(fileURLWithPath: arguments[2]).standardizedFileURL
        let sourceRoot = root.appendingPathComponent("Sources/Audilse")
        let paths = (FileManager.default.enumerator(at: sourceRoot, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? []).filter { $0.pathExtension == "swift" }.sorted { $0.path < $1.path }
        var entries: [String: [Occurrence]] = [:], files = 0, failures: [String] = []
        var updates: [(url: URL, original: String, replacement: String)] = []
        for path in paths {
            let original = try String(contentsOf: path, encoding: .utf8), tree = Parser.parse(source: original)
            guard !tree.hasError else { failures.append("\(path.path): Swift parser reported an error"); continue }
            let collector = Collector(path: String(path.path.dropFirst(root.path.count + 1)), tree: tree)
            collector.walk(tree); failures += collector.failures
            if !collector.values.isEmpty { files += 1 }
            for (key, occurrence) in collector.values { entries[key, default: []].append(occurrence) }
            if mode == "migrate", !path.path.contains("/Localization/") {
                let migrator = Migrator(viewMode: .sourceAccurate), rewritten = migrator.rewrite(tree).description
                if migrator.changed > 0 { updates.append((path, original, rewritten)) }
            }
        }
        guard failures.isEmpty else { FileHandle.standardError.write(Data((failures.joined(separator: "\n") + "\n").utf8)); exit(1) }
        let rows = entries.keys.sorted().map { InventoryEntry(key: $0, occurrences: entries[$0]!) }
        let formatted = rows.filter { $0.occurrences.contains { !$0.arguments.isEmpty } }.count
        let inventory = Inventory(files: files, occurrences: rows.reduce(0) { $0 + $1.occurrences.count }, staticKeys: rows.count - formatted, formattedKeys: formatted, entries: rows)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        if arguments.count > 3 { try encoder.encode(inventory).write(to: URL(fileURLWithPath: arguments[3]), options: .atomic) }
        else { FileHandle.standardOutput.write(try encoder.encode(inventory)); FileHandle.standardOutput.write(Data("\n".utf8)) }
        if mode == "migrate" {
            // Abort before the first write if a cooperating agent edited any snapshot.
            for update in updates where try String(contentsOf: update.url, encoding: .utf8) != update.original {
                throw NSError(domain: "Localization", code: 4, userInfo: [NSLocalizedDescriptionKey: "Concurrent edit: \(update.url.path)"])
            }
            let backup = FileManager.default.temporaryDirectory.appendingPathComponent("shelf-localization-backup-" + UUID().uuidString)
            for update in updates {
                let relative = String(update.url.path.dropFirst(root.path.count + 1)), saved = backup.appendingPathComponent(relative)
                try FileManager.default.createDirectory(at: saved.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data(update.original.utf8).write(to: saved)
                try Data(update.replacement.utf8).write(to: update.url, options: .atomic)
            }
            FileHandle.standardError.write(Data("Migrated \(updates.count) files; original snapshots: \(backup.path)\n".utf8))
        }
        FileHandle.standardError.write(Data("Inventory: \(inventory.occurrences) occurrences, \(rows.count) keys (\(inventory.staticKeys) static, \(formatted) formatted), \(files) files\n".utf8))
    }
}
