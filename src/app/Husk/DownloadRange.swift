// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

struct DownloadContentRange {
    let total: Int64?
    let end: Int64
    let bodyLength: Int64
}

private func downloadRangeInteger(_ value: Substring) -> Int64? {
    guard !value.isEmpty, value.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }) else { return nil }
    return Int64(value)
}

func downloadContentRange(_ value: String?, _ offset: Int64) -> DownloadContentRange? {
    guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
          value.lowercased().hasPrefix("bytes ") else { return nil }
    let rangeAndTotal = value.dropFirst(6).split(separator: "/", maxSplits: 1)
    guard rangeAndTotal.count == 2 else { return nil }
    let total = rangeAndTotal[1] == "*" ? nil : downloadRangeInteger(rangeAndTotal[1])
    guard rangeAndTotal[1] == "*" || (total.map { $0 > 0 } ?? false) else { return nil }
    let bounds = rangeAndTotal[0].split(separator: "-", maxSplits: 1)
    guard bounds.count == 2,
          let start = downloadRangeInteger(bounds[0]), let end = downloadRangeInteger(bounds[1]),
          start == offset, end >= start, total.map({ end < $0 }) ?? true else { return nil }
    let (difference, differenceOverflow) = end.subtractingReportingOverflow(start)
    let (bodyLength, lengthOverflow) = difference.addingReportingOverflow(1)
    guard !differenceOverflow, !lengthOverflow else { return nil }
    return DownloadContentRange(total: total, end: end, bodyLength: bodyLength)
}

func downloadUnsatisfiedRangeTotal(_ value: String?) -> Int64? {
    guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
          value.lowercased().hasPrefix("bytes */"),
          let total = downloadRangeInteger(value.dropFirst(7)) else { return nil }
    return total
}
