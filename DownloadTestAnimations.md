# Popular Lottie Test Animations

## Free Sources:
1. **LottieFiles.com** - Largest collection
   - Search: "loading", "heart", "check", "hamburger menu"
   - Download as JSON

2. **GitHub Repositories:**
   - [Lottie React Native Examples](https://github.com/lottie-react-native/lottie-react-native/tree/master/example/src/animations)
   - [Airbnb Lottie Samples](https://github.com/airbnb/lottie-web/tree/master/demo/examples)

## Common Test Categories:
- **Loading Spinners**: circular, dots, bars
- **Icons**: heart, star, check, close
- **Menu Animations**: hamburger to X
- **Progress Bars**: linear, circular
- **Micro Interactions**: button press, toggle

## Quick Downloads:
```bash
# From your project directory:
cd /Users/Wickone/Desktop/Flippie/Flippie/Preview\ Content/

# Download some popular animations (examples):
curl -o loading-dots.json "https://assets1.lottiefiles.com/packages/lf20_a2chheio.json"
curl -o heart-like.json "https://assets3.lottiefiles.com/packages/lf20_zypnmm9z.json"
curl -o checkmark.json "https://assets9.lottiefiles.com/packages/lf20_jcikwtux.json"
```

Then add to BundledAnimationsView.swift:
```swift
let bundledAnimations = [
    "note_outline_music_sa_outline_to_fill_28",
    "loading-dots",
    "heart-like", 
    "checkmark"
]
```