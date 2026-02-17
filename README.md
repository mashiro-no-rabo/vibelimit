# VibeLimitApp

macOS menu bar app that shows Claude usage as a pikanyan nyan cat progress bar.

The cat's position represents your 5-hour session utilization (0–100%), with a rainbow trail filling behind it. Click the menu bar item to see usage details and reset times.

If the OAuth token is missing or expired, the menu shows a "Run: claude auth login" item that opens Terminal to re-authenticate.

## Build

```sh
swift build
```

## Run manually

```sh
.build/debug/VibeLimitApp &
```

## Run via LaunchAgent

Copy the plist to LaunchAgents:

```sh
cp com.vibelimit.app.plist ~/Library/LaunchAgents/
```

Edit the binary path in the plist if needed, then load it:

```sh
launchctl load ~/Library/LaunchAgents/com.vibelimit.app.plist
```

The app will now start on login and restart if it crashes.

To reload after a rebuild:

```sh
launchctl unload ~/Library/LaunchAgents/com.vibelimit.app.plist && launchctl load ~/Library/LaunchAgents/com.vibelimit.app.plist
```

To stop:

```sh
launchctl unload ~/Library/LaunchAgents/com.vibelimit.app.plist
```

## Flash notification for Claude Code

The menu bar flashes (pulsing white overlay) when Claude Code needs your attention, and stops when Claude finishes responding. Click the menu bar item to dismiss manually.

Add these hooks to `~/.claude/settings.json`:

```json
{
  "hooks": {
    "Notification": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "swift -e 'import Foundation; DistributedNotificationCenter.default().postNotificationName(NSNotification.Name(\"com.vibelimit.flash.on\"), object: nil)'"
          }
        ]
      }
    ],
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "swift -e 'import Foundation; DistributedNotificationCenter.default().postNotificationName(NSNotification.Name(\"com.vibelimit.flash.off\"), object: nil)'"
          }
        ]
      }
    ]
  }
}
```
