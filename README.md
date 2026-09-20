# Clipboard Sync

Real-time LAN clipboard sync between a **Mac desktop app** and an **Android
app**. Both devices must be on the same Wi-Fi network. Text only; nothing is
sent to a cloud service.

## Download

Use the download site: **clipboard-sync-pinki.netlify.app**

Install both the Mac and Android apps. Start the Mac server first, then start
sync on Android and select the discovered Mac.

If macOS Gatekeeper blocks the unsigned app, right-click it, choose **Open**,
then confirm. Android shows a persistent **Clipboard Sync Active** notification
while sync is running.

## How it works

1. The Mac app advertises itself with mDNS/Bonjour as `_clipboardsync._tcp`.
2. Android discovers the Mac on the same Wi-Fi network.
3. Android connects to the Mac over a persistent WebSocket on port `8080`.
4. Clipboard changes are sent immediately in either direction.

The Mac uses `NSPasteboard`; Android uses `ClipboardManager` inside a foreground
service. The desktop polls its macOS clipboard change token every 100 ms, while
Android receives clipboard-change callbacks from the operating system.

## Project structure

```text
clipboard_sync/
├── desktop_app/       # macOS Flutter server application
├── android_app/       # Android Flutter UI and Kotlin foreground service
├── website/           # Static Mac + Android download site
├── scripts/           # Release packaging
└── doc/               # Project notes and feature designs
```

## Run locally

### Mac desktop app

```bash
cd desktop_app
flutter pub get
flutter run -d macos
```

### Android app

```bash
cd android_app
flutter pub get
flutter run
```

## Package releases

Build the Mac `.app`/`.dmg` and Android APK, then copy them to
`website/downloads/`:

```bash
chmod +x scripts/pack-downloads.sh
./scripts/pack-downloads.sh
npx netlify deploy --prod --dir=website
```

## Current limitations

- macOS desktop and Android only
- Text clipboard content only
- Both devices must be on the same local Wi-Fi network
- The Mac app must remain open

## Security roadmap

The current release uses a local WebSocket connection. The active design work
for device identity, WSS/TLS, and first-time device pairing is in
`doc/feature/secure-device-pairing.md`.
