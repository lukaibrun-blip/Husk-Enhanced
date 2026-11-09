// SPDX-License-Identifier: GPL-2.0-or-later
import XCTest

final class APKIngestPlanTests: XCTestCase {
    private func apk(_ package: String?, split: Bool = false, name: String = "game.apk") -> APKIngestPlan.Entry {
        APKIngestPlan.Entry(kind: .apk, packageName: package, isSplit: split, name: name)
    }

    func testSeparatePackagesBecomeSeparateApps() throws {
        let groups = try APKIngestPlan.groups(for: [
            apk("com.example.first"), apk("com.example.second")
        ])

        XCTAssertEqual(groups, [[0], [1]])
    }

    func testBaseAndManifestSplitsStayTogether() throws {
        let groups = try APKIngestPlan.groups(for: [
            apk("com.example.game", split: true, name: "config.arm64.apk"),
            apk("com.example.game", name: "base.apk"),
            apk("com.example.game", split: true, name: "config.en.apk")
        ])

        XCTAssertEqual(groups, [[0, 1, 2]])
    }

    func testBundlesRemainSeparateFromStandaloneAPKs() throws {
        let bundle = APKIngestPlan.Entry(kind: .bundle, packageName: nil, isSplit: false, name: "game.apks")
        let groups = try APKIngestPlan.groups(for: [bundle, apk("com.example.game")])

        XCTAssertEqual(groups, [[0], [1]])
    }

    func testUnrecognizedAPKManifestsAreNotGroupedByGuess() throws {
        let groups = try APKIngestPlan.groups(for: [apk(nil), apk(nil)])

        XCTAssertEqual(groups, [[0], [1]])
    }

    func testDuplicateBaseAPKIsRejectedInsteadOfCombiningVersions() {
        XCTAssertThrowsError(try APKIngestPlan.groups(for: [
            apk("com.example.game", name: "old.apk"), apk("com.example.game", name: "new.apk")
        ])) { error in
            XCTAssertEqual(error as? APKIngestPlan.Failure, .multipleBaseAPKs("com.example.game"))
        }
    }

    func testExpansionFileFollowsMatchingPackage() throws {
        let obb = APKIngestPlan.Entry(kind: .obb, packageName: "com.example.game", isSplit: false, name: "main.1.com.example.game.obb")
        let groups = try APKIngestPlan.groups(for: [apk("com.example.other"), apk("com.example.game"), obb])

        XCTAssertEqual(groups, [[0], [1, 2]])
    }

    func testExpansionFileStaysWithItsOnlyBundle() throws {
        let bundle = APKIngestPlan.Entry(kind: .bundle, packageName: nil, isSplit: false, name: "game.xapk")
        let obb = APKIngestPlan.Entry(kind: .obb, packageName: "com.example.game", isSplit: false, name: "main.1.com.example.game.obb")

        XCTAssertEqual(try APKIngestPlan.groups(for: [bundle, obb]), [[0, 1]])
    }

    func testUnmatchedExpansionFileIsRejected() {
        let obb = APKIngestPlan.Entry(kind: .obb, packageName: "com.example.missing", isSplit: false, name: "main.1.com.example.missing.obb")

        XCTAssertThrowsError(try APKIngestPlan.groups(for: [apk("com.example.game"), obb])) { error in
            XCTAssertEqual(error as? APKIngestPlan.Failure, .unmatchedExpansionFile(obb.name))
        }
    }

    func testFilenameCollisionGetsStableSuffix() {
        XCTAssertEqual(APKIngestPlan.uniqueName("base.apk", occupied: ["base.apk"]), "base-2.apk")
        XCTAssertEqual(APKIngestPlan.uniqueName("BASE.apk", occupied: ["base.apk", "base-2.apk"]), "BASE-3.apk")
    }
}
