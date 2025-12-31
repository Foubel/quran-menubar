import XCTest
@testable import QuranMenubar

final class SurahSelectionLogicTests: XCTestCase {
    private let surahs: [QuranPlayer.Surah] = [
        .init(number: 1, nameFr: "Al-Fatiha", nameAr: "الفاتحة", verses: 7, audioFile: "01-Al-Fatiha.mp3", durationSeconds: 360),
        .init(number: 2, nameFr: "Al-Baqara", nameAr: "البقرة", verses: 286, audioFile: "02-Al-Baqara.mp3", durationSeconds: 6120),
        .init(number: 3, nameFr: "Al-Imran", nameAr: "آل عمران", verses: 200, audioFile: "03-Al-Imran.mp3", durationSeconds: 4520)
    ]

    func testSelectionAfterFilteringKeepsPreviousWhenStillPresent() {
        let selection = SurahSelectionLogic.selectionAfterFiltering(
            previousSelection: 2,
            filteredSurahs: surahs
        )
        XCTAssertEqual(selection, 2)
    }

    func testSelectionAfterFilteringFallsBackToFirstWhenPreviousMissing() {
        let filtered = Array(surahs.dropFirst())
        let selection = SurahSelectionLogic.selectionAfterFiltering(
            previousSelection: 1,
            filteredSurahs: filtered
        )
        XCTAssertEqual(selection, 2)
    }

    func testSelectionAfterFilteringReturnsNilWhenListEmpty() {
        let selection = SurahSelectionLogic.selectionAfterFiltering(
            previousSelection: 2,
            filteredSurahs: []
        )
        XCTAssertNil(selection)
    }

    func testSelectionAfterCurrentChangeAlignsWithCurrentSurah() {
        let selection = SurahSelectionLogic.selectionAfterCurrentChange(
            currentSurahID: 3,
            currentSelection: 2,
            filteredSurahs: surahs
        )
        XCTAssertEqual(selection, 3)
    }

    func testSelectionAfterCurrentChangeIgnoresWhenCurrentNotInFiltered() {
        let filtered = Array(surahs.dropFirst())
        let selection = SurahSelectionLogic.selectionAfterCurrentChange(
            currentSurahID: 1,
            currentSelection: 2,
            filteredSurahs: filtered
        )
        XCTAssertEqual(selection, 2)
    }

    func testSelectionAfterCurrentChangeKeepsSelectionWhenCurrentNil() {
        let selection = SurahSelectionLogic.selectionAfterCurrentChange(
            currentSurahID: nil,
            currentSelection: 2,
            filteredSurahs: surahs
        )
        XCTAssertEqual(selection, 2)
    }
}
