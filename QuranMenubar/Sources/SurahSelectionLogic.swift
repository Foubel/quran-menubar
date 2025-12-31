import Foundation

struct SurahSelectionLogic {
    static func selectionAfterFiltering(previousSelection: QuranPlayer.Surah.ID?, filteredSurahs: [QuranPlayer.Surah]) -> QuranPlayer.Surah.ID? {
        guard !filteredSurahs.isEmpty else {
            return nil
        }
        if let previousSelection,
           filteredSurahs.contains(where: { $0.id == previousSelection }) {
            return previousSelection
        }
        return filteredSurahs.first?.id
    }

    static func selectionAfterCurrentChange(currentSurahID: QuranPlayer.Surah.ID?, currentSelection: QuranPlayer.Surah.ID?, filteredSurahs: [QuranPlayer.Surah]) -> QuranPlayer.Surah.ID? {
        guard let currentSurahID else {
            return currentSelection
        }
        guard filteredSurahs.contains(where: { $0.id == currentSurahID }) else {
            return currentSelection
        }
        return currentSurahID
    }
}
