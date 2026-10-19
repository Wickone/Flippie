# Flippie

Flippie is an iOS tool for inspecting, testing, editing and exporting Lottie
animations. It imports JSON and `.lottie` packages, switches between four
embedded Lottie iOS versions, and exports JSON, GIF, MP4 and MOV.

## Requirements

- Xcode 26 or newer with the iOS 26 SDK or newer. The Liquid Glass API
  references require this SDK even though their use is guarded at runtime.
- iOS 17.5 or newer to run the app. Liquid Glass is available on iOS 26+;
  older supported systems use material fallbacks.
- Swift 5 language mode, as configured by the project and vendored package.
- An installed simulator runtime compatible with the selected Xcode.

CI uses Xcode 26.3 and iOS 26.2 on the GitHub `macos-15` runner.
See [Development setup](DEVELOPMENT.md) for commands and troubleshooting.

## Open and run

1. Open `Flippie.xcodeproj`.
2. Let Xcode resolve the local `Vendor/LottieVersions` package.
3. Select an installed iPhone or iPad simulator and run the shared `Flippie`
   scheme. To run on your phone, select the connected device and configure
   signing for your Apple development team.

No external Lottie package download is required: the comparison runtimes and
the SVG fallback are checked into the repository.

## Current functionality

### Import and inspect

- JSON and `.lottie` import through the iOS file picker.
- Initial animation selection from dotLottie v1/v2 manifests.
- Local copies of imported files and referenced image assets.
- Import report with format version from `v`, canvas, timing, assets,
  diagnostics and runtime load results.
- Folder selection to locate missing image assets.
- Six bundled example animations, opened by tapping the welcome message.

### Playback and comparison

- Play/pause, previous/next frame, speed and loop settings.
- In-app lottie-ios versions: **3.0.0, 3.5.0, 4.0.0 and 4.6.1**.
- Playback Settings opens from the ellipsis button on the preview.
- Renderer Test compares Core Animation and Main Thread using 4.6.1.
- Gaussian Blur (`ty: 29`) uses the bundled **lottie-web SVG 5.13.0**
  renderer for preview and frame export. In that case, selecting a different
  native runtime still uses the same web fallback.

### Edit

Edit opens a sheet with metadata, static/keyframed fill and stroke color
replacement, precomp colors, background and playback speed. Identical colors
are grouped. Apply updates the shared document and preview; reopening the
editor retains applied changes for the current in-memory document.

### Export

Export opens a sheet with JSON, GIF, MP4 and MOV options. Rendered formats
support size, FPS, speed and background settings, progress and cancellation.
MP4 is opaque H.264; transparent MOV requests HEVC with Alpha on supported
devices. Exported files can be sent through the system share sheet.

## Build and test

Build without installing a simulator:

```bash
xcodebuild build \
  -project Flippie.xcodeproj \
  -scheme Flippie \
  -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO
```

For tests, first list available devices with `xcrun simctl list devices available`.
Replace `SIMULATOR_UDID` below with an available iPhone's UUID:

```bash
xcodebuild test \
  -project Flippie.xcodeproj \
  -scheme Flippie \
  -destination 'platform=iOS Simulator,id=SIMULATOR_UDID' \
  -parallel-testing-enabled NO \
  CODE_SIGNING_ALLOWED=NO
```

The GitHub workflow runs the test suite and four isolated module builds. It
uploads logs and result bundles even when a job fails. The module matrix
checks compilation; it does not currently perform visual snapshot comparisons.

## Source layout

- `Flippie/ContentView.swift`: active preview, empty state and sheet routing.
- `Flippie/Models/`: document, metadata, edits and analysis.
- `Flippie/Services/`: import and export implementations.
- `Flippie/Views/`: players, edit/export sheets and shared components.
- `FlippieTests/`: hosted XCTest suite and fixtures.
- `Vendor/LottieVersions/`: four namespaced native runtimes and their licenses.
- `Flippie/Resources/`: bundled SVG renderer and logo resources.
- `Tools/FigmaMCP/`: optional development tooling.

`AnimationPlayerView.swift` and `AnimationEditorView.swift` are legacy
reference views excluded from the application target.

## Known limitations

- Applied edits are not yet restored after an app restart.
- A successful runtime load is not proof of visual fidelity.
- The shared blur fallback does not compare native runtime behavior, and its
  Back-and-Forth mode currently behaves as a normal loop.
- Standalone JSON export does not yet embed external image dependencies.
- Transparent MOV verification and large/long exports need further validation.
- Gradient/text/solid color editing and per-layer transforms are not implemented
  in the active editor. Not every detected property is editable.

The remaining work is described in the
[improvement plan](docs/superpowers/plans/2026-10-19-flippie-improvements.md).

## Dependencies and license

The app is MIT licensed; vendored code retains its own licenses.

- [lottie-ios](https://github.com/airbnb/lottie-ios): 3.0.0, 3.5.0, 4.0.0, 4.6.1.
- [lottie-web](https://github.com/airbnb/lottie-web): 5.13.0 SVG runtime.
