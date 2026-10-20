# Stage 2 verification — 2026-10-20

Scope: safe import and owned, portable working packages. No tab-bar/layout
redesign, web playback lifecycle changes, or new export format in this stage.

## Implemented

- Guarded document/player entry points: recoverable errors for duplicate asset
  IDs, unsafe numbers, excessive dimensions and invalid timelines. Feature
  scanning no longer uses trapping integer conversions or duplicate-key maps.
- Bounded file reads; ZIP output checked before each append against declared
  size and the remaining 300 MiB budget. CRC, central/local header consistency,
  disk/encryption/type flags, duplicate paths and unsafe paths are checked.
- Cooperative parent-to-worker cancellation, including mid-extraction cleanup.
  Import builds in a staging folder; repair/animation selection validate a
  staged copy before replacing the owned package.
- Resource copies cannot overwrite existing package files, including the
  manifest or playback JSON. Remaining package capacity bounds each read
  before copying; shared references reuse the same copied image.
- Security-scoped access is always attempted and released only when acquired.
  File visibility/readability no longer bypasses the grant attempt.
- One image resolver for the import report and four native runtime providers
  used by playback/export. Exact `u+p` takes precedence; undecodable or
  escaping symlink resources are not reported as found. Renderer comparison
  now receives the same resource base URL.
- `.lottie` v1/v2 animation catalog and native selection sheet. The current
  preview is retained while choosing; cancelling removes the unaccepted
  package. The selection is applied after the chooser dismisses.
- Extracted animations/manifest/themes/fonts/state machines remain unchanged.
  Only the separately named playback JSON receives canonical image paths.
  Unsupported package execution features appear as import warnings.

## Resource policy

- JSON/image file: 50 MiB; compressed archive: 250 MiB; owned package and
  expanded archive: 300 MiB. The working playback JSON counts toward the
  package budget, including hidden files.
- ZIP: at most 10,000 entries; stored/raw-deflate supported. ZIP64,
  encrypted/multi-disk entries and symlinks are rejected.
- Canvas/image: dimensions at most 16,384, at most 16,777,216 pixels per
  image/canvas. Declared image buffers together must fit 300 MiB (RGBA).
- Animation: positive rate up to 1,000 fps; duration up to 24 hours.
  JSON numeric magnitude at most 1e9, at most 500,000 visited values and
  nesting depth 128. Canvas dimensions must be whole pixels.

These are safety limits, not a claim of support for every valid Lottie file
or a measured peak-memory guarantee. In particular, media decoding and four
simultaneous runtime instances still need memory profiling.

## Evidence

Environment: Xcode 27.1 (27A9275), iPhone 17 Pro simulator / iOS 26.5,
`91AF7F77-75A1-44B7-8C1D-E3DCE255A18E`.

- Initial regression run: 10 tests / 16 failed assertions, reproducing numeric,
  duplicate-ID, manifest overwrite, image resolution, CRC, streaming-size,
  cancellation and repair rollback defects.
- After first fixes: the same 10 tests passed.
- Catalog/selection regressions: 17 tests / 9 failed assertions before
  implementing selection, then the full 49-test suite passed.
- Boolean/asset-size regressions: six failed assertions before the final
  validation changes.
- Long Unicode service-name regression: reproduced an overlong owned path,
  then bounded the service basename while retaining the original report name.
- Fresh-context review found two P1 and two P2 issues: asset destination
  collisions, late repair budget checks, missing relative image repair and
  cancellation skipped for nonmatching search entries. Five regressions
  reproduced all four findings (11 failures before fixes); one fix pass
  addressed them, including validation of the staged playback JSON.
- A shared-resource repair regression confirms that multiple asset IDs may
  reference one copied file without triggering the collision guard.
- Final full suite: **60 tests, 0 failures**, including the previous 32 smoke
  tests and 28 focused import tests; command exited 0. No second reviewer
  pass was performed; the fix pass is verified by these regressions.
- Generic iOS device build: succeeded, unsigned; this is not a device run.
- Existing image/ZIP test fixtures now use real PNG data and correct CRCs,
  so stricter validation is tested against genuine readable resources.

Local evidence (temporary, not committed): `/tmp/flippie-stage2-red.log`,
`/tmp/flippie-stage2-red2.log`, `/tmp/flippie-stage2-red3.log`,
`/tmp/flippie-stage2-review-red.log`, `/tmp/flippie-stage2-complete.log`,
`/tmp/flippie-stage2-complete.xcresult`, `/tmp/flippie-stage2-reviewed-device.log`.

## Still unverified

- Real Files/iCloud provider grants and missing-asset folder repair on a
  physical device. Local file fixtures do not prove provider behavior.
- Manual chooser/interactive-dismiss transitions on a physical device.
- Peak memory on large packages and low-memory devices.
- Repair reports a recoverable error rather than overwriting a pre-existing
  file, including an undecodable image. Copy-on-write relocation for repairing
  such a collision is not implemented; missing (absent) resources are repairable.
- Existing SVG snapshot external-resource behavior, web waiters/timing and
  portable JSON export remain in stages 3–5; passing existing export tests
  is not proof of complete alpha/video-format conformance.

Package layout/manifest selection follows the official
[dotLottie v1](https://dotlottie.io/spec/1.0/) and
[dotLottie v2](https://dotlottie.io/spec/2.0/) specifications. Preserving
themes/state machines/font files is not the same as executing them.

GitHub publication/CI for this stage has not been requested or performed.
