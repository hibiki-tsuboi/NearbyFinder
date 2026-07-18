# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

NearbyFinder is an iPhone treasure-hunt app built on Nearby Interaction (UWB): one iPhone is hidden, the other finds it using live distance/direction readings. The Xcode project is multiplatform (iOS, macOS, visionOS), but Nearby Interaction only works on iOS — other platforms compile against a stub and show an "unsupported" UI. Real functionality requires two physical UWB-capable iPhones (iPhone 11+, not SE); Xcode can also simulate NI between two booted simulators.

- Xcode project: `NearbyFinder.xcodeproj`, single target/scheme `NearbyFinder`
- Deployment target: iOS/macOS 26.5; bundle ID `jp.hibiki.NearbyFinder`
- No test targets yet. No Swift Package dependencies.

## Commands

Build for iOS Simulator (Debug):

```sh
xcodebuild -project NearbyFinder.xcodeproj -scheme NearbyFinder \
  -destination 'platform=iOS Simulator,name=iPhone 17' build
```

Compile-check macOS: same command with `-destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO`.

Run tests (once a test target is added): replace `build` with `test`; run a single test by appending `-only-testing:<TestTarget>/<TestClass>/<testMethod>`.

There is no linter configured.

## Architecture

Layering, bottom to top:

- `MultipeerSession.swift` — thin MC wrapper; advertises and browses simultaneously with service type `nearbyfinder`. Any peer that discovers the other invites unconditionally, and a ~3s jittered retry loop re-invites while unconnected — MC discovery is often one-directional, so a "only one designated side invites" scheme deadlocks (this bug shipped once; don't reintroduce it). Double sessions are prevented by rejecting invitations while already connected.
- `NearbySessionManager.swift` — `ObservableObject` owning the `NISession`; publishes `status` / `distance` / `direction`. All peer traffic is JSON-encoded `GameMessage` (defined in `GameModels.swift`): it handles `.discoveryToken` itself (runs the NI config) and forwards everything else via `onGameMessage`. Handles suspension/resume, peer-ended and timeout recovery, and permission denial (`.userDidNotAllow` must NOT trigger a session restart — it would loop). The whole implementation is wrapped in `#if os(iOS)` with an `#else` stub, because the NearbyInteraction module *imports* on macOS but its APIs are marked unavailable (`canImport` is not a sufficient guard).
- `GameManager.swift` — game state machine (`lobby → hiding → hunting → found`) plus `HapticPulser`. Roles sync over `.roleSelected` (a random `priority` breaks the both-picked-the-same-role tie). Found is confirmed physically, not by distance: the hunter uses the `HoldAndSlideButton` on the *treasure* device's screen — long-press 0.5 s to arm, then slide the thumb to the end (`confirmFound()`, treasure-side only), which sends `.found` to the hunter. The two-stage gesture exists because the hidden phone may be pressed against fabric/skin; don't replace it with a plain tap or long-press. Distance-based auto-detection was removed deliberately — proximity fires before the phone is physically located. It re-publishes the nested `NearbySessionManager`'s `objectWillChange` — nested `ObservableObject`s don't propagate automatically, so views observing `GameManager` still update on distance changes.
- Views: `ContentView.swift` (phase switch + `LobbyView`/`HidingView`/`TreasureWaitView`/`FoundView`) and `HuntingView.swift` (Find-My-style finding UI: black background, big arrow when NI provides `direction`, green fade + pulse rings under 1 m). Sets `isIdleTimerDisabled = true` so the hidden phone keeps ranging.

## Constraints and conventions

- The build uses `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` (Xcode 26 template). Framework delegate callbacks (MCSessionDelegate, NISessionDelegate) arrive on non-main queues, so delegate conformances are declared `nonisolated` and hop to the main actor via `Task { @MainActor in ... }`. Follow this pattern for any new delegate-based code.
- Info.plist: `GENERATE_INFOPLIST_FILE = YES` is combined with a checked-in `Info.plist` at the repo root (`INFOPLIST_FILE = Info.plist`), which holds the keys that can't be expressed as `INFOPLIST_KEY_*` build settings — notably the `NSBonjourServices` array (`_nearbyfinder._tcp/_udp`, required for MC browsing) plus the NI/local-network usage descriptions. It lives *outside* the `NearbyFinder/` folder on purpose: that folder is a `PBXFileSystemSynchronizedRootGroup`, and a plist inside it would be bundled as a resource and conflict.
- NI peer sessions suspend when either app leaves the foreground; both phones must keep the app frontmost.
