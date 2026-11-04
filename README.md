# Aura Search

A free, open-source iPhone browser in the spirit of Arc Search, built to be
the phone companion for Zen Browser on desktop.

> Status: **phase 1** — a fast local browser with Spaces. Sync with Zen
> comes in later phases (see the roadmap).

## What's in phase 1

- **Picks up where you left off** — the app reopens on your last page with the
  search panel already up, like Arc Search. Turn this off with Auto-Open Keyboard.
- **Light and dark** — follows the system, or pick Light or Dark in Settings.
  Tab cards invert for contrast: dark cards on light, light cards on dark.
- **Search suggestions** — from your chosen search engine as you type, with
  matching open tabs. Off for private tabs, and can be turned off in Settings.
- **Autocomplete and history** — type "goo" and it completes to a site you
  visit, like google.com, with visited pages suggested underneath. History is
  kept on the device only, never includes private tabs or search result pages,
  and can be searched or cleared in Settings → History.
- **Private tabs** — toggle private in the search panel, which turns solid dark. Private tabs keep
  cookies in memory only and are never saved, archived or snapshotted to disk.
- **Spaces** — group tabs like Zen workspaces. Switch with the chips at the top.
- **Tab cards** — each Space's tabs as a deck like the iOS app switcher, laid
  out from Arc Search measured on the same phone: each card is its page at 70%,
  the next card overlaps from the right and earlier ones stack as dimmed
  slivers on the left. The live page shrinks into its card (and grows back out)
  while the other cards fly out of the tabs button.
- **Swipe up to close, pull down to pin** — like closing apps in the iOS app
  switcher. Long-press a card to move it to another Space.
- **Auto-archive** — unpinned tabs you haven't opened in 12 hours (configurable)
  move to the Archive, where you can restore them.
- **Full-screen pages** — just Tabs, New Tab and a menu button below the page.
  Swipe up on the bar, or tap the arrow, for the page menu: address, back and
  forward, copy link, Find on Page, Reader, Pin, Share, page zoom and the
  desktop version of the site.
- **Downloads** — Download buttons, and files a page can't show like zips,
  save to Downloads (in the page menu and Settings) and to the Files app under
  On My iPhone › Aura Search. A card above the bar shows progress, then Open;
  Quick Look's Share button saves images to Photos.
- **Reader mode** — strips a page down to the article, using Mozilla's
  Readability.js, shown with JavaScript off.
- **Tracker blocking** — WebKit's native content blocker with a built-in list,
  with a per-site off switch for pages it breaks.
- **App links** — links to apps you have installed (YouTube, Maps...) open in
  the app, or keep them in the browser.
- **Private by default** — DuckDuckGo search, no analytics, no accounts,
  favicons fetched only from the site you visited.

## Build it

You need a Mac with Xcode (free on the Mac App Store) and
[Homebrew](https://brew.sh).

```sh
brew install xcodegen
cd ~/dev/Zen-search
./scripts/bootstrap.sh        # downloads Readability.js, generates the Xcode project
open AuraSearch.xcodeproj
```

Pick an iPhone simulator and press **Run** (⌘R). To run on your own phone,
put your Apple team ID in `Config/Local.xcconfig` (bootstrap creates it):

```
DEVELOPMENT_TEAM = ABCDE12345
```

Find the ID in Xcode → Settings → Accounts. A free account works for personal
testing. Both the app and the tests use it, and it isn't committed.

Run the tests with **⌘U**.

The `.xcodeproj` is generated from `project.yml` and isn't committed. Edit
`project.yml`, then run `xcodegen generate` again.

## Roadmap

1. **Local browser** — Spaces, the tab deck, auto-archive, reader mode,
   tracker blocking, downloads. ← *now*
2. **Read Zen tabs** — sign in with a Mozilla account and see your desktop tabs.
   - Built on Mozilla's own Rust components from
     [application-services](https://github.com/mozilla/application-services)
     (`fxa-client`, `sync_manager`, `tabs`): their prebuilt XCFramework and
     Swift bindings, vendored as a local Swift package the way Firefox for iOS
     does it now (`rust-components-swift` is archived). No home-made sync or
     encryption: the components decrypt records themselves.
   - Sign-in in `ASWebAuthenticationSession`; the account state, which holds
     the Sync keys, lives in the Keychain.
   - Rust calls block and hit the network, so they run in a sync service off
     the main thread, which feeds `TabStore`. Views never see the SDK.
   - Needs an OAuth client ID with the Sync scope from Mozilla.
3. **Read Zen Spaces** — Zen 1.22+ syncs Spaces, folders, pinned tabs and
   Essentials through the same account, in its own `spaces` collection.
   Mozilla's components don't read that collection, so this needs a small
   reader for it, using the account's Sync keys.
4. **Two-way sync** — send and close tabs from the phone, with Mozilla
   account device commands.
5. **Browse for Me** — on-device page summaries with Apple's Foundation Models,
   on devices that support Apple Intelligence.

## How the code is organized

```
AuraSearch/
  App/        App entry point
  Models/     Tabs, Spaces, settings, saving to disk (TabStore) — no web views
  Browser/    Live web views (BrowserSession), page snapshots, reader mode, tracker blocking
  Views/      SwiftUI screens
  Resources/  Asset catalog, tracker list, Readability.js
AuraSearchTests/
design/       App icon source: edit app-icon.html, run node design/render-icon.js
Config/       Signing (your team ID goes in Local.xcconfig)
```

`TabStore` holds the data and knows nothing about web views, so it can be
tested, saved and later synced on its own. `BrowserSession` owns the running
`WKWebView`s: it keeps up to six alive and saves the back/forward history of
any it drops to save memory.

A tab's identity is its `id`, assigned once. Its URL is just what it's showing
right now. A synced tab is the same `BrowserTab` type with `sync` metadata
filled in.

## Contributing

Issues and pull requests are welcome. Please keep the app private by default:
no analytics, and no third-party requests the user didn't trigger.

## License

MIT — see [LICENSE](LICENSE). Third-party code is listed in
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
