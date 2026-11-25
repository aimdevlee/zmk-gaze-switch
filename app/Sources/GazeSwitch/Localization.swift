import Foundation

/// Languages the app speaks. Every user-facing string is written at its call
/// site in all three, via `tr(_:_:_:)`, so a missing translation can't compile.
enum Language: String, CaseIterable {
    case ko, en, ja

    /// Name shown in the language menu, in the language itself.
    var displayName: String {
        switch self {
        case .ko: return "한국어"
        case .en: return "English"
        case .ja: return "日本語"
        }
    }

    /// BCP 47 code for the voice that reads calibration steps aloud.
    var voiceCode: String {
        switch self {
        case .ko: return "ko-KR"
        case .en: return "en-US"
        case .ja: return "ja-JP"
        }
    }

    private static let defaultsKey = "language"

    /// The user's explicit pick; nil means "follow the system".
    static var chosen: Language? {
        get { UserDefaults.standard.string(forKey: defaultsKey).flatMap(Language.init(rawValue:)) }
        set {
            if let newValue {
                UserDefaults.standard.set(newValue.rawValue, forKey: defaultsKey)
            } else {
                UserDefaults.standard.removeObject(forKey: defaultsKey)
            }
            current = newValue ?? system
        }
    }

    /// First of the system's preferred languages that we support.
    static var system: Language {
        for tag in Locale.preferredLanguages {
            if let match = Language(rawValue: String(tag.prefix(2))) { return match }
        }
        return .en
    }

    private(set) static var current: Language = chosen ?? system
}

/// Picks the text for the current language.
func tr(_ ko: String, _ en: String, _ ja: String) -> String {
    switch Language.current {
    case .ko: return ko
    case .en: return en
    case .ja: return ja
    }
}
