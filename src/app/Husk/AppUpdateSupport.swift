// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

/// Small, Foundation-only helpers for comparing release tags and presenting release notes.
enum AppUpdateSupport {
    static func normalizedVersion(_ tag: String) -> String? {
        let version = tag.hasPrefix("v") || tag.hasPrefix("V") ? String(tag.dropFirst()) : tag
        let parts = version.split(separator: ".", omittingEmptySubsequences: false)
        guard !parts.isEmpty, parts.allSatisfy({ part in
            !part.isEmpty && part.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }) && Int(part) != nil
        }) else { return nil }
        return version
    }

    /// Compare dotted numeric versions, so 3.4.10 sorts after 3.4.9.
    static func isNewer(_ candidate: String, than installed: String) -> Bool {
        guard let candidate = normalizedVersion(candidate),
              let installed = normalizedVersion(installed) else { return false }
        let left = candidate.split(separator: ".").map { Int($0)! }
        let right = installed.split(separator: ".").map { Int($0)! }
        for index in 0..<max(left.count, right.count) {
            let a = index < left.count ? left[index] : 0
            let b = index < right.count ? right[index] : 0
            if a != b { return a > b }
        }
        return false
    }

    /// A short, readable preview of GitHub's Markdown release notes for the alert and Settings.
    static func summary(from notes: String, maxLength: Int = 360) -> String {
        let lines = notes.components(separatedBy: .newlines).compactMap { raw -> String? in
            var line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.hasPrefix("#") else { return nil }
            if line.hasPrefix("- ") || line.hasPrefix("* ") { line.removeFirst(2) }
            guard !line.isEmpty, !line.hasPrefix("**Full Changelog**") else { return nil }
            return line
        }
        let joined = lines.prefix(3).joined(separator: " ")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let text = joined.isEmpty ? "Bug fixes and improvements." : joined
        guard maxLength > 0 else { return "" }
        guard text.count > maxLength else { return text }
        guard maxLength > 1 else { return "…" }
        return String(text.prefix(maxLength - 1)).trimmingCharacters(in: .whitespacesAndNewlines) + "…"
    }
}
