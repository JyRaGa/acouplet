import Foundation

struct DiagnosticHistory {
    static let maximumEvents = 120
    static let maximumLineBytes = 256
    private(set) var events: [String] = []
    private(set) var lastFailure: String?

    mutating func record(_ message: String, failure: Bool = false, redacting names: [String] = [], at date: Date = Date()) {
        let timestamp = date.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: true).timeZone(separator: .omitted))
        let line = Self.line("\(timestamp) \(message)", redacting: names)
        if events.count == Self.maximumEvents { events.removeFirst() }
        events.append(line)
        if failure { lastFailure = line }
    }

    var report: String {
        (["Last recorded failure (may be from an earlier attempt): \(lastFailure ?? "None")",
          "Recent events (oldest first; up to \(Self.maximumEvents), memory only, retained across reconnects):"]
         + (events.isEmpty ? ["None"] : events)).map { Self.line($0) }.joined(separator: "\n")
    }

    static func line(_ message: String, redacting names: [String] = []) -> String {
        var value = message
        for name in names.filter({ !$0.isEmpty }).sorted(by: { $0.count > $1.count }) {
            let pattern = #"(?i)(?<![\p{L}\p{N}])"# + NSRegularExpression.escapedPattern(for: name) + #"(?![\p{L}\p{N}])"#
            value = value.replacingOccurrences(of: pattern, with: "[name omitted]", options: .regularExpression)
        }
        for pattern in [
            #"(?i)\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b"#,
            #"(?i)\b(?:(?:[0-9a-f]{2}[:-]){5}[0-9a-f]{2}|[0-9a-f]{12})\b"#,
            #"(?i)(?:file://)?/(?:Users|home)/[^\r\n]+"#,
            #"~/[^\r\n]+"#,
        ] {
            value = value.replacingOccurrences(of: pattern, with: "[omitted]", options: .regularExpression)
        }
        value = value.unicodeScalars.map { CharacterSet.controlCharacters.contains($0) || CharacterSet.newlines.contains($0) ? " " : String($0) }.joined()
        guard value.utf8.count > maximumLineBytes else { return value }
        return String(decoding: value.utf8.prefix(maximumLineBytes - 6), as: UTF8.self) + "…"
    }

    static var environmentReport: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "Unknown"
        #if arch(arm64)
        let architecture = "arm64"
        #elseif arch(x86_64)
        let architecture = "x86_64"
        #else
        let architecture = "Unknown"
        #endif
        #if ACOUPLET_PUBLIC_APIS_ONLY
        let variant = "Public APIs"
        #else
        let variant = "Full"
        #endif
        return ["App: Acouplet \(version) (build \(build)); \(variant)",
                "macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)",
                "Process architecture: \(architecture)"].map { line($0) }.joined(separator: "\n")
    }
}
