import Combine
import Foundation
import Security

public enum ServerURL {
    /// The hosted WriteFlow server, used unless the user picks another one in Settings.
    public static let `default` = "https://writeflow-api-gcd5.onrender.com"

    /// Returns the URL without query or trailing slash, or nil when it is not an http(s) URL.
    public static func normalize(_ value: String) -> String? {
        guard var components = URLComponents(string: value.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = components.host, !host.isEmpty
        else { return nil }
        components.scheme = scheme
        components.query = nil
        components.fragment = nil
        components.user = nil
        components.password = nil
        guard var url = components.string else { return nil }
        while url.hasSuffix("/") { url.removeLast() }
        return url
    }
}

/// The global shortcut that opens the card. `modifiers` uses Carbon's bits, as RegisterEventHotKey does.
public struct Shortcut: Equatable, Sendable {
    public static let command = 0x0100
    public static let shift = 0x0200
    public static let option = 0x0800
    public static let control = 0x1000

    /// Control-Option-W. (⌥⇧W, the extension's shortcut, can't be used: see `isAllowed`.)
    public static let `default` = Shortcut(keyCode: 13, modifiers: control | option, key: "W")

    /// A kVK_ virtual key code.
    public let keyCode: Int
    public let modifiers: Int
    /// What the key shows, e.g. "W" or "Space".
    public let key: String

    public init(keyCode: Int, modifiers: Int, key: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.key = key
    }

    /// "⌃⌥W", in the order macOS menus use.
    public var display: String {
        [(Self.control, "⌃"), (Self.option, "⌥"), (Self.shift, "⇧"), (Self.command, "⌘")]
            .filter { modifiers & $0.0 != 0 }
            .map(\.1)
            .joined() + key
    }

    /// macOS 15 and later ignore global shortcuts whose only modifiers are Option and Shift,
    /// so a shortcut needs ⌘ or ⌃.
    public var isAllowed: Bool { modifiers & (Self.command | Self.control) != 0 }
}

/// Everything the user can change, saved in UserDefaults; the access key is kept in the Keychain.
@MainActor
public final class SettingsStore: ObservableObject {
    private enum Key {
        static let serverURL = "serverURL"
        static let modes = "modes"
        static let targetLanguage = "targetLanguage"
        static let romanized = "romanized"
        static let askFirst = "askFirst"
        static let enabled = "enabled"
        static let hasAccessKey = "hasAccessKey"
        static let installID = "installID"
        static let onboarded = "onboarded"
        static let shortcut = "shortcut"
        static let showScore = "showScore"
    }

    private let defaults: UserDefaults
    private let keychain: Keychain

    @Published public var serverURL: String { didSet { defaults.set(serverURL, forKey: Key.serverURL) } }
    /// Mode ids in display order, never empty.
    @Published public var modes: [String] { didSet { defaults.set(modes, forKey: Key.modes) } }
    /// Empty: keep the input's language and script.
    @Published public var targetLanguage: String { didSet { defaults.set(targetLanguage, forKey: Key.targetLanguage) } }
    /// Write the chosen Indian language in English (Roman) letters. Remembered even while a language
    /// it does not apply to is picked, so it comes back with the next Indian language.
    @Published public var romanized: Bool { didSet { defaults.set(romanized, forKey: Key.romanized) } }
    /// Show the style chips and wait for "Rewrite" instead of answering straight away.
    @Published public var askFirst: Bool { didSet { defaults.set(askFirst, forKey: Key.askFirst) } }
    /// The on/off switch: when off, no W button appears on selection. The shortcut still works.
    @Published public var enabled: Bool { didSet { defaults.set(enabled, forKey: Key.enabled) } }
    /// Show a 0-100 writing score on the W button; the selected text is sent to score it.
    @Published public var showScore: Bool { didSet { defaults.set(showScore, forKey: Key.showScore) } }
    @Published public var shortcut: Shortcut {
        didSet {
            defaults.set(["keyCode": shortcut.keyCode, "modifiers": shortcut.modifiers, "key": shortcut.key], forKey: Key.shortcut)
        }
    }
    /// Only for a private server; the hosted one needs none.
    @Published public var accessKey: String {
        didSet {
            let trimmed = accessKey.trimmingCharacters(in: .whitespacesAndNewlines)
            keychain.write(trimmed)
            defaults.set(!trimmed.isEmpty, forKey: Key.hasAccessKey)
        }
    }

    public init(
        defaults: UserDefaults = .standard,
        keychain: Keychain = Keychain(service: "WriteFlow", account: "accessKey")
    ) {
        self.defaults = defaults
        self.keychain = keychain
        serverURL = defaults.string(forKey: Key.serverURL).flatMap(ServerURL.normalize) ?? ServerURL.default
        modes = Mode.normalize(defaults.stringArray(forKey: Key.modes) ?? Mode.defaultIDs)
        let language = defaults.string(forKey: Key.targetLanguage) ?? ""
        targetLanguage = Languages.isKnown(language) ? language : ""
        romanized = defaults.bool(forKey: Key.romanized)
        askFirst = defaults.bool(forKey: Key.askFirst)
        enabled = defaults.object(forKey: Key.enabled) as? Bool ?? true
        showScore = defaults.object(forKey: Key.showScore) as? Bool ?? true
        shortcut = Self.storedShortcut(defaults.dictionary(forKey: Key.shortcut)) ?? .default
        // Reading the Keychain can ask the user for permission after an update, so only when a key was saved.
        accessKey = defaults.bool(forKey: Key.hasAccessKey) ? keychain.read() : ""
    }

    private static func storedShortcut(_ stored: [String: Any]?) -> Shortcut? {
        guard let keyCode = stored?["keyCode"] as? Int, let modifiers = stored?["modifiers"] as? Int,
              let key = stored?["key"] as? String, !key.isEmpty
        else { return nil }
        let shortcut = Shortcut(keyCode: keyCode, modifiers: modifiers, key: key)
        return shortcut.isAllowed ? shortcut : nil
    }

    /// The tag to send for the current language and "English letters" choice.
    public var requestLanguage: String {
        Languages.requestTag(targetLanguage, romanized: romanized)
    }

    /// A random id for this install, made once. The server uses it only to share its usage limits
    /// fairly between users; it is not linked to the person.
    public var installID: String {
        if let id = defaults.string(forKey: Key.installID), !id.isEmpty { return id }
        let id = UUID().uuidString.lowercased()
        defaults.set(id, forKey: Key.installID)
        return id
    }

    /// True once, on the first launch.
    public func takeFirstLaunch() -> Bool {
        guard !defaults.bool(forKey: Key.onboarded) else { return false }
        defaults.set(true, forKey: Key.onboarded)
        return true
    }
}

/// One generic password in the login Keychain.
public struct Keychain: Sendable {
    let service: String
    let account: String

    public init(service: String, account: String) {
        self.service = service
        self.account = account
    }

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    public func read() -> String {
        var lookup = query
        lookup[kSecReturnData as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(lookup as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    public func write(_ value: String) {
        SecItemDelete(query as CFDictionary)
        guard !value.isEmpty else { return }
        var item = query
        item[kSecValueData as String] = Data(value.utf8)
        SecItemAdd(item as CFDictionary, nil)
    }
}
