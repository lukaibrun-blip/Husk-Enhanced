// SPDX-License-Identifier: GPL-2.0-or-later
import XCTest

final class AppUpdateSupportTests: XCTestCase {
    func testComparesNumericVersionComponents() {
        XCTAssertTrue(AppUpdateSupport.isNewer("3.4.10", than: "3.4.9"))
        XCTAssertTrue(AppUpdateSupport.isNewer("v4.0", than: "3.99.99"))
        XCTAssertFalse(AppUpdateSupport.isNewer("3.4", than: "3.4.0"))
        XCTAssertFalse(AppUpdateSupport.isNewer("3.3.9", than: "3.4"))
    }

    func testNormalizesOnlyNumericReleaseTags() {
        XCTAssertEqual(AppUpdateSupport.normalizedVersion("v3.4.1"), "3.4.1")
        XCTAssertEqual(AppUpdateSupport.normalizedVersion("3.4"), "3.4")
        XCTAssertNil(AppUpdateSupport.normalizedVersion("release-3.4"))
        XCTAssertNil(AppUpdateSupport.normalizedVersion("3..4"))
        XCTAssertNil(AppUpdateSupport.normalizedVersion("3.4-beta"))
    }

    func testSummarizesMarkdownReleaseNotesAndLimitsLength() {
        let notes = "## What's new?\n\nHusk runs faster.\n\n### Fixes\n- Crash resolved\n- Better UI"
        XCTAssertEqual(AppUpdateSupport.summary(from: notes), "Husk runs faster. Crash resolved Better UI")
        XCTAssertEqual(AppUpdateSupport.summary(from: "A long note", maxLength: 5), "A lo…")
        XCTAssertEqual(AppUpdateSupport.summary(from: "## Notes"), "Bug fixes and improvements.")
    }
}
