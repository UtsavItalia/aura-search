# Aura Search — project guide for Claude

## 1. Project vision

Aura Search is a free, open-source (MIT) iPhone browser that recreates Arc Search's fast, gesture-driven UI and is built as the phone companion to Zen Browser on desktop. The goal is reach and connections rather than income: get a polished Arc-quality browser onto as many phones as possible, then sync tabs and Spaces with Zen through Mozilla accounts.

## 2. Decisions made and rationale

### How we work
- The owner (Utsav, GitHub `UtsavItalia`) asked Claude to "take care of things building this browser": Claude writes the code, including decision-bearing code. Explain trade-offs briefly; ask before expensive or irreversible choices (e.g. reordering phases, bundle ID).
- Move through phases in order, but pulling work forward is fine when a phase is blocked (Summarize was pulled forward from phase 5 while Mozilla reviews the OAuth request).
- UI must match Arc Search closely, down to small details. The owner compares screen recordings of Arc and Aura from the same phone (iPhone 18 Pro Max, 440×956 pt, iOS 27). Layout constants were measured frame by frame from those recordings.
- Explain *why* when fixing bugs. Bullets for technical content. Suggest Obsidian links for concepts.
- Commit/push only when asked. Untested features go on a branch first (e.g. `summarize-page`), then merge to `main` once confirmed on the phone.

