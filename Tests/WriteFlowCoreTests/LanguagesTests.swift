import XCTest
@testable import WriteFlowCore

final class LanguagesTests: XCTestCase {
    func testThirtyLanguagesPlusSameAsInput() {
        XCTAssertEqual(Languages.all.count, 31)
        XCTAssertEqual(Set(Languages.all.map(\.tag)).count, Languages.all.count, "tags are unique")
    }

    func testOnlyIndianScriptsCanBeRomanized() {
        for tag in ["hi", "mr", "ta", "te", "bn", "kn", "ml", "ur", "as"] {
            XCTAssertTrue(Languages.canRomanize(tag), tag)
        }
        for tag in ["", "en", "hi-Latn", "ja", "es", "lus", "kha"] {
            XCTAssertFalse(Languages.canRomanize(tag), tag)
        }
    }

    func testRequestTag() {
        XCTAssertEqual(Languages.requestTag("mr", romanized: true), "mr-Latn")
        XCTAssertEqual(Languages.requestTag("mr", romanized: false), "mr")
        XCTAssertEqual(Languages.requestTag("ja", romanized: true), "ja")
        XCTAssertEqual(Languages.requestTag("", romanized: true), "")
    }

    func testMenuTitle() {
        let tamil = Languages.all.first { $0.tag == "ta" }
        XCTAssertEqual(tamil?.menuTitle, "Tamil · தமிழ் — Tamil Nadu, Puducherry")
        XCTAssertEqual(Languages.all.first { $0.tag == "en" }?.menuTitle, "English")
    }

    func testModesKeepDisplayOrderAndFallBack() {
        XCTAssertEqual(Mode.normalize(["professional", "grammar", "shout"]), ["grammar", "professional"])
        XCTAssertEqual(Mode.normalize([]), Mode.defaultIDs)
    }

    func testServerURLNormalize() {
        XCTAssertEqual(ServerURL.normalize(" https://a.onrender.com/ "), "https://a.onrender.com")
        XCTAssertEqual(ServerURL.normalize("HTTP://127.0.0.1:8787/?x=1"), "http://127.0.0.1:8787")
        XCTAssertNil(ServerURL.normalize("a.onrender.com"))
        XCTAssertNil(ServerURL.normalize("ftp://a.com"))
        XCTAssertNil(ServerURL.normalize(""))
    }
}

@MainActor
final class SettingsStoreTests: XCTestCase {
    private func makeDefaults() -> UserDefaults {
        let name = "WriteFlowTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    func testDefaultsAndPersistence() {
        let defaults = makeDefaults()
        let keychain = Keychain(service: "WriteFlowTests-\(UUID().uuidString)", account: "accessKey")
        let store = SettingsStore(defaults: defaults, keychain: keychain)
        XCTAssertEqual(store.serverURL, ServerURL.default)
        XCTAssertEqual(store.modes, Mode.defaultIDs)
        XCTAssertTrue(store.enabled)
        XCTAssertEqual(store.accessKey, "")

        store.targetLanguage = "mr"
        store.romanized = true
        store.enabled = false
        XCTAssertEqual(store.requestLanguage, "mr-Latn")

        let reloaded = SettingsStore(defaults: defaults, keychain: keychain)
        XCTAssertEqual(reloaded.targetLanguage, "mr")
        XCTAssertTrue(reloaded.romanized)
        XCTAssertFalse(reloaded.enabled)
    }

    func testRomanizedIsIgnoredForNonIndianLanguages() {
        let store = SettingsStore(defaults: makeDefaults(), keychain: Keychain(service: "WriteFlowTests-\(UUID().uuidString)", account: "a"))
        store.romanized = true
        store.targetLanguage = "ja"
        XCTAssertEqual(store.requestLanguage, "ja")
        store.targetLanguage = "ta"
        XCTAssertEqual(store.requestLanguage, "ta-Latn", "the choice comes back with the next Indian language")
    }

    func testInstallIDIsStable() {
        let defaults = makeDefaults()
        let store = SettingsStore(defaults: defaults, keychain: Keychain(service: "WriteFlowTests-\(UUID().uuidString)", account: "a"))
        let id = store.installID
        XCTAssertNotNil(id.range(of: "^[a-z0-9-]{36}$", options: .regularExpression))
        XCTAssertEqual(store.installID, id)
        XCTAssertEqual(SettingsStore(defaults: defaults).installID, id)
    }

    func testShortcutDefaultsAndPersists() {
        let defaults = makeDefaults()
        let store = SettingsStore(defaults: defaults, keychain: Keychain(service: "WriteFlowTests-\(UUID().uuidString)", account: "a"))
        XCTAssertEqual(store.shortcut.display, "⌃⌥W")
        store.shortcut = Shortcut(keyCode: 49, modifiers: Shortcut.command | Shortcut.shift, key: "Space")
        let reloaded = SettingsStore(defaults: defaults, keychain: Keychain(service: "WriteFlowTests-\(UUID().uuidString)", account: "a"))
        XCTAssertEqual(reloaded.shortcut.display, "⇧⌘Space")
    }

    func testOptionShiftOnlyShortcutsAreRejected() {
        XCTAssertFalse(Shortcut(keyCode: 13, modifiers: Shortcut.option | Shortcut.shift, key: "W").isAllowed)
        XCTAssertTrue(Shortcut.default.isAllowed)
        let defaults = makeDefaults()
        defaults.set(["keyCode": 13, "modifiers": Shortcut.option | Shortcut.shift, "key": "W"], forKey: "shortcut")
        let store = SettingsStore(defaults: defaults, keychain: Keychain(service: "WriteFlowTests-\(UUID().uuidString)", account: "a"))
        XCTAssertEqual(store.shortcut, .default)
    }

    func testUnknownStoredValuesFallBack() {
        let defaults = makeDefaults()
        defaults.set("not a url", forKey: "serverURL")
        defaults.set("xx", forKey: "targetLanguage")
        defaults.set(["shout"], forKey: "modes")
        let store = SettingsStore(defaults: defaults, keychain: Keychain(service: "WriteFlowTests-\(UUID().uuidString)", account: "a"))
        XCTAssertEqual(store.serverURL, ServerURL.default)
        XCTAssertEqual(store.targetLanguage, "")
        XCTAssertEqual(store.modes, Mode.defaultIDs)
    }
}
