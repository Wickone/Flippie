import SwiftUI
import Lottie

struct AnimationPlayerView: View {
    @Binding var animationURL: URL?
    @State private var animationView: LottieAnimationView?
    @State private var isPlaying = false
    @State private var currentProgress: Double = 0
    @State private var animationSpeed: Double = 1.0
    @State private var loopMode: LottieLoopMode = .loop
    @State private var currentFrame: Int = 0
    @State private var totalFrames: Int = 60
    @State private var wasPlayingBeforeScrub = false
    @State private var isUserScrubbing = false
    @State private var progressTimer: Timer?
    
    var body: some View {
        VStack(spacing: 20) {
            // Animation Display
                Group {
                    if let animationView = animationView {
                        LottieView(animationView: animationView)
                            .frame(maxWidth: .infinity, maxHeight: 400)
                            .background(Color.gray.opacity(0.1))
                            .cornerRadius(12)
                    } else {
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color.gray.opacity(0.1))
                            .frame(height: 400)
                            .overlay(
                                VStack {
                                    Image(systemName: "play.rectangle")
                                        .font(.largeTitle)
                                        .foregroundColor(.gray)
                                    Text("No animation loaded")
                                        .foregroundColor(.gray)
                                }
                            )
                    }
                }
                .padding(.horizontal)
                
                // Controls
                VStack(spacing: 16) {
                    // Progress Slider
                    if animationView != nil {
                        VStack(spacing: 4) {
                            HStack {
                                Text("Progress")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                Spacer()
                                Text("\(currentFrame)/\(totalFrames)")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .monospacedDigit()
                            }
                            Slider(value: $currentProgress, in: 0...1) { editing in
                                isUserScrubbing = editing
                                if editing {
                                    // User started scrubbing
                                    wasPlayingBeforeScrub = isPlaying
                                    if isPlaying {
                                        animationView?.pause()
                                        isPlaying = false
                                    }
                                } else {
                                    // User finished scrubbing
                                    animationView?.currentProgress = currentProgress
                                    updateFrameCounter()
                                    if wasPlayingBeforeScrub {
                                        animationView?.play { _ in
                                            self.isPlaying = false
                                        }
                                        isPlaying = true
                                    }
                                }
                            }
                            .onChange(of: currentProgress) { _, newValue in
                                // Only update during user scrubbing, not during automatic playback
                                if isUserScrubbing {
                                    animationView?.currentProgress = newValue
                                    updateFrameCounter()
                                }
                            }
                            .disabled(animationView == nil)
                        }
                    }
                    
                    // Playback Controls
                    HStack(spacing: 40) {
                        Button(action: stepBackward) {
                            Image(systemName: "backward.fill")
                                .font(.title2)
                        }
                        .disabled(animationView == nil)
                        
                        Button(action: rewind) {
                            Image(systemName: "backward.end.fill")
                                .font(.title2)
                        }
                        .disabled(animationView == nil)
                        
                        Button(action: togglePlayback) {
                            Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                                .font(.largeTitle)
                        }
                        .disabled(animationView == nil)
                        
                        Button(action: fastForward) {
                            Image(systemName: "forward.end.fill")
                                .font(.title2)
                        }
                        .disabled(animationView == nil)
                        
                        Button(action: stepForward) {
                            Image(systemName: "forward.fill")
                                .font(.title2)
                        }
                        .disabled(animationView == nil)
                    }
                    
                    // Speed Control
                    VStack {
                        Text("Speed: \(animationSpeed, specifier: "%.1f")x")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Slider(value: $animationSpeed, in: 0.1...3.0) { _ in
                            animationView?.animationSpeed = animationSpeed
                        }
                        .disabled(animationView == nil)
                    }
                    
                    // Loop Mode
                    Picker("Loop Mode", selection: $loopMode) {
                        Text("Play Once").tag(LottieLoopMode.playOnce)
                        Text("Loop").tag(LottieLoopMode.loop)
                        Text("Auto Reverse").tag(LottieLoopMode.autoReverse)
                    }
                    .pickerStyle(SegmentedPickerStyle())
                    .onChange(of: loopMode) { _, newMode in
                        animationView?.loopMode = newMode
                    }
                    .disabled(animationView == nil)
                }
                .padding(.horizontal)
                
                Spacer()
            }
        .onChange(of: animationURL) { _, newURL in
            loadAnimation(from: newURL)
        }
        .onAppear {
            if let url = animationURL {
                loadAnimation(from: url)
            }
        }
        .onDisappear {
            stopProgressTimer()
        }
    }
    
    private func loadAnimation(from url: URL?) {
        guard let url = url else {
            animationView = nil
            return
        }
        
        print("Loading animation from: \(url.path)")
        
        do {
            // Check if file exists
            guard FileManager.default.fileExists(atPath: url.path) else {
                print("File does not exist at path: \(url.path)")
                return
            }
            
            let data = try Data(contentsOf: url)
            print("Loaded data size: \(data.count) bytes")
            
            // Try to parse as JSON first to validate
            _ = try JSONSerialization.jsonObject(with: data, options: [])
            print("Valid JSON structure detected")
            
            let animation = try LottieAnimation.from(data: data)
            print("Lottie animation created successfully")
            
            // Calculate total frames
            totalFrames = Int(animation.duration * animation.framerate)
            currentFrame = 0
            
            let newAnimationView = LottieAnimationView(animation: animation)
            newAnimationView.contentMode = .scaleAspectFit
            newAnimationView.loopMode = loopMode
            newAnimationView.animationSpeed = animationSpeed
            animationView = newAnimationView
            
            // Don't auto-start playing, just prepare the animation
            // User will click play button when ready
            isPlaying = false
            
            // Set up progress tracking timer
            startProgressTimer()
            
        } catch {
            print("Failed to load animation: \(error)")
            print("Error details: \(error.localizedDescription)")
        }
    }
    
    private func togglePlayback() {
        guard let animationView = animationView else { return }
        
        if isPlaying {
            // Pause the animation
            animationView.pause()
            isPlaying = false
        } else {
            // Resume or start playing from current position
            if animationView.currentProgress >= 1.0 {
                // If at end, restart from beginning
                animationView.currentProgress = 0
                currentProgress = 0
                updateFrameCounter()
            }
            
            animationView.play { completed in
                // Only set to false if animation completed naturally
                if completed {
                    self.isPlaying = false
                }
            }
            isPlaying = true
        }
    }
    
    private func rewind() {
        // Pause if playing
        if isPlaying {
            animationView?.pause()
            isPlaying = false
        }
        
        currentProgress = 0
        animationView?.currentProgress = 0
        updateFrameCounter()
    }
    
    private func fastForward() {
        // Pause if playing
        if isPlaying {
            animationView?.pause()
            isPlaying = false
        }
        
        currentProgress = 1
        animationView?.currentProgress = 1
        updateFrameCounter()
    }
    
    private func stepBackward() {
        // Pause if playing
        if isPlaying {
            animationView?.pause()
            isPlaying = false
        }
        
        // Calculate frame step
        let frameStep = 1.0 / Double(totalFrames)
        let newProgress = max(0, currentProgress - frameStep)
        
        currentProgress = newProgress
        animationView?.currentProgress = newProgress
        updateFrameCounter()
    }
    
    private func stepForward() {
        // Pause if playing
        if isPlaying {
            animationView?.pause()
            isPlaying = false
        }
        
        // Calculate frame step
        let frameStep = 1.0 / Double(totalFrames)
        let newProgress = min(1.0, currentProgress + frameStep)
        
        currentProgress = newProgress
        animationView?.currentProgress = newProgress
        updateFrameCounter()
    }
    
    private func updateFrameCounter() {
        currentFrame = Int(currentProgress * Double(totalFrames - 1)) + 1
        currentFrame = max(1, min(currentFrame, totalFrames)) // Ensure valid range
    }
    
    private func startProgressTimer() {
        progressTimer?.invalidate()
        progressTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
            if let view = self.animationView, !self.isUserScrubbing, self.isPlaying {
                self.currentProgress = view.currentProgress
                self.updateFrameCounter()
            }
        }
    }
    
    private func stopProgressTimer() {
        progressTimer?.invalidate()
        progressTimer = nil
    }
}



