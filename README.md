# Clipboard Sync

A cross-platform clipboard synchronization system that enables seamless copy-paste between desktop computers and Android devices over local Wi-Fi network.

## Demo

Watch the app in action: [Demo Video](https://streamable.com/ebb7o4)

## Overview

This project implements a real-time clipboard synchronization solution that works across macOS, Windows, Linux, and Android. It uses mDNS/Bonjour for automatic device discovery and WebSocket for bidirectional communication, ensuring clipboard content is synced instantly between devices without any manual configuration.

## Features

- Bidirectional clipboard synchronization (desktop ↔ Android)
- Automatic device discovery using mDNS/Bonjour protocol
- Cross-platform desktop support (macOS, Windows, Linux)
- Real-time sync with sub-100ms latency on local networks
- No manual IP address configuration required
- Privacy-focused - all data stays on local network
- Persistent connection with automatic reconnection

## Architecture

The system consists of two main components:

**Desktop Application (Flutter)**
- GUI application for starting/stopping the sync server
- WebSocket server running on port 8080
- mDNS service broadcaster for auto-discovery
- Platform-specific clipboard monitoring (polling every 100ms)
- Cross-platform clipboard access helpers

**Android Application (Flutter + Kotlin)**
- Flutter-based UI for user interactions
- mDNS service discovery client
- Native Kotlin Foreground Service for 24/7 operation
- ClipboardManager for instant clipboard change detection
- WebSocket client for server communication

## Communication Flow

1. Desktop broadcasts its presence via mDNS with service type "_clipboardsync._tcp"
2. Android discovers the service and extracts IP address and port
3. WebSocket connection is established between devices
4. Clipboard changes are detected and transmitted in real-time
5. Received content is written to the destination device's clipboard

## Technology Stack

**Desktop:**
- Flutter for cross-platform GUI
- Bonsoir package for mDNS broadcasting
- shelf and shelf_web_socket for WebSocket server
- Platform-specific clipboard commands (pbcopy/pbpaste, PowerShell, xclip)

**Android:**
- Flutter for UI layer
- Bonsoir package for mDNS discovery
- Native Kotlin for background service
- ClipboardManager API for clipboard operations
- OkHttp library for WebSocket client
- Foreground Service for persistent operation

**Protocol:**
- WebSocket for bidirectional communication
- mDNS/Bonjour for service discovery
- TCP/IP over local Wi-Fi network

## Project Structure

```
clipboard_sync/
├── desktop_app/              # Cross-platform desktop application
│   ├── lib/main.dart         # Application logic and UI
│   ├── macos/                # macOS platform configuration
│   ├── windows/              # Windows platform configuration
│   ├── linux/                # Linux platform configuration
│   └── pubspec.yaml          # Flutter dependencies
│
├── android_app/              # Android mobile application
│   ├── lib/main.dart         # Flutter UI and discovery logic
│   ├── android/              # Android native code
│   └── pubspec.yaml          # Flutter dependencies
│
└── README.md                 # This file
```

## Installation & Setup

### Desktop Application

**Prerequisites:**
- Flutter SDK installed
- For macOS: CocoaPods installed
- For Linux: xclip package installed

**macOS:**
```bash
cd desktop_app
cd macos && pod install && cd ..
flutter pub get
flutter run
```

**Windows:**
```bash
cd desktop_app
flutter pub get
flutter run
```

**Linux:**
```bash
sudo apt-get install xclip
cd desktop_app
flutter pub get
flutter run
```

### Android Application

**Prerequisites:**
- Flutter SDK installed
- Android SDK configured

**Steps:**
```bash
cd android_app
flutter pub get
flutter run
```

## Usage

1. Ensure both devices are connected to the same Wi-Fi network
2. Launch the desktop application and click "Start Server"
3. Launch the Android application and click "Start Sync"
4. Tap your desktop's hostname under "Found Servers" to connect
5. Copy text on either device - it will instantly appear on the other device's clipboard

## Technical Details

**Clipboard Detection:**
- Desktop: Polling mechanism checks clipboard every 100ms
- Android: Event-driven using ClipboardManager.OnPrimaryClipChangedListener

**Service Discovery:**
- Uses mDNS protocol on UDP port 5353
- Multicast group: 224.0.0.251
- Service type: "_clipboardsync._tcp"

**Data Transfer:**
- WebSocket protocol over TCP
- Port: 8080
- Text-based payload
- Persistent bidirectional connection

**Background Operation:**
- Android uses Foreground Service to maintain clipboard monitoring when app is closed
- Service displays persistent notification as required by Android

## Platform-Specific Implementation

**macOS Clipboard:**
- Read: `pbpaste` command
- Write: `echo "text" | pbcopy` command

**Windows Clipboard:**
- Read: `powershell -command Get-Clipboard`
- Write: `powershell -command Set-Clipboard -Value text`

**Linux Clipboard:**
- Read: `xclip -selection clipboard -o`
- Write: `echo "text" | xclip -selection clipboard`

**Android Clipboard:**
- Native ClipboardManager API via Kotlin
- Method Channel bridge to Flutter

## Dependencies

**Desktop (pubspec.yaml):**
- flutter
- bonsoir: ^7.1.4
- shelf: ^1.4.0
- shelf_web_socket: ^2.0.0
- web_socket_channel: ^3.0.0

**Android (pubspec.yaml):**
- flutter
- bonsoir: ^7.1.4

**Android Native (build.gradle):**
- OkHttp for WebSocket client
- Android system APIs (ClipboardManager, NotificationCompat)

## Security & Privacy

- All communication occurs over local network only
- No data is transmitted to external servers or cloud services
- No authentication required (assumes trusted local network)
- Clipboard content is transmitted in plain text over WebSocket

## Limitations

- Requires both devices on same Wi-Fi network
- Currently supports text clipboard content only (no images or files)
- Desktop application must remain open for sync to work
- Android app must be started to initiate connection

## Future Enhancements

- Support for image and file clipboard content
- End-to-end encryption for clipboard data
- Multi-device support (one desktop, multiple mobile devices)
- Clipboard history feature
- Internet-based sync via relay server
- iOS support

## License

This project is provided as-is for educational and personal use.
