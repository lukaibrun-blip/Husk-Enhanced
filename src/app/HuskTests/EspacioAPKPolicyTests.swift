// SPDX-License-Identifier: GPL-2.0-or-later
import XCTest

final class EspacioAPKPolicyTests: XCTestCase {
    func testOnlyHTTPSArticlesOnTheExactEspacioAPKHostAreAllowed() {
        XCTAssertNotNil(EspacioAPKPolicy.articleURL("https://espacioapk.com/juegos/game/"))
        XCTAssertNotNil(EspacioAPKPolicy.articleURL("https://ESPACIOAPK.COM/aplicaciones/app"))
        XCTAssertNil(EspacioAPKPolicy.articleURL("http://espacioapk.com/game"))
        XCTAssertNil(EspacioAPKPolicy.articleURL("https://espacioapk.com.evil.example/game"))
        XCTAssertNil(EspacioAPKPolicy.articleURL("https://evil.example/https://espacioapk.com/game"))
        XCTAssertNil(EspacioAPKPolicy.articleURL("https://user@espacioapk.com/game"))
        XCTAssertNil(EspacioAPKPolicy.articleURL("https://espacioapk.com:444/game"))
        XCTAssertNil(EspacioAPKPolicy.articleURL("https://espacioapk.com/"))
        XCTAssertNil(EspacioAPKPolicy.articleURL("https://espacioapk.com/next/full?url=third-party"))
        XCTAssertNil(EspacioAPKPolicy.articleURL("https://espacioapk.com/game/download/"))
        XCTAssertNil(EspacioAPKPolicy.articleURL("https://espacioapk.com/wp-json/wp/v2/posts"))
        XCTAssertNil(EspacioAPKPolicy.articleURL("https://espacioapk.com/game?redirect=https://evil.example"))
        XCTAssertNil(EspacioAPKPolicy.articleURL("https://espacioapk.com/game#download"))
        XCTAssertNotNil(EspacioAPKPolicy.catalogURL("https://espacioapk.com/wp-json/wp/v2/posts?search=game"))
        XCTAssertNil(EspacioAPKPolicy.catalogURL("https://espacioapk.com/wp-json/espacioapk/v1/download"))
    }

    func testGamblingIsFilteredFromTextEvenOutsideCasinoCategory() {
        let post = EspacioAPKPost(id: 1, date: nil, slug: "sports", link: nil,
                                  title: EspacioAPKRendered(rendered: "1win sports bonus"),
                                  excerpt: nil, content: nil, categories: nil)

        XCTAssertFalse(EspacioAPKPolicy.isAllowed(post, categoryNames: ["Deportes"]))
        XCTAssertFalse(EspacioAPKPolicy.isAllowed(post, categoryNames: ["Apps"]))
        XCTAssertTrue(EspacioAPKPolicy.containsRestrictedGamblingContent("oferta de apostas deportivas"))
        XCTAssertTrue(EspacioAPKPolicy.containsRestrictedGamblingContent("juego de azar"))
        let safePost = EspacioAPKPost(id: 2, date: nil, slug: "game", link: nil,
                                      title: EspacioAPKRendered(rendered: "A puzzle game"), excerpt: nil,
                                      content: nil, categories: nil)
        XCTAssertTrue(EspacioAPKPolicy.isAllowed(safePost, categoryNames: ["Games"]))
        XCTAssertFalse(EspacioAPKPolicy.isAllowed(safePost, categoryNames: ["Casino"]))
    }

    func testModifiedContentClaimsAreExplicitlyMarked() {
        XCTAssertTrue(EspacioAPKPolicy.claimsModifiedContent("Among Us MOD menu"))
        XCTAssertTrue(EspacioAPKPolicy.claimsModifiedContent("Versión modificada"))
        XCTAssertTrue(EspacioAPKPolicy.claimsModifiedContent("Juego modificado"))
        XCTAssertTrue(EspacioAPKPolicy.claimsModifiedContent("Aplicaciones modificadas"))
        XCTAssertFalse(EspacioAPKPolicy.claimsModifiedContent("Among Us official listing"))
    }
}
