// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

enum APKIngestPlan {
    enum Kind: Equatable {
        case apk
        case obb
        case bundle
    }

    struct Entry {
        let kind: Kind
        let packageName: String?
        let isSplit: Bool
        let name: String
    }

    enum Failure: LocalizedError, Equatable {
        case multipleBaseAPKs(String)
        case unmatchedExpansionFile(String)
        case emptyApp

        var errorDescription: String? {
            switch self {
            case .multipleBaseAPKs(let package):
                return "More than one base APK for \(package) was selected. Add one version at a time."
            case .unmatchedExpansionFile(let name):
                return "Husk could not match the expansion file \(name) to an app. Add it with that app's APKs."
            case .emptyApp:
                return "No APK was found for one of the selected app groups."
            }
        }
    }

    private struct Group {
        var isBundle = false
        var hasBase = false
        var hasAPK = false
        var entries: [Int] = []
    }

    /// Bundles always remain intact. Separate APKs with a readable package name are grouped by that name so real splits
    /// stay beside their base; unreadable packages are kept separate rather than guessed to belong together.
    static func groups(for entries: [Entry]) throws -> [[Int]] {
        var groups: [Group] = []
        var packageGroups: [String: Int] = [:]
        var expansionFiles: [Int] = []

        for (index, entry) in entries.enumerated() {
            switch entry.kind {
            case .obb:
                expansionFiles.append(index)
            case .bundle:
                groups.append(Group(isBundle: true, hasBase: false, hasAPK: true, entries: [index]))
            case .apk:
                guard let package = entry.packageName, !package.isEmpty else {
                    groups.append(Group(hasBase: !entry.isSplit, hasAPK: true, entries: [index]))
                    continue
                }
                let groupIndex: Int
                if let existing = packageGroups[package] {
                    groupIndex = existing
                } else {
                    groupIndex = groups.count
                    packageGroups[package] = groupIndex
                    groups.append(Group())
                }
                if !entry.isSplit {
                    guard !groups[groupIndex].hasBase else { throw Failure.multipleBaseAPKs(package) }
                    groups[groupIndex].hasBase = true
                }
                groups[groupIndex].hasAPK = true
                groups[groupIndex].entries.append(index)
            }
        }

        for index in expansionFiles {
            let entry = entries[index]
            if let package = entry.packageName, let groupIndex = packageGroups[package] {
                groups[groupIndex].entries.append(index)
            } else if entry.packageName != nil {
                let appGroups = groups.indices.filter { groups[$0].hasAPK }
                let bundleGroups = groups.indices.filter { groups[$0].isBundle }
                guard appGroups.count == 1, bundleGroups.count == 1, let groupIndex = bundleGroups.first else {
                    throw Failure.unmatchedExpansionFile(entry.name)
                }
                groups[groupIndex].entries.append(index)
            } else {
                let appGroups = groups.indices.filter { groups[$0].hasAPK }
                guard appGroups.count == 1, let groupIndex = appGroups.first else {
                    throw Failure.unmatchedExpansionFile(entry.name)
                }
                groups[groupIndex].entries.append(index)
            }
        }

        return groups.map(\.entries)
    }

    /// Keep archive names intact unless a case-insensitive name collision would overwrite another selected file.
    static func uniqueName(_ name: String, occupied: Set<String>) -> String {
        let path = name as NSString
        let ext = path.pathExtension
        let stem = ext.isEmpty ? name : path.deletingPathExtension
        var suffix = 2
        var candidate = name
        while occupied.contains(candidate.lowercased()) {
            candidate = ext.isEmpty ? "\(stem)-\(suffix)" : "\(stem)-\(suffix).\(ext)"
            suffix += 1
        }
        return candidate
    }
}
