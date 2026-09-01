# VibeLimitApp

macOS menu bar app that shows your Claude 5-hour session headroom as a Japanese word.

## What it does

- Displays the 5-hour session headroom as a word: `余裕` (0–33% used), `半分` (34–66%), `間近` (67–89%), `限界` (90–100%)
- Click the menu bar item to see: session/weekly usage % with ▰▱ progress bars, session resets in h/m, weekly resets in days
- Usage refreshes every 60 seconds
- Requires Claude Desktop to be logged in (reads its cookies for API access)
- On any error the title is a generic `Error`; the dropdown carries the detail, plus an "Open Claude Desktop to log in" item for auth errors

## Tech stack

- Swift (SPM executable), macOS 13+
- AppKit for the menu bar (NSStatusItem with attributedTitle)
- No SwiftUI, no Xcode project — just `swift build`

## Project structure

```
Package.swift                              # SPM manifest
Sources/VibeLimitApp/main.swift            # All app code (single file)
README.md                                  # Build & launch setup docs
.gitignore
```

## Key implementation details

### Status bar title
- `NSStatusItem` with `variableLength`
- Title is an `NSAttributedString` using `NSFont.systemFont(ofSize: 13, weight: .regular)`
- `headroomWord(percent:)` maps utilization to the word; exact percentages stay in the dropdown
- All error states show `Error` (`…` before the first fetch); the specific cause goes in the dropdown

### Usage API
- Endpoint: `GET https://claude.ai/api/organizations/{orgId}/usage`
- Auth: `sessionKey` and `lastActiveOrg` cookies from Claude Desktop
- Response: `{ "five_hour": { "utilization": 37.0, "resets_at": "..." }, "seven_day": { ... } }`
- Utilization is a percentage (0–100), `resets_at` is ISO 8601 with fractional seconds
- Error handling: 401/403 → auth error (prompts login), 429 → rate limited, network/parse errors shown in menu

### Claude Desktop cookies
- Reads encrypted Chromium cookies from `~/Library/Application Support/Claude/Cookies` (SQLite)
- Decryption key: macOS Keychain item "Claude Safe Storage", derived via PBKDF2 (salt "saltysalt", 1003 iterations, 16-byte key)
- AES-128-CBC decryption (IV = 16 spaces), strip 32-byte prefix from plaintext
- Shelling out to `/usr/bin/security` CLI avoids repeated Keychain access prompts (the Security framework prompts on every rebuild since unsigned binaries get new identities)
- Extracts `sessionKey` (auth) and `lastActiveOrg` (org ID for API URL)

### Menu
- Dropdown shows session bar/percent/reset, then weekly bar/percent/reset
- `Refresh` (⌘R), `Quit` (⌘Q)
- No dock icon: `app.setActivationPolicy(.accessory)`

## Build & run

```sh
swift build
.build/debug/VibeLimitApp &
```

### LaunchAgent (run via launchctl)

```sh
cp com.vibelimit.app.plist ~/Library/LaunchAgents/
launchctl load ~/Library/LaunchAgents/com.vibelimit.app.plist
```

To reload after a build: `launchctl unload ~/Library/LaunchAgents/com.vibelimit.app.plist && launchctl load ~/Library/LaunchAgents/com.vibelimit.app.plist`

**Always reload the app after building.**

To stop: `launchctl unload ~/Library/LaunchAgents/com.vibelimit.app.plist`
