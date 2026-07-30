# Development setup

## Requirements

- Xcode 16.4 or newer
- iOS 17.5 deployment target
- A matching iOS Simulator runtime installed in Xcode

## First run

1. Open `Flippie.xcodeproj`.
2. Wait for Swift Package Manager to resolve Lottie.
3. Select an installed iOS simulator.
4. Run the shared `Flippie` scheme.

## Command-line verification

```bash
xcodebuild test \
  -project Flippie.xcodeproj \
  -scheme Flippie \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro,OS=latest' \
  CODE_SIGNING_ALLOWED=NO
```

If Xcode reports a CoreSimulator version mismatch, finish Xcode's first-launch
setup and restart macOS. The installed Xcode, platform components, and
CoreSimulator service must come from the same Xcode release.

## Renderer and version testing

Flippie links four namespaced Lottie modules for interactive version
switching. Its **Renderer Test** screen uses `Lottie461` to load the same JSON
with forced Core Animation and Main Thread configurations.

The comparison matrix is:

- 3.0.0 — first Swift-only 3.x renderer baseline
- 3.5.0 — final 3.x release
- 4.0.0 — initial 4.x renderer transition
- 4.6.1 — current stable comparison runtime

The vendored source lives in `Vendor/LottieVersions`. The same package targets
also have separate schemes used by the CI build matrix.

## Source layout

`ContentView`, `BundledAnimationsView`, `EditPropertiesSheet`, and
`MainExportView` form the active application flow. `AnimationPlayerView` and
`AnimationEditorView` are retained as legacy reference code and are excluded
from the application target.
