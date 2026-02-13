# VibeLimitApp

macOS menu bar app that shows Claude usage as a pikanyan nyan cat progress bar.

The cat's position represents your 5-hour session utilization (0–100%), with a rainbow trail filling behind it. Click the menu bar item to see usage details and reset times.

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

To stop:

```sh
launchctl unload ~/Library/LaunchAgents/com.vibelimit.app.plist
```
