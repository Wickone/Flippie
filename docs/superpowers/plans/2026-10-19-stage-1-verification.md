# Stage 1 verification — 2026-10-19

Scope: restore Flippie's build/test baseline and CI configuration. Application
logic, UI, deployment target and vendored runtime versions are unchanged.

## Changes

- Corrected both workflow jobs to use `Flippie.xcodeproj`; the hosted suite
  uses the existing shared `Flippie` scheme.
- Selected Xcode 26.3 through `DEVELOPER_DIR` and pinned iPhone 17 Pro /
  iOS 26.2 for CI on `macos-15`. Availability was checked against the
  [official runner inventory](https://github.com/actions/runner-images/blob/main/images/macos/macos-15-Readme.md).
- Kept all four library build entries; renamed the matrix job from
  “Snapshot build” to “Build”, matching what it actually checks.
- Added logs and `.xcresult` artifacts on success and failure, with seven-day
  retention, plus manual dispatch and read-only repository permissions.
- Updated README and development instructions to describe the active UI,
  JSON/`.lottie` import, existing export formats and known limitations.
- The existing `Flippie.xcscheme` already contains the test target and the
  expected package schemes are discoverable, so no scheme edit was necessary.

## Local evidence

Environment: Xcode 27.1 (27A9275), iOS 26.5 simulator, arm64, iPhone 17 Pro
`91AF7F77-75A1-44B7-8C1D-E3DCE255A18E`.

The earlier CoreSimulator mismatch was resolved when the selected Xcode's
`xcrun simctl` completed component registration and replaced the stale
1171.7 service with version 1174.9.2. No manual deletion of devices or Xcode
reinstallation was performed.

| Check | Result |
|---|---|
| Workflow references before change | Failed: missing `LottieLab.xcodeproj` |
| Workflow references after change | Passed: all project paths exist |
| YAML parsing and all embedded shell syntax | Passed |
| actionlint v1.7.7 | Passed, exit 0; official release SHA-256 verified |
| Shared/package scheme discovery | Flippie, Lottie300, Lottie350, Lottie400, Lottie461 |
| Full hosted XCTest suite | 32 passed, 0 failed, 0 skipped; command exit 0 |
| Lottie300 isolated simulator build | Passed, command exit 0 |
| Lottie350 isolated simulator build | Passed, command exit 0 |
| Lottie400 isolated simulator build | Passed, command exit 0 |
| Lottie461 isolated simulator build | Passed, command exit 0 |
| Project plist and whitespace validation | Passed |

Full test command:

```bash
xcodebuild test \
  -project Flippie.xcodeproj \
  -scheme Flippie \
  -destination 'platform=iOS Simulator,id=91AF7F77-75A1-44B7-8C1D-E3DCE255A18E' \
  -destination-timeout 30 \
  -parallel-testing-enabled NO \
  -derivedDataPath /tmp/flippie-stage1-simulator \
  -resultBundlePath /tmp/flippie-stage1-tests.xcresult \
  CODE_SIGNING_ALLOWED=NO
```

Each library was also built with `xcodebuild build -project Flippie.xcodeproj
-scheme <scheme> -destination 'generic/platform=iOS Simulator'
CODE_SIGNING_ALLOWED=NO ONLY_ACTIVE_ARCH=YES`, using a separate derived-data
directory from the full suite.

Temporary evidence files:

- `/tmp/flippie-stage1-tests.log` and `/tmp/flippie-stage1-tests.xcresult`.
- `/tmp/flippie-stage1-Lottie{300,350,400,461}.log` and matching result bundles.
- The XCTest result summary was read with `xcresulttool`, not inferred from
  the last log line.
- A fresh-context read-only review of the workflow and documentation found
  no Critical, Important or Minor issues before the stage 1 commit.

## Limits of this baseline

- The GitHub-hosted workflow has not been executed for this revision.
  Local testing used Xcode 27.1 / iOS 26.5, not CI's Xcode 26.3 / iOS 26.2.
  The first pushed revision must be checked in GitHub Actions.
- Old vendored runtimes still produce deprecation / future Swift 6 warnings;
  WebKit and the simulator's HEVC bridge also log diagnostics.
- `testTransparentMOVExporterUsesHEVCWithAlpha` currently accepts
  `alphaEncodingUnavailable`. Its green result does not prove successful
  transparent MOV encoding or fix the stage 5 alpha-verification issue.
- The suite is a functional smoke baseline, not comprehensive visual,
  accessibility, memory, cancellation or corrupted-input coverage.
- No application bugs from stages 2–8 were fixed as part of this stage.
