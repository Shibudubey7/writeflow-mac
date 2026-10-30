# WriteFlow for Mac

A menu bar app that rewrites the text you select in any app: grammar fixes and casual, polite or
professional versions, in 30 languages (Indian languages also in English letters). Same server and
features as the WriteFlow Chrome extension.

Click a suggestion (or **Replace**) to put it in place of the text you selected, or **Copy** to
paste it yourself. WriteFlow changes nothing until you click.

## Use it

- **Select text and press ⌃⌥W** (Control-Option-W) in any app. A card with suggestions opens at the
  pointer. Change it in Settings → Shortcut (click it, press new keys). It needs ⌘ or ⌃: macOS 15
  and later ignore global shortcuts that use only Option and Shift.
- **Or click the W button** that appears when you select text with the mouse or the keyboard
  (⇧ or ⌘⇧ with arrows, ⌘A), while WriteFlow is on.
- **W in the menu bar** shows whether it is on: filled W = on, outlined W = off. Click it for
  Turn On/Off, Rewrite Clipboard Text, Settings and Quit. When off, the W button never appears;
  the shortcut still works.
- The card closes when you click outside it, press Esc, or pick a suggestion.
- Replace works by pasting (⌘V) over your selection, so it works wherever you could paste. Where
  you can't (text on a web page, for example) the suggestion is still on the clipboard.

## Install

**[Download the latest WriteFlow for Mac](https://github.com/shibudubey7/writeflow-mac/releases/latest)**
(macOS 13 or later, Apple silicon and Intel)

1. On that page, under **Assets**, download `WriteFlow-<version>.zip` and unzip it.
2. Drag **WriteFlow.app** into **Applications**.
3. Open it. macOS says it can't check the app for malicious software, because it is not
   notarized by Apple. Click **Done**, then open **System Settings → Privacy & Security**,
   scroll down and click **Open Anyway** next to WriteFlow. You only do this once.
4. Allow **Accessibility** when asked (System Settings → Privacy & Security → Accessibility →
   turn on WriteFlow). It's needed to read the text you select.
5. Optional: Settings → **Open WriteFlow at login**.

## Privacy

Only the text you ask about is sent to the WriteFlow server, to make suggestions. It is not
stored. A random install ID is sent with each request so the server can share its free daily
limits fairly; it is not linked to you. Details: https://writeflow-api-gcd5.onrender.com/privacy

## Build

Needs Xcode 15 or later (macOS 13+ to run).

```sh
swift test                  # unit tests
swift run WriteFlow         # run from the terminal while developing
sh scripts/build-app.sh     # dist/WriteFlow.app and dist/WriteFlow-<version>.zip
```

`WRITEFLOW_LIVE_URL=https://writeflow-api-gcd5.onrender.com swift test` also runs one real request
against the server. `swift run WriteFlow --snapshot /some/folder` renders the card, Settings and
menu bar icons to PNGs without starting the app.

Each build is signed ad hoc, so macOS treats a rebuilt app as a new app: after rebuilding, remove
WriteFlow from the Accessibility list (−) and allow it again.

## Release

Releases are built by GitHub Actions (`.github/workflows/release.yml`) when a version tag is pushed:

1. Bump `CFBundleShortVersionString` (and `CFBundleVersion`) in `Resources/Info.plist`, commit, push.
2. Tag the commit with the same version and push the tag. In VS Code: Command Palette →
   **Git: Create Tag** → `v1.0.1`, then **Git: Push Tags**. Or `git tag v1.0.1 && git push origin v1.0.1`.
3. In a few minutes the release appears under Releases with `WriteFlow-1.0.1.zip` attached
   (progress under the Actions tab).

To skip the "Open Anyway" step for users, the app has to be signed with a Developer ID and
notarized, which needs an Apple Developer account (US$99/year).

## Code

| Path | What |
| --- | --- |
| `Sources/WriteFlowCore/Languages.swift` | Styles and the 30 languages (same list as the extension's `common.js`) |
| `Sources/WriteFlowCore/Settings.swift` | Saved settings, install ID, access key in the Keychain |
| `Sources/WriteFlowCore/APIClient.swift` | Requests to the server, errors, cache |
| `Sources/WriteFlow/AppDelegate.swift` | Menu bar icon and menu, shortcut, on/off |
| `Sources/WriteFlow/SelectionReader.swift` | Reads the selection (Accessibility, then ⌘C with the clipboard restored) |
| `Sources/WriteFlow/SelectionWatcher.swift` | Notices mouse selections for the W button |
| `Sources/WriteFlow/Card.swift` | The suggestion card |
| `Sources/WriteFlow/SettingsWindow.swift` | Settings |
| `Sources/WriteFlow/Panels.swift` | Floating panels that don't take focus from the app you're in |
