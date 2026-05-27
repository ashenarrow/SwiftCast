# SwiftCast

SwiftCast is a LAN-first iOS screen mirror for Chrome. It captures the full iOS screen with a ReplayKit Broadcast Upload Extension, encodes the screen with hardware H.264, sends encoded frames over unreliable WebRTC DataChannels, decodes with WebCodecs in Chrome, and paints directly to a canvas.

This repository is scaffolded for macOS/Xcode development. The current workspace is Windows, so iOS build and ReplayKit validation must be done on a Mac with a real iPhone.

## Architecture

- `ios/` contains the SwiftUI host app, ReplayKit Broadcast Upload Extension, shared protocol code, and XcodeGen/CocoaPods setup.
- `web/` contains the Chrome WebCodecs viewer served by the iOS app.
- `tunnel/` contains the Railway-ready pairing/signaling service for broadcasts that continue after the iOS host app leaves the foreground.
- `docs/PROTOCOL.md` documents the binary media packets, settings, and signaling endpoints.

For real use, the browser loads the Railway tunnel URL and pairs with the Broadcast Upload Extension by code. The tunnel stores offers, answers, ICE candidates, and settings only; it never relays screen video or audio. The iOS host app still includes a local HTTPS server, but that is only a foreground fallback because iOS suspends ordinary app work when you leave the app.

The Broadcast Upload Extension owns the active WebRTC peer and sends media directly to Chrome over SCTP DataChannels.

## Browser Requirements

SwiftCast targets desktop Chrome. The screen stream intentionally does not use an HTML5 `<video>` element or a normal WebRTC video track. Chrome must support:

- WebRTC DataChannels
- WebCodecs `VideoDecoder`
- AudioWorklet
- Canvas 2D rendering

Unsupported browsers receive a clear compatibility message.

WebCodecs `VideoDecoder` requires a secure context in Chrome. SwiftCast includes a local-development TLS identity at `ios/App/Resources/swiftcast-local.p12` so the host app can serve `https://<iphone-lan-ip>:<port>`. Chrome will show a certificate warning unless you install/trust your own certificate for production builds.

## Local Web Development

```powershell
cd web
npm install
npm run build
npm run dev
```

The web build is copied into the iOS app bundle by the Xcode build script in `ios/project.yml`.

## Railway Tunnel

Deploy the repository root to Railway. Keep the service root at the repo root so Railway can build both `web/` and `tunnel/`.

Railway settings:

```bash
Build command: npm --prefix web ci && npm --prefix web run build && npm --prefix tunnel ci && npm --prefix tunnel run build
Start command: npm --prefix tunnel start
Healthcheck path: /healthz
Node version: 22
```

Recommended environment variables:

```bash
SWIFTCAST_PUBLIC_URL=https://swiftcast-production.up.railway.app
SWIFTCAST_SESSION_TTL_MS=600000
SWIFTCAST_MAX_BODY_BYTES=1mb
```

Open the viewer at:

```text
https://swiftcast-production.up.railway.app/watch?pair=YOUR_PAIR_CODE
```

The iOS app defaults to `https://swiftcast-production.up.railway.app`, and you can change it in the Pairing card before starting the broadcast. The browser-side controls are intentionally viewer controls only: start peer, enable audio playback, fullscreen, keyframe request, ROI request, audio sync, and stats display. Capture-heavy settings such as FPS, resolution, bitrate range, temporal compression, P-frames, app audio, mic, gain, and encoder behavior live in the iOS app so the ReplayKit extension can read them before capture begins.

## iOS Setup on macOS

Install Xcode, CocoaPods, and XcodeGen, then:

```bash
cd ios
xcodegen generate
pod install
open SwiftCast.xcworkspace
```

Before running on a real device, update these values in `ios/project.yml`:

- `DEVELOPMENT_TEAM`
- `PRODUCT_BUNDLE_IDENTIFIER` for `SwiftCast` and `SwiftCastBroadcast`
- `SWIFTCAST_APP_GROUP`

ReplayKit Broadcast Upload Extensions cannot be properly validated in the iOS simulator.

## Signed Sideload Build

The uploaded CI IPA is unsigned and will not sideload. iOS requires a valid Apple signing team, provisioning profiles, and matching entitlements. For SwiftCast, the host app and Broadcast Upload Extension must use explicit App IDs, and the App Group must exist in your Apple developer account.

1. In Apple Developer, create these identifiers:

- App ID: `com.ashenarrow.swiftcast`
- App ID: `com.ashenarrow.swiftcast.broadcast`
- App Group: `group.com.ashenarrow.swiftcast`

2. In `ios/project.yml`, replace the bundle IDs/app group with your own reverse-DNS identifiers if needed, then set `DEVELOPMENT_TEAM` to your Apple Team ID.

3. Also update `ios/ExportOptions.Development.plist` and replace `YOUR_TEAM_ID`.

4. Build a signed development IPA on macOS:

```bash
cd web
npm ci
npm run build

cd ../ios
xcodegen generate
pod install --repo-update

xcodebuild \
  -workspace SwiftCast.xcworkspace \
  -scheme SwiftCast \
  -configuration Release \
  -sdk iphoneos \
  -destination 'generic/platform=iOS' \
  -archivePath build/SwiftCast.xcarchive \
  -allowProvisioningUpdates \
  DEVELOPMENT_TEAM=YOUR_TEAM_ID \
  SWIFTCAST_APP_GROUP=group.com.ashenarrow.swiftcast \
  archive

xcodebuild \
  -exportArchive \
  -archivePath build/SwiftCast.xcarchive \
  -exportPath build/export \
  -exportOptionsPlist ExportOptions.Development.plist \
  -allowProvisioningUpdates
```

The signed IPA will be in `ios/build/export`. If you use a free Apple account, App Groups and Broadcast Upload Extension provisioning may be limited; a paid Apple Developer account is the reliable path for this app.

## GitHub CI

Two GitHub Actions workflows are included:

- `.github/workflows/web.yml` builds and audits the Chrome WebCodecs client on Ubuntu.
- `.github/workflows/ios.yml` builds the iOS app and Broadcast Upload Extension on macOS with code signing disabled for CI.
- `.github/workflows/tunnel.yml` builds the Railway tunnel and uploads a deployable service artifact.

The iOS workflow validates compilation only. Real ReplayKit capture, app audio, and low-latency streaming still require a signed build on a physical iPhone.

Successful iOS CI runs upload `swiftcast-ios-debug-unsigned`, which contains:

- `SwiftCast-unsigned.ipa`
- `SwiftCast.app.zip`
- `SwiftCast-dSYMs.zip` when debug symbols are emitted
- `xcodebuild.log`

The CI IPA is unsigned because GitHub Actions builds with `CODE_SIGNING_ALLOWED=NO`. Use a signed archive/export workflow before installing on devices outside local development.

## Defaults

- Gaming preset: 1280x720, 30 fps, 3-8 Mbps
- H.264 hardware encode only
- Temporal compression on
- P-frames on
- B-frames/frame reordering off
- Keyframe interval: 1000 ms
- Dynamic bitrate on
- App audio on
- Mic audio off
- ROI off by default, with manual/motion/touch/center modes exposed
