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
- **Private tabs** — toggle private in the search panel, which turns solid dark. Private tabs keep
  cookies in memory only and are never saved, archived or snapshotted to disk.
- **Spaces** — group tabs like Zen workspaces. Switch with the chips at the top.
- **Tab cards** — each Space's tabs as a swipeable carousel with page previews,
  pinned tabs first.
- **Swipe up to close, pull down to pin** — like closing apps in the iOS app
  switcher. Long-press a card to move it to another Space.
- **Auto-archive** — unpinned tabs you haven't opened in 12 hours (configurable)
  move to the Archive, where you can restore them.
- **Full-screen pages** — just Tabs, New Tab and a menu button below the page.
  Swipe up on the bar, or tap the arrow, for the page menu: address, back and
  forward, copy link, Find on Page, Reader, Pin, Share, page zoom and the
  desktop version of the site.
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
select your Apple ID under **Signing & Capabilities** first; a free account works
for personal testing.

Run the tests with **⌘U**.

The `.xcodeproj` is generated from `project.yml` and isn't committed. Edit
`project.yml`, then run `xcodegen generate` again.

## Roadmap

1. **Local browser** — Spaces, vertical tabs, auto-archive, reader mode, tracker blocking. ← *now*
2. **Read Zen tabs** — sign in with a Mozilla account and see your desktop tabs.
   Needs an OAuth client ID registered with Mozilla.
3. **Read Zen Spaces** — group synced tabs by Space.
4. **Two-way sync** — close or send tabs from the phone.
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
