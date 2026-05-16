# Proteles

A native Aardwolf MUD client for macOS, and later iPad.

The design and implementation plan lives in **[PLAN.md](PLAN.md)** — read that first.

## Status

Phase 0 (bootstrap). Skeleton builds and tests pass. No connection logic yet — see PLAN.md §8 for the phased roadmap.

## Layout

```
Package.swift                 SwiftPM manifest (one package, three libraries)
Sources/
  MudCore/                    platform-agnostic core (networking, parsers, state, ...)
  MudUI/                      shared SwiftUI chrome
  MudOutputView_macOS/        AppKit-backed text view host
Tests/                        XCTest / swift-testing suites per library
apps/
  ProtelesApp_macOS/          XcodeGen-generated app bundle
fixtures/                     recorded sessions, golden files (populated later)
tools/                        CLIs (plugin migrator, etc.) — populated later
docs/                         API & user docs (populated later)
```

The submodules at the repo root (`mushclient`, `aardwolfclientpackage`, `mudlet`, `iterm2`) are reference-only — see PLAN.md §14.

## Development

Requires macOS 14+, Xcode 16+ (Swift 6).

```sh
# Build & test the libraries
swift build
swift test

# Lint & format (install once: brew install swiftformat swiftlint xcodegen)
swiftformat --lint .
swiftlint

# Install the pre-commit hook
./scripts/install-hooks.sh

# Generate the macOS app Xcode project
cd apps/ProtelesApp_macOS && xcodegen generate
open ProtelesApp_macOS.xcodeproj
```

## Documents

- **[PLAN.md](PLAN.md)** — design, architecture, phases, testing, risks, decision log.
- `Native_macOS_MUD_client.md`, `Native_macOS_MUD_client_follow-up.md` — early scoping conversations.
