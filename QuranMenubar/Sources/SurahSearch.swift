import Foundation

struct SurahSearch {
    static func normalize(_ string: String) -> String {
        let folded = string.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
        let lowercased = folded.lowercased()
        let allowed = CharacterSet.letters.union(.decimalDigits)
        let scalars = lowercased.unicodeScalars.filter { allowed.contains($0) }
        return String(String.UnicodeScalarView(scalars))
    }

    static func filter(surahs: [QuranPlayer.Surah], query: String) -> [QuranPlayer.Surah] {
        let normalized = normalize(query)
        guard !normalized.isEmpty else {
            return surahs
        }
        return surahs.filter { surah in
            let normalizedFr = normalize(surah.nameFr)
            let normalizedAr = normalize(surah.nameAr)
            let normalizedNumber = normalize(String(surah.number))
            return normalizedFr.contains(normalized) ||
                normalizedAr.contains(normalized) ||
                normalizedNumber.contains(normalized)
        }
    }
}
