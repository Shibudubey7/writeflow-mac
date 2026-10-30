import Foundation

/// A rewrite style. Order of `all` is the order suggestions are shown in; ids match the backend's modes.
public struct Mode: Identifiable, Hashable, Sendable {
    public let id: String
    public let label: String

    public static let all: [Mode] = [
        Mode(id: "grammar", label: "Fix grammar"),
        Mode(id: "casual", label: "Casual"),
        Mode(id: "polite", label: "Polite"),
        Mode(id: "professional", label: "Professional"),
    ]
    public static let defaultIDs = ["grammar", "casual", "professional"]

    /// Keeps known ids in display order; falls back to the defaults when nothing is left.
    public static func normalize(_ ids: [String]) -> [String] {
        let kept = all.map(\.id).filter(ids.contains)
        return kept.isEmpty ? defaultIDs : kept
    }
}

/// An output language. `tag` is BCP-47 and resolved by the backend; empty means "same as input".
public struct Language: Identifiable, Hashable, Sendable {
    public let tag: String
    public let label: String
    public let native: String?
    /// States and union territories where it is official or widely spoken.
    public let places: String?
    /// Already written in Latin letters, so "English letters" does not apply.
    public let latin: Bool

    public var id: String { tag }

    /// "Tamil · தமிழ் — Tamil Nadu, Puducherry", as in the extension's menus.
    public var menuTitle: String {
        let name = native.map { "\(label) · \($0)" } ?? label
        return places.map { "\(name) — \($0)" } ?? name
    }
}

public struct LanguageGroup: Sendable {
    public let name: String
    public let languages: [Language]
}

/// The same list as writeflow-frontend/common.js (LANGUAGE_GROUPS); keep the two in step.
public enum Languages {
    private static func lang(
        _ tag: String, _ label: String, native: String? = nil, places: String? = nil, latin: Bool = false
    ) -> Language {
        Language(tag: tag, label: label, native: native, places: places, latin: latin)
    }

    public static let groups: [LanguageGroup] = [
        LanguageGroup(name: "Common", languages: [
            lang("", "Same as input"),
            lang("en", "English", latin: true),
            lang("hi-Latn", "Hinglish", places: "Hindi in Roman letters", latin: true),
        ]),
        LanguageGroup(name: "North India", languages: [
            lang("hi", "Hindi", native: "हिन्दी", places: "Uttar Pradesh, Bihar, Madhya Pradesh, Rajasthan, Delhi, Haryana, Himachal Pradesh, Uttarakhand, Chhattisgarh, Jharkhand"),
            lang("pa", "Punjabi", native: "ਪੰਜਾਬੀ", places: "Punjab, Chandigarh"),
            lang("ur", "Urdu", native: "اردو", places: "Jammu & Kashmir, Uttar Pradesh, Bihar, Telangana"),
            lang("ks", "Kashmiri", native: "کٲشُر", places: "Jammu & Kashmir"),
            lang("doi", "Dogri", native: "डोगरी", places: "Jammu & Kashmir"),
            lang("bho", "Bhojpuri", native: "भोजपुरी", places: "Bihar, Uttar Pradesh"),
            lang("mai", "Maithili", native: "मैथिली", places: "Bihar"),
            lang("sa", "Sanskrit", native: "संस्कृतम्", places: "Uttarakhand, Himachal Pradesh"),
        ]),
        LanguageGroup(name: "West India", languages: [
            lang("mr", "Marathi", native: "मराठी", places: "Maharashtra"),
            lang("gu", "Gujarati", native: "ગુજરાતી", places: "Gujarat, Dadra & Nagar Haveli and Daman & Diu"),
            lang("kok", "Konkani", native: "कोंकणी", places: "Goa"),
            lang("sd", "Sindhi", native: "سنڌي", places: "Gujarat, Rajasthan, Maharashtra"),
        ]),
        LanguageGroup(name: "South India", languages: [
            lang("ta", "Tamil", native: "தமிழ்", places: "Tamil Nadu, Puducherry"),
            lang("te", "Telugu", native: "తెలుగు", places: "Andhra Pradesh, Telangana"),
            lang("kn", "Kannada", native: "ಕನ್ನಡ", places: "Karnataka"),
            lang("ml", "Malayalam", native: "മലയാളം", places: "Kerala, Lakshadweep"),
            lang("tcy", "Tulu", native: "ತುಳು", places: "Karnataka (coast)"),
        ]),
        LanguageGroup(name: "East India", languages: [
            lang("bn", "Bengali", native: "বাংলা", places: "West Bengal, Tripura"),
            lang("or", "Odia", native: "ଓଡ଼ିଆ", places: "Odisha"),
            lang("sat", "Santali", native: "ᱥᱟᱱᱛᱟᱲᱤ", places: "Jharkhand, West Bengal, Odisha"),
        ]),
        LanguageGroup(name: "Northeast India", languages: [
            lang("as", "Assamese", native: "অসমীয়া", places: "Assam"),
            lang("brx", "Bodo", native: "बड़ो", places: "Assam"),
            lang("mni", "Manipuri", native: "ꯃꯩꯇꯩꯂꯣꯟ", places: "Manipur"),
            lang("ne", "Nepali", native: "नेपाली", places: "Sikkim, West Bengal (Darjeeling)"),
            lang("lus", "Mizo", places: "Mizoram", latin: true),
            lang("kha", "Khasi", places: "Meghalaya", latin: true),
        ]),
        LanguageGroup(name: "World", languages: [
            lang("ja", "Japanese", native: "日本語", places: "Japan"),
            lang("es", "Spanish", native: "Español", places: "Spain, Latin America", latin: true),
        ]),
    ]

    public static let all: [Language] = groups.flatMap(\.languages)

    /// Indian languages written in their own script: the only ones "English letters" applies to.
    private static let romanizable: Set<String> = Set(
        groups.filter { $0.name.hasSuffix("India") }
            .flatMap(\.languages)
            .filter { !$0.latin }
            .map(\.tag)
    )

    public static func canRomanize(_ tag: String) -> Bool {
        romanizable.contains(tag)
    }

    /// The tag sent to the backend: "mr" becomes "mr-Latn" (Marathi in Roman letters) when romanized.
    public static func requestTag(_ tag: String, romanized: Bool) -> String {
        romanized && canRomanize(tag) ? "\(tag)-Latn" : tag
    }

    public static func isKnown(_ tag: String) -> Bool {
        all.contains { $0.tag == tag }
    }
}
