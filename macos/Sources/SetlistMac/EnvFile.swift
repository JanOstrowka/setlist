import Foundation

/// A minimal `.env`-style settings file: `KEY=value` lines, `#` comments,
/// optional single or double quotes around values. Edits replace the
/// matching line in place and keep every other line (including comments)
/// untouched, so a hand-edited file survives the Settings window and the
/// Settings window survives hand edits.
///
/// The grammar mirrors what python-dotenv accepts, because the same file
/// is handed to the engine via `uvicorn --env-file`.
struct EnvFile: Equatable {
    private(set) var lines: [String]

    init(contents: String = "") {
        var lines = contents.components(separatedBy: .newlines)
        // A trailing newline produces one empty final element; drop it so
        // repeated load/save cycles never grow the file.
        if lines.last == "" {
            lines.removeLast()
        }
        self.lines = lines
    }

    init(contentsOf url: URL) {
        let contents = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        self.init(contents: contents)
    }

    var contents: String {
        lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
    }

    /// The value of `key`, or `nil` when the key is absent. Like dotenv,
    /// the last assignment wins. An assignment to nothing (`KEY=`) reads
    /// as an empty string, which callers usually treat as unset.
    func value(for key: String) -> String? {
        var result: String?
        for line in lines {
            if let entry = Self.parse(line), entry.key == key {
                result = entry.value
            }
        }
        return result
    }

    /// Replaces the last assignment of `key`, or appends one. Passing
    /// `nil` writes `KEY=` so the key stays discoverable in the file.
    mutating func set(_ value: String?, for key: String) {
        let rendered = "\(key)=\(Self.render(value ?? ""))"
        if let index = lines.lastIndex(where: { Self.parse($0)?.key == key }) {
            lines[index] = rendered
        } else {
            lines.append(rendered)
        }
    }

    func write(to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try contents.write(to: url, atomically: true, encoding: .utf8)
        // Settings may hold API keys: keep the file private to the user.
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )
    }

    // MARK: - Line grammar

    static func parse(_ rawLine: String) -> (key: String, value: String)? {
        var line = rawLine.trimmingCharacters(in: .whitespaces)
        guard !line.isEmpty, !line.hasPrefix("#") else {
            return nil
        }
        if line.hasPrefix("export ") {
            line = String(line.dropFirst("export ".count))
                .trimmingCharacters(in: .whitespaces)
        }
        guard let separator = line.firstIndex(of: "=") else {
            return nil
        }
        let key = line[..<separator].trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty, !key.contains(where: \.isWhitespace) else {
            return nil
        }
        let rawValue = line[line.index(after: separator)...]
            .trimmingCharacters(in: .whitespaces)
        return (key, unquote(rawValue))
    }

    private static func unquote(_ raw: String) -> String {
        guard let first = raw.first else {
            return ""
        }
        if first == "\"" {
            var result = ""
            var escaped = false
            for character in raw.dropFirst() {
                if escaped {
                    result.append(character)
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == "\"" {
                    return result
                } else {
                    result.append(character)
                }
            }
            return result
        }
        if first == "'" {
            let body = raw.dropFirst()
            if let end = body.firstIndex(of: "'") {
                return String(body[..<end])
            }
            return String(body)
        }
        // Unquoted values end at an inline comment (` #`), like dotenv.
        if let range = raw.range(of: " #") {
            return raw[..<range.lowerBound]
                .trimmingCharacters(in: .whitespaces)
        }
        return raw
    }

    /// Quotes a value whenever a bare token would be misread on the way
    /// back in (spaces, `#`, quotes, backslashes, or leading/trailing
    /// whitespace).
    static func render(_ value: String) -> String {
        let needsQuotes = value.isEmpty == false && (
            value.contains(where: \.isWhitespace)
                || value.contains("#")
                || value.contains("\"")
                || value.contains("'")
                || value.contains("\\")
        )
        guard needsQuotes else {
            return value
        }
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}
