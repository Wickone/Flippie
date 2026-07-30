# Flippie

Flippie is an iOS motion QA and export tool for Lottie animations. The
current prototype supports JSON import, playback, basic color inspection,
cross-version rendering, and JSON/GIF export. MP4 export is planned.

## Features

### 🎬 Animation Player
- **Import**: Load Lottie JSON files from your device
- **Playback Controls**: Play, pause, rewind, fast forward
- **Speed Control**: Adjust animation speed (0.1x to 3.0x)
- **Loop Modes**: Play once, loop, or auto-reverse
- **Progress Scrubbing**: Manually control animation timeline
- **Export**: Save animations as JSON or GIF

### ✏️ Animation Editor
- **Color Editing**: Modify static and keyframed fill/stroke colors
- **Precomp Support**: Discover and update colors inside asset layers
- **Persistent Draft**: Applied edits remain when the editor is reopened
- **Real Background**: Background is exported as a Lottie solid layer
- **Transform Controls**: Adjust scale, rotation, and opacity per layer
- **Real-time Preview**: See changes instantly in the preview window
- **Property Inspector**: Fine-tune animation properties

### 📁 File Management
- **Import Support**: JSON file import via document picker
- **Export Options**: JSON and GIF export capabilities
- **Share Integration**: Built-in iOS sharing for exported files

### 🧪 Runtime Comparison
- **Format version**: Displays the animation's `v` field
- **Renderer test**: Compares Core Animation and Main Thread side by side
- **Library matrix**: CI builds Lottie iOS 3.0.0, 3.5.0, 4.0.0, and 4.6.1
- **In-app versions**: Switch Lottie iOS 3.0.0, 3.5.0, 4.0.0, and 4.6.1
- **Gaussian Blur**: Uses the bundled lottie-web SVG renderer for layer effect
  `ty: 29`, including preview and frame export

## Getting Started

### Prerequisites
- Xcode 16.4 or later
- iOS 17.5 or later
- Swift 5.0

### Installation
1. Open `Flippie.xcodeproj` in Xcode
2. Xcode will resolve the local `Vendor/LottieVersions` package
3. Build and run the project

### Project Structure
```
Flippie/
├── Flippie/
│   ├── Views/
│   │   ├── AnimationPlayerView.swift    # Player tab with controls
│   │   └── AnimationEditorView.swift    # Editor tab with properties
│   ├── Extensions/
│   │   └── FileManager+Extensions.swift # File handling utilities
│   ├── FlippieApp.swift           # App entry point
│   ├── ContentView.swift               # Main tab view
│   └── Assets.xcassets/                # App icons and colors
└── SampleAnimations/                   # Example Lottie files
```

## Usage

### Loading Animations
1. Tap "Import" in the navigation bar
2. Select a Lottie JSON file from your device
3. The animation will load in both Player and Editor tabs

### Player Tab
- Use playback controls to play/pause animations
- Adjust speed with the speed slider
- Change loop mode with the segmented control
- Scrub through timeline with progress slider
- Export animations using the "Export" button

### Editor Tab
- Select layers from the layer list
- Modify colors by tapping color circles
- Adjust transform properties when a layer is selected
- Apply changes with the "Apply" button

## Dependencies

- **Lottie iOS**: Animation rendering and playback
  - GitHub: https://github.com/airbnb/lottie-ios
  - Comparison versions: exactly 3.0.0, 3.5.0, 4.0.0, and 4.6.1
- **lottie-web 5.13.0**: SVG fallback for Gaussian Blur
  - GitHub: https://github.com/airbnb/lottie-web

## Building and Testing

### Debug Build
```bash
# Open in Xcode and build for simulator
# or build from command line:
xcodebuild -project Flippie.xcodeproj -scheme Flippie -destination 'platform=iOS Simulator,name=iPhone 15' build
```

### Device Testing
1. Connect your iOS device
2. Select your device in Xcode's destination picker
3. Ensure proper code signing is configured
4. Build and run

## Supported File Formats

### Import
- **Lottie JSON**: Standard Lottie animation files (.json)

### Export
- **JSON**: Modified Lottie animation data
- **GIF**: Experimental rendered animation export

## Technical Notes

### Architecture
- **SwiftUI** for the application interface
- Four namespaced Lottie iOS modules plus isolated CI matrix builds
- **AnimationDocument** as the shared source of truth for original JSON,
  metadata, edits, diagnostics, preview data, and export data

### Performance Considerations
- Animations are loaded asynchronously
- Memory management for large animation files
- Efficient rendering with Lottie's native iOS implementation

### Known Limitations
- GIF export is experimental and currently optimized only for small animations
- Complex layer editing is simplified for demonstration
- Some advanced Lottie features may not be fully editable

See [DEVELOPMENT.md](DEVELOPMENT.md) for local setup, tests, and CI details.

## Contributing

1. Fork the repository
2. Create a feature branch
3. Make your changes
4. Test thoroughly on device and simulator
5. Submit a pull request

## License

Flippie is available under the MIT License. Lottie iOS is subject to its
own license terms.