### Stack
- **SwiftUI, iOS 17+**, Swift 5 language mode, `@Observable` (Observation framework) models — **not** `ObservableObject`/`@Published` (finer-grained redraws; matters with progress ticking).
- **WKWebView only** (all iOS browsers must use WebKit). Wrapped in `BrowserSession`; views never touch WebKit except `WebViewContainer` and `ReaderView`.
- **XcodeGen**: `project.yml` is the source of truth; `*.xcodeproj` is generated and git-ignored. Adding/removing files or changing `project.yml` requires `xcodegen generate` (or `./scripts/bootstrap.sh`).
- **Signing**: team ID lives in `Config/Local.xcconfig` (git-ignored; owner's is `6VT9A7UXL4`), included by `Config/Signing.xcconfig`, applied at project level so both the app and test targets get it and it survives regeneration.
- Bundle ID currently `io.github.aurasearch.app`; suggested final `io.github.utsavitalia.aurasearch` — not yet changed (changing it makes the phone treat it as a new app; decide before App Store Connect).
- Reader mode uses Mozilla Readability.js (fetched by bootstrap, git-ignored), run in an isolated JS world.
- Tracker blocking uses WebKit content rule lists (WKWebView can't intercept or rewrite subresource requests — don't plan features that need that).
- No analytics, no accounts of our own, no server. Private by default (DuckDuckGo default engine).

### Architecture
- `Models/` — `TabStore` (tabs, Spaces, archive, settings; persisted to Application Support; knows nothing about WebKit), `HistoryStore` (frecency autocomplete), `BrowserTab` (identity = `id` assigned once; URL is just current content; optional `sync: SyncMetadata` reserved for phase 2), `URLResolver`, `BrowserSettings`.
- `Browser/` — `BrowserSession` (live web views, max 6 alive, LRU eviction saving `interactionState`; KVO + delegates torn down on discard; private tabs share one non-persistent data store dropped when the last private tab closes), `WebViewDelegate`, `SnapshotStore` (card previews, Caches dir), `DownloadManager`, `PageSummarizer`, `PinchToSummarize`, `ReaderMode`, `ContentBlocker`, `SearchSuggestions`.
- `Views/` — `RootView` (measures the screen; hosts screens, search panel, download card, sheets), `HomeView` (tab deck), `BrowserView`, `DeckLayout` (ScreenMetrics, BarMetrics, deck math), `SearchPanel`, `TabCard`, `PageMenuView`, `SettingsView`, `DownloadsView`, `SummaryView`, etc.
- Shared state is injected via `.environment(store)` / `.environment(session)`; sheets re-inject them explicitly.

### UI decisions (Arc parity)
- Tab deck: each card is its page at 70%; next card overlaps from the right, earlier cards stack as dimmed slivers on the left; piecewise-linear stops in `DeckLayout` measured from Arc. Swipe up on a card closes it (fast consecutive flicks supported), pull down pins. Tapping the background opens the most recent tab.
- Page ↔ deck transition: the **live page itself** scales into/out of its card (no copy, no crossfade); other cards fly out of the tabs button. Screens use `.transition(.identity)`.
- Bottom bar: tabs stack button / 76×40 "+" capsule / chevron-up menu; bar centred at `H − max(safeBottom + 10.5, 30)`; pastel background matches the deck. Private tabs: dark bar, frosted card previews (blur only for private tabs).
- Search panel: custom panel (not a sheet) pinned to the top of the keyboard, ~31.6% of screen height, opens at launch with keyboard up (Auto-Open Keyboard setting) and from "+". History autocomplete ghost text, suggestions, private toggle.
- Appearance defaults to System; tab cards invert for contrast.
- App icon: "Halo" (light), "Eclipse" (dark), tinted variant; original design taking mood (not shapes) from Arc/Zen/Claude to avoid trademark/App Store issues. Source in `design/app-icon.html`, render with `node design/render-icon.js`.

### Sync plan (phases 2–4)
- Use Mozilla's **application-services** Rust components (`fxa-client`, `sync_manager`, `tabs`), vendored as a **local Swift package** (prebuilt XCFramework + generated UniFFI bindings) the way Firefox iOS does now. `rust-components-swift` is **archived** (Dec 2025) — don't use it.
- Components decrypt records internally; our security job is storing account state (refresh token + Sync keys) in the **Keychain**. No home-made sync/crypto for tabs.
- Rust calls block and do network I/O → run in a sync service/actor off the main thread that feeds `TabStore`. Views never import the SDK.
- Sign-in via `ASWebAuthenticationSession`, PKCE public client.
- The SDK's Swift wrapper depends on Glean (telemetry) — keep it off to honour "no analytics".
- Zen 1.22+ syncs Spaces/folders/pinned/Essentials in its own `spaces` collection (engine "Spaces", records `{id, kind, data}`, kinds: space, folder, tab, container, split, layout). Mozilla's components don't read it → phase 3 needs a small reader using the account's Sync keys (or a custom Rust engine). Zen syncs only pinned + Essentials by default.

### Motion (app-wide)
- Every animation comes from `Views/Motion.swift` — never write `.spring(...)`/`.easeOut(...)` in a view. iOS-like: no-wobble springs at system speeds; fades only where one thing replaces another; gestures hand over the finger's velocity (`Motion.settle(velocity:)`, `Motion.fling(velocity:)`, `Motion.relativeVelocity(_:toCover:)`).
- Key values: `zoom` (page↔card, timed from Arc), `standard`, `arrive` (new page), `present`/`dismiss` (search panel), `reflow` (cards closing a gap), `quick`, `crossfade`, `fade`, `progress`, `pulse` (placeholder).
- Motion the app drives frame by frame (the deck) uses `Motion.FrameSpring` (`.glide`, `.reflow`): exact critically damped springs on a `CADisplayLink` (`FrameTicker`), same curves as the SwiftUI springs.
- **120 fps**: `CADisableMinimumFrameDurationOnPhone = YES` in Info.plist (via `project.yml`). Without it iOS caps the app at 60 fps — measured from a screen recording.
- The owner prefers a short, smooth transition over an instant cut everywhere ("a few ms of animation beats a blink").

### Tab deck motion
- After a flick the deck glides on `DeckGlide` (CADisplayLink, analytic critically damped spring, starts at the flick's velocity), so the stored `position` always equals what's on screen: catching the deck mid-glide stops it in place. Don't move this back to `withAnimation` — SwiftUI jumps the stored value to the end and a mid-glide touch made the deck leap.
- Swipe-to-close (like the app switcher): the card stays opaque and flies off the top at the finger's velocity (`FlyingCard.lift` + `Motion.fling`). The flying copy reproduces the card's drag transforms exactly (`TabCard.lift`) and keeps its z-order (just under the next card), so nothing jumps or pops on release.
- The cards after a closed one slide over on `DeckReflow` (frame by frame, per-tab offset + velocity, `FrameSpring.reflow`), starting exactly where they are — so a card swiped away mid-slide flies from where it looks. Removals from inside the deck (swipe, context-menu close/move) go through `TabCarousel.remove(_:by:)` and never use `withAnimation`; SwiftUI animations there would store end values and fight the frame-driven motion.
- A sideways drag catches a gliding deck; a card being swiped vertically lets the glide finish. A re-settle after a close carries the glide's current velocity.
- `TabCarousel` stays alive with no tabs, so the last card's copy finishes flying; the empty state fades in underneath it.
- Card shadows are cast by a plain shape behind each card; the dim overlay sits on top. Keeps shadows from re-rendering every frame.
- Card titles are masked (not narrowed) at the next card's left edge (`headerVisibleWidth`), so titles never overlap and text isn't re-laid-out per frame.

### Page transitions
- New tab from search or a new-window link: `BrowserSession.arrival` grows the page in from 94% with rounded corners over the deck's pastel (`Motion.arrive`).
- Link taps crossfade: `navigationStarting` (link/form/other, not back/forward or reload) snapshots the page; at `didCommit` the picture goes up instantly (`pageCovers`, animations disabled); it fades out (`Motion.crossfade`) when the page reports it has drawn — a script in the `.defaultClient` world posts `auraPageReady` after DOMContentLoaded + 2 animation frames (`PageReadyHandler`, weak to the session) — or after 1.2 s, or on finish/failure. Cancelled navigations (NSURLErrorCancelled) are ignored.
- Until a page first draws, a cover hides WebKit's blank white: the leaving page's picture, else the last snapshot, else plain `systemBackground`. It appears instantly and only fades out.

### Fixed elements and the bottom bar
- WebKit ignores `scrollView.contentInset` when placing `position: fixed` elements, so bottom-fixed banners (cookie consent buttons) hid behind our bar. iOS 26+: `webView.obscuredContentInsets.bottom = barHeight` (public API, what Safari's toolbars use) plus the scroll inset. iOS 17–25: the web view's frame ends at the bar instead (no public API there). Card previews are width-fitted so the shorter pre-26 snapshots aren't cropped.

### Summarize Page (Apple Foundation Models)
- `SystemLanguageModel(useCase: .general, guardrails: .permissiveContentTransformations)`; fresh `LanguageModelSession` per request; text from Readability (fallback `innerText`); chunked by `contextSize` with a chars-per-token estimate (3 Latin, 2 other scripts, 1 CJK); map (notes per part, max 8 parts) → reduce (streamed summary: one sentence + 3–5 "- " bullets).
- iOS 27 deprecated `LanguageModelSession.GenerationError` in favour of `LanguageModelError` with different case names → errors are classified **by name** (`SummaryText.failure(for:)`), and the page language is checked up front with NaturalLanguage.
- FoundationModels is **weak-linked** in `project.yml` so the app still launches on iOS 17–25. All model code is behind `#if canImport(FoundationModels)` + `@available(iOS 26.0, *)`.
- Triggers: page menu "Summarize" tile, and pinching the page in past its minimum zoom (`PinchToSummarize`, haptic only when a summary opens).

## 3. What NOT to change (working; don't refactor)
- **Screen measurement in `RootView`**: plain frames from two GeometryReaders (one ignoring all safe areas, one ignoring only the keyboard), on a `Color.clear` surface the screens sit on in an overlay. Never read safe-area insets or `UIScreen`/window sizes during layout — that caused an AttributeGraph cycle ("Cycle detected through attribute") that silently broke the + button and the launch search panel.
- **Search panel dismissal** (`BrowserSession.dismissSearch`): resign first responder immediately, animate `isSearchClosing` (panel sinks behind the keyboard), remove the panel without animation in the completion; generation counter handles reopen-while-closing. SwiftUI otherwise keeps the keyboard until the text field is removed.
- `DeckLayout` constants/stops and `BarMetrics` — measured from Arc; change only with new measurements.
- The live-page-into-card transition (`TabTransition`, `showHome`, `open(_:fromCard:deckPosition:)`).
- Web view memory policy (max 6 live, LRU + `interactionState`, teardown order) and private data store handling.
- Downloads: `.download` policy for `Content-Disposition: attachment`, `<a download>` (`shouldPerformDownload`) and non-showable main-frame MIME types; files in `Documents/Downloads` (visible in Files via `UIFileSharingEnabled` + `LSSupportsOpeningDocumentsInPlace`); blank tabs opened only for a download close themselves and return to the opener.
- Info.plist privacy strings (photo add, camera, mic, location) — removing them crashes WebKit features.
- Signing setup (`Config/Signing.xcconfig` + git-ignored `Local.xcconfig`).
- Weak link of FoundationModels; name-based model error classification.
- `Motion.swift` as the single source of animation values; `CADisableMinimumFrameDurationOnPhone`.
- `DeckGlide` + `DeckReflow` + `FrameTicker` (frame-driven deck motion), the opaque velocity fling and its z-order, shadow-behind/dim-on-top card layering, and the title mask.
- Page covers + `PageReadyHandler` crossfade flow; insert covers with animations disabled; never mark a covered tab painted from load progress.
- `obscuredContentInsets` on iOS 26+ / shortened web view frame before 26.
- `.gitignore` entries for `*.xcodeproj/`, `Readability.js`, `Config/Local.xcconfig`.

## 4. Current status and pending roadmap

### Done on `main` (pushed)
Phase 1 local browser: Spaces, Arc-style deck and page zoom, swipe-to-close/pull-to-pin, auto-archive + Archive, history with autocomplete, search suggestions, private tabs, reader mode, tracker blocking with per-site exceptions, app links, page menu (address, back/forward, copy link, find, reader, summarize, pin, share, zoom, desktop site, move to Space), downloads (card + list + Quick Look), app icon set, signing fix.
Summarize Page (confirmed on device) and the doubled-bullet fix (`770b98c`).

### On branch `motion-polish` (pushed; the Mac is on this branch) — needs testing on the phone
Built from the owner's screen recording (42 s at 120 fps; the deck only ever drew 60 fps):
1. 120 fps opt-in; cheaper card rendering (shadow/dim layering); title mask so cards' titles don't overlap.
2. Deck glide that starts at the flick's speed and can be caught mid-glide.
3. Swipe-to-close like the app switcher (opaque, velocity fling, smooth reflow).
4. App-wide `Motion` rules; every animation now uses them.
5. New pages grow in; link taps crossfade instead of blinking; no blank-white flash before first paint.
6. Cookie banners/fixed bottom elements no longer hide behind the bottom bar (iOS 26+ `obscuredContentInsets`).
**Next**: owner builds (`xcodegen generate` — new file `Views/Motion.swift` + Info.plist key), tests on the phone, then merge `motion-polish` into `main`. Things to watch: deck smoothness at 120 Hz, the link crossfade timing (cover timeout 1.2 s), and that fixed bottom elements sit above the bar.

### External / waiting
- Mozilla OAuth client request filed: https://github.com/mozilla/fxa/issues/21691 (synced to Mozilla Jira FXA-14918). No reply yet. Mozilla's contributing guide says accounts are for Mozilla or tightly coupled parties — a "no" is possible. Never borrow another app's client ID.
- Apple Developer Program ($99/yr): owner to enroll; then TestFlight public link and request the default-browser entitlement; settle bundle ID first.
- Optional: Instruments (Leaks/Allocations) memory check on device.

### Later phases
2. Read Zen tabs (Mozilla account sign-in, tabs via application-services) — gated on Mozilla client ID.
3. Read Zen Spaces (`spaces` collection reader).
4. Two-way sync (Send Tab / close tabs via device commands).
5. Browse for Me (multi-page answers on device); single-page Summarize already shipped.

## Practical notes
- Repo: https://github.com/UtsavItalia/aura-search (public). Local path: `~/dev/Zen-search`.
- Build: `xcodegen generate`, then ⌘R on the iPhone; tests ⌘U.
- Xcode console noise to ignore: keyboard "UIKBDynamicRenderFactory" spam, TUIPrediction constraint warnings, "Invalid UIScreen coordinate space conversion", WebKit sandbox/RunningBoard lines, "Updated list with error: DownloadFailed" (WebKit, not ours). App logs only on errors, prefixed `AuraSearch:`. Treat any "Cycle detected through attribute" as a real bug.
