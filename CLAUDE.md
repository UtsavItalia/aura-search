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
- `TabStore` knows nothing about WebKit. `BrowserTab` identity is its `id`, assigned once; the URL is just current content; `sync: SyncMetadata` is reserved for phase 2.
- Shared state is injected via `.environment(store)` / `.environment(session)`; sheets re-inject them explicitly.

### UI decisions (Arc parity)
- Tab deck: each card is its page at 70%; next card overlaps from the right, earlier cards stack as dimmed slivers on the left; piecewise-linear stops in `DeckLayout` measured from Arc. Swipe up on a card closes it (fast consecutive flicks supported), pull down pins. Tapping the background opens the most recent tab.
- Page ↔ deck transition: the **live page itself** scales into/out of its card (no copy, no crossfade); other cards fly out of the tabs button. Screens use `.transition(.identity)`. Growing out of a card, the page view shows the card's picture until the zoom ends and the web view is back in the window (see Page transitions).
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
- Deck order is by use, like Arc: `TabStore.tabs(in:)` keeps stored order (pinned first), and `BrowserSession.showHome` calls `TabStore.moveToFront` on the tab being left *before* the deck draws, so it lands as the front (rightmost) card and no card is seen changing places. New tabs append, so they start at the front too.
- Drags follow from where they're recognised, not from the touch: the deck subtracts its 12 pt threshold (`DeckDrag.slop`), a card's vertical swipe its 14 pt (`CardDrag.slop`, kept for the release in `TabCard.swipeStart`, since `@GestureState` may already be reset in `onEnded`). The flying copy gets the same corrected offset, so release doesn't jump. A card closes or pins only on a swipe it locked onto vertically.

### Page transitions
- New tab from search or a new-window link: `BrowserSession.arrival` grows the page in from 94% with rounded corners over the deck's pastel (`Motion.arrive`).
- Link taps crossfade: `navigationStarting` (link/form/other, not back/forward or reload) snapshots the page; at `didCommit` the picture goes up instantly (`pageCovers`, animations disabled); it fades out (`Motion.crossfade`) when the page reports it has drawn — a script in the `.defaultClient` world posts `auraPageReady` after DOMContentLoaded + 2 animation frames (`PageReadyHandler`, weak to the session) — or after 1.2 s, or on finish/failure. Cancelled navigations (NSURLErrorCancelled) are ignored.
- Until a page first draws, a cover hides WebKit's blank white: the leaving page's picture, else the last snapshot, else plain `systemBackground`. It appears instantly and only fades out.
- Opening a card whose web view is still alive: the web view stays **out of the window during the zoom** (`BrowserSession.holdBack` → `heldBackTabID` → `WebViewContainer(isAttached: false)`), with the card's snapshot drawn by the loading cover, and goes in when the zoom ends (`release`). The cover then fades after two animation frames have run in the window (`callAsyncJavaScript` in `.defaultClient`), or a 600 ms timeout counted from the release. While held, `pageDidPaint` is ignored, so a load finishing mid-zoom can't lift the cover over an empty container. Why: re-attaching at the start showed ~100 ms of blank white (WebKit drops an off-screen page's drawing) and froze the zoom 1–2 frames in every open measured (WebKit waits on the main thread for the page to draw when it re-enters a window; SwiftUI animations run on the main thread, so they stall — Arc's UIKit animations don't). Not held back: no snapshot, no address, or an evicted web view being rebuilt (those already wait for first paint).

### Fixed elements and the bottom bar
- WebKit ignores `scrollView.contentInset` when placing `position: fixed` elements, so bottom-fixed banners (cookie consent buttons) hid behind our bar. iOS 26+: `webView.obscuredContentInsets.bottom = barHeight` (public API, what Safari's toolbars use) plus the scroll inset. iOS 17–25: the web view's frame ends at the bar instead (no public API there). Card previews are width-fitted so the shorter pre-26 snapshots aren't cropped.

### Summarize Page (Apple Foundation Models)
- iOS 27 deprecated `LanguageModelSession.GenerationError` in favour of `LanguageModelError` with different case names → errors are classified **by name** (`SummaryText.failure(for:)`), and the page language is checked up front with NaturalLanguage.
- FoundationModels is **weak-linked** in `project.yml` so the app still launches on iOS 17–25. All model code is behind `#if canImport(FoundationModels)` + `@available(iOS 26.0, *)`.

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
- Page covers + `PageReadyHandler` crossfade flow (and `holdBack`/`release` when a card opens: the web view stays out of the window during the zoom); insert covers with animations disabled; never mark a covered tab painted from load progress.
- `TabStore` saves: batched (0.5 s) and encoded/written on a serial background queue; `saveNow()` (synchronous) when the app goes to the background and in tests. Don't go back to saving on the main thread per change — it ran at the start of every open and return.
- Deck order by use (`moveToFront` in `showHome`, before the deck draws).
- `obscuredContentInsets` on iOS 26+ / shortened web view frame before 26.
- `.gitignore` entries for `*.xcodeproj/`, `Readability.js`, `Config/Local.xcconfig`.

## 4. Current status and pending roadmap

### Done: smooth opens (merged to `main` 2026-11-05, confirmed on the phone)
From per-frame timing of the 2026-11-04 recording (every open froze 1–2 frames right after its first frame; Arc never freezes):
1. Opening a card: web view held out of the window during the zoom, attached at the end (see Page transitions).
2. Tab state saves batched and moved off the main thread (they ran at the start of every open and return).
3. Card swipe follows from its 14 pt threshold instead of jumping by it; close/pin only on a swipe the card followed.

### Possible next polish (not fixed)
- Returns (page → deck): 2 of 6 in the recording had one late frame (25 ms) right after the zoom started. Cause unconfirmed; candidates are the deck's first render and `takeSnapshot` for the card picture. Measure again on the new build.
- The drag-start "dropped frame" suspicion was wrong: frame timing shows no late or frozen frame when a drag starts.
- Keep watching the link crossfade timing (cover timeout 1.2 s).

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
- Xcode console noise to ignore: keyboard "UIKBDynamicRenderFactory" spam, TUIPrediction constraint warnings, "Invalid UIScreen coordinate space conversion", WebKit sandbox/RunningBoard lines, "Updated list with error: DownloadFailed" (WebKit, not ours). App logs only on errors, prefixed `AuraSearch:`. Treat any "Cycle detected through attribute" as a real bug.
