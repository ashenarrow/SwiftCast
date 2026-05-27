# SwiftCast

SwiftCast is a LAN-first iOS screen mirror for Chrome. It captures the full iOS screen with a ReplayKit Broadcast Upload Extension, encodes the screen with hardware H.264, sends encoded frames over unreliable WebRTC DataChannels, decodes with WebCodecs in Chrome, and paints directly to a canvas.

This repository is scaffolded for macOS/Xcode development. The current workspace is Windows, so iOS build and ReplayKit validation must be done on a Mac with a real iPhone.

## Architecture

- `ios/` contains the SwiftUI host app, ReplayKit Broadcast Upload Extension, shared protocol code, and XcodeGen/CocoaPods setup.
- `web/` contains the Chrome WebCodecs viewer served by the iOS app.
- `docs/PROTOCOL.md` documents the binary media packets, settings, and signaling endpoints.

The iOS host app serves the website over local HTTPS and bridges initial signaling through local HTTP-style endpoints. It never relays media. The Broadcast Upload Extension owns the active WebRTC peer and sends media directly to Chrome over SCTP DataChannels.

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
- App group identifiers under `CODE_SIGN_ENTITLEMENTS`
- Bundle identifiers if needed

ReplayKit Broadcast Upload Extensions cannot be properly validated in the iOS simulator.

## GitHub CI

Two GitHub Actions workflows are included:

- `.github/workflows/web.yml` builds and audits the Chrome WebCodecs client on Ubuntu.
- `.github/workflows/ios.yml` builds the iOS app and Broadcast Upload Extension on macOS with code signing disabled for CI.

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
