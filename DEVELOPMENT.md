# Development setup

## Toolchain

The app deployment target is **iOS 17.5**. Building requires **Xcode 26 or
newer with the iOS 26 SDK or newer**, because the source references Liquid
Glass APIs. Runtime availability checks retain fallbacks for older devices;
they do not allow an older SDK to compile unknown APIs.

The project and local Swift package use Swift 5 language mode. The older
comparison runtimes produce deprecation and future Swift 6 compatibility
warnings; enabling Swift 6 is not part of the CI-baseline change.

CI pins:

- Runner: `macos-15`.
- Developer directory: `/Applications/Xcode_26.3.app/Contents/Developer`.
- Test destination: `iPhone 17 Pro`, iOS `26.2`.
- Reference: [GitHub macOS 15 image inventory](https://github.com/actions/runner-images/blob/main/images/macos/macos-15-Readme.md).

`DEVELOPER_DIR` selects Xcode for the workflow without changing a developer's
global `xcode-select` setting. If that Xcode or simulator is removed from the
runner image, update both pins after checking the inventory; do not silently
switch to `latest`.

## First run

1. Open `Flippie.xcodeproj`.
2. Resolve the local `Vendor/LottieVersions` package.
3. Select an installed iOS simulator and run the shared `Flippie` scheme.
4. For a device build, select the connected device and your signing team.

The checked-in `Flippie.xcscheme` includes `FlippieTests` in its Test action.
Xcode also exposes four package schemes: `Lottie300`, `Lottie350`,
`Lottie400` and `Lottie461`.

## Local verification

Inspect the selected environment first:

```bash
xcode-select -p
xcodebuild -version
xcrun simctl list runtimes
xcrun simctl list devices available
xcodebuild -list -project Flippie.xcodeproj
```

Build the app for a simulator without launching it:

```bash
xcodebuild build \
  -project Flippie.xcodeproj \
  -scheme Flippie \
  -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO
```

Run the whole existing XCTest suite on an available iPhone. Replace
`SIMULATOR_UDID` with the UUID printed by `simctl`:

```bash
set -o pipefail
xcodebuild test \
  -project Flippie.xcodeproj \
  -scheme Flippie \
  -destination 'platform=iOS Simulator,id=SIMULATOR_UDID' \
  -destination-timeout 60 \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/Flippie-local-tests-derived-data \
  -resultBundlePath /tmp/Flippie-local-tests.xcresult \
  CODE_SIGNING_ALLOWED=NO \
  2>&1 | tee /tmp/Flippie-local-tests.log
```

Choose fresh result-bundle and derived-data paths when repeating this command;
Xcode refuses to overwrite an existing `.xcresult`. Tests are hosted by the
app and include UIKit/WebKit rendering and codec checks, so a live compatible
simulator is required. Serialization is intentional: the tests use app windows
and rendering resources. Do not replace a failing full run with selected
passing tests.

Read the result bundle:

```bash
xcrun xcresulttool get test-results summary \
  --path /tmp/Flippie-local-tests.xcresult
```

## Isolated runtime builds

The following is a compilation check for each embedded library. It is not a
snapshot comparison and does not validate pixels or animation behavior:

```bash
for scheme in Lottie300 Lottie350 Lottie400 Lottie461; do
  xcodebuild build \
    -project Flippie.xcodeproj \
    -scheme "$scheme" \
    -destination 'generic/platform=iOS Simulator' \
    -derivedDataPath "/tmp/Flippie-$scheme-derived-data" \
    CODE_SIGNING_ALLOWED=NO \
    ONLY_ACTIVE_ARCH=YES || exit $?
done
```

The modules are built separately in CI, with `fail-fast: false` so a failure
in one runtime does not prevent collecting diagnostics from the others.

## CI results

`.github/workflows/ios.yml` runs on pushes, pull requests and manual dispatch.

- `Flippie · build and test` builds the app and runs its hosted test suite.
- `Build · Lottie <version>` compiles one namespaced runtime per matrix entry.
- Every job uploads its log and `.xcresult` with `if: always()`, retained for
  seven days. Test artifacts also include the toolchain, installed devices
  and discovered schemes.
- Build pipelines use `pipefail` so successful log capture cannot hide an
  `xcodebuild` failure. No signing credentials are required.
- A local green result does not establish a green GitHub Actions run. Verify
  the checks for the pushed revision before calling remote CI successful.

## CoreSimulator troubleshooting

If Xcode reports `CoreSimulator is out of date` or lists no usable test
destinations:

1. Check `xcode-select -p`, `xcodebuild -version`, and the CoreSimulator
   versions in the error. A listed device in `simctl` is insufficient if
   `xcodebuild -showdestinations -project Flippie.xcodeproj -scheme Flippie`
   cannot use it.
2. Open the selected Xcode and finish its requested component setup. Run the
   selected Xcode's `xcrun simctl list runtimes` again; this can refresh its
   service registration after an Xcode update.
3. If Xcode still requests authorization or component installation, complete
   that step explicitly. Restart macOS if the old service remains loaded.
   Do not delete the simulator device set or reinstall Xcode as a first step.
4. Retry `xcodebuild -showdestinations`, then run the full suite with a valid
   simulator UUID. Missing environments are infrastructure failures, not
   passing or skipped application tests.

Hardware-dependent HEVC-alpha behavior must be distinguished from render or
verification failures. The current MOV test accepts
`alphaEncodingUnavailable`; a green baseline does not resolve the alpha
verification defect tracked in stage 5 of the improvement plan.

## Renderer behavior and source layout

The comparison runtimes are exactly 3.0.0, 3.5.0, 4.0.0 and 4.6.1. Renderer
Test uses 4.6.1 with forced Core Animation and Main Thread modes. Gaussian Blur
uses lottie-web SVG for every selected native version; the import report
marks that as fallback.

`ContentView`, `BundledAnimationsView`, `EditPropertiesSheet` and
`MainExportView` form the active flow. `AnimationPlayerView` and
`AnimationEditorView` remain legacy references excluded from the app target.

See the [improvement plan](docs/superpowers/plans/2026-10-19-flippie-improvements.md)
and the [stage 1 verification record](docs/superpowers/plans/2026-10-19-stage-1-verification.md)
for the measured baseline and remaining work.
