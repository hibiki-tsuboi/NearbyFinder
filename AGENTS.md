# Repository Guidelines

## Project Structure & Module Organization

`NearbyFinder/` contains the iPhone SwiftUI app. Core coordination lives in `GameManager.swift`, peer transport in `MultipeerSession.swift`, UWB ranging in `NearbySessionManager.swift`, and screen-level UI in `ContentView.swift`, `HuntingView.swift`, and `ARTreasureView.swift`. `NearbyFinderWatch/` is the watchOS companion target. Asset catalogs are stored under each target's `Assets.xcassets`; documentation images belong in `docs/`. Keep the root `Info.plist` in place: it supplies Bonjour, local-network, camera, and Nearby Interaction keys without being copied as a synchronized-folder resource.

## Build, Test, and Development Commands

- `xcodebuild -project NearbyFinder.xcodeproj -scheme NearbyFinder -destination 'platform=iOS Simulator,name=iPhone 17' build` builds the iOS app in Debug.
- `xcodebuild -project NearbyFinder.xcodeproj -scheme NearbyFinderWatch -destination 'generic/platform=watchOS Simulator' build` checks the Watch app independently.
- Open `NearbyFinder.xcodeproj` in Xcode to run paired simulators or deploy to devices.

There are no Swift Package dependencies. Real ranging behavior requires two foregrounded UWB-capable iPhones; simulator builds verify compilation but not the full radio workflow.

## Coding Style & Naming Conventions

Use standard Swift formatting with four-space indentation. Name types in `UpperCamelCase`, members in `lowerCamelCase`, and keep one primary type or responsibility per file. Follow the existing SwiftUI/ObservableObject organization and use `// MARK:` to separate substantial sections. The project defaults actor isolation to `MainActor`; declare framework delegate callbacks `nonisolated` and return to the main actor with `Task { @MainActor in ... }`. No formatter or linter is configured, so match nearby code and keep warnings at zero.

## Testing Guidelines

No XCTest target currently exists. Before submitting, build both schemes and manually exercise connection, role selection, hiding, hunting, timeout, rematch, and reconnection. Changes to Nearby Interaction or MultipeerConnectivity should be validated on two supported iPhones. If adding tests, create a dedicated XCTest target, name files `FeatureTests.swift`, and methods `testExpectedBehavior`.

## Commit & Pull Request Guidelines

Recent commits use short Japanese summaries focused on one completed change, for example `測距が始まらないデグレを修正`. Keep commits narrowly scoped and use the same descriptive style. Pull requests should explain behavior and architecture impact, list build/manual-test results and devices used, link relevant issues, and include screenshots or recordings for UI changes. Call out permission, Info.plist, connectivity, or mixed-build compatibility changes explicitly.
