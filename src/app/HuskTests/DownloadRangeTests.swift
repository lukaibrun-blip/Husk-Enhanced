// SPDX-License-Identifier: GPL-2.0-or-later
import XCTest

final class DownloadRangeTests: XCTestCase {
    func testParsesSatisfiableRangeAndKnownTotal() {
        let range = downloadContentRange("bytes 5-9/10", 5)

        XCTAssertEqual(range?.total, 10)
        XCTAssertEqual(range?.end, 9)
        XCTAssertEqual(range?.bodyLength, 5)
    }

    func testParsesUnknownTotalWithoutTreatingRangeEndAsEOF() {
        let range = downloadContentRange("bytes 5-9/*", 5)

        XCTAssertNil(range?.total)
        XCTAssertEqual(range?.end, 9)
        XCTAssertEqual(range?.bodyLength, 5)
    }

    func testRejectsMalformedOrOverflowingRanges() {
        XCTAssertNil(downloadContentRange("items 5-9/10", 5))
        XCTAssertNil(downloadContentRange("bytes 5-9/10", 4))
        XCTAssertNil(downloadContentRange("bytes 9-5/10", 9))
        XCTAssertNil(downloadContentRange("bytes 5-10/10", 5))
        XCTAssertNil(downloadContentRange("bytes 0-9223372036854775807/*", 0))
        XCTAssertNil(downloadContentRange("bytes +5-9/10", 5))
    }

    func testParsesUnsatisfiedRangeTotal() {
        XCTAssertEqual(downloadUnsatisfiedRangeTotal("bytes */10"), 10)
        XCTAssertEqual(downloadUnsatisfiedRangeTotal("BYTES */0"), 0)
        XCTAssertNil(downloadUnsatisfiedRangeTotal("bytes */*"))
        XCTAssertNil(downloadUnsatisfiedRangeTotal("bytes */-1"))
        XCTAssertNil(downloadUnsatisfiedRangeTotal("items */10"))
    }
}
