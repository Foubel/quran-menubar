import XCTest
@testable import QuranMenubar

final class SurahSearchTests: XCTestCase {
    private let surahs: [QuranPlayer.Surah] = [
        .init(number: 1, nameFr: "Al-Fatiha", nameAr: "الفاتحة", verses: 7, audioFile: "01-Al-Fatiha.mp3", durationSeconds: 360),
        .init(number: 18, nameFr: "Al-Kahf", nameAr: "الكهف", verses: 110, audioFile: "18-Al-Kahf.mp3", durationSeconds: 2600),
        .init(number: 36, nameFr: "Ya-Sin", nameAr: "يٰسٓ", verses: 83, audioFile: "36-Ya-Sin.mp3", durationSeconds: 1500),
        .init(number: 112, nameFr: "Al-Ikhlas", nameAr: "الإخلاص", verses: 4, audioFile: "112-Al-Ikhlas.mp3", durationSeconds: 90)
    ]

    func testNormalizeRemovesDiacriticsAndSpaces() {
        let result = SurahSearch.normalize("  Âl-Kâhf  ")
        XCTAssertEqual(result, "alkahf")
    }

    func testNormalizeKeepsNumbers() {
        let result = SurahSearch.normalize("012 Al-Kahf")
        XCTAssertEqual(result, "012alkahf")
    }

    func testFilterEmptyQueryReturnsAllSurahs() {
        let filtered = SurahSearch.filter(surahs: surahs, query: "")
        XCTAssertEqual(filtered.count, surahs.count)
    }

    func testFilterMatchesFrenchNameIgnoringDiacritics() {
        let filtered = SurahSearch.filter(surahs: surahs, query: "yasn")
        XCTAssertEqual(filtered.map(\.number), [36])
    }

    func testFilterMatchesArabicName() {
        let filtered = SurahSearch.filter(surahs: surahs, query: "الإخلاص")
        XCTAssertEqual(filtered.map(\.number), [112])
    }

    func testFilterMatchesNumber() {
        let filtered = SurahSearch.filter(surahs: surahs, query: "18")
        XCTAssertEqual(filtered.map(\.number), [18])
    }

    func testFilterMatchesPartialWords() {
        let filtered = SurahSearch.filter(surahs: surahs, query: "ikhl")
        XCTAssertEqual(filtered.map(\.number), [112])
    }
}
