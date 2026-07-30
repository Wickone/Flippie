import SwiftUI
import Lottie

struct AnimationEditorView: View {
    @Binding var animationURL: URL?
    @State private var animationView: LottieAnimationView?
    @StateObject private var analyzer = LottieAnalyzer()
    @State private var selectedProperty: LottieProperty?
    @State private var selectedColor: Color = .red
    @State private var selectedStrokeWidth: Double = 2.0
    @State private var showingColorPicker = false
    @State private var backgroundColorFilter: Color = .clear
    @State private var updateTimer: Timer?
    @State private var isUpdating = false
    
    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                // Fixed Animation Preview (Non-scrollable)
                VStack {
                    Group {
                        if let animationView = animationView {
                            LottieView(animationView: animationView)
                                .frame(maxWidth: .infinity, maxHeight: 200)
                                .background(backgroundColorFilter == .clear ? Color.gray.opacity(0.1) : backgroundColorFilter)
                                .cornerRadius(12)
                        } else {
                            RoundedRectangle(cornerRadius: 12)
                                .fill(Color.gray.opacity(0.1))
                                .frame(height: 200)
                                .overlay(
                                    VStack {
                                        Image(systemName: "paintpalette")
                                            .font(.largeTitle)
                                            .foregroundColor(.gray)
                                        Text("No animation loaded")
                                            .foregroundColor(.gray)
                                    }
                                )
                        }
                    }
                    .padding(.horizontal)
                }
                .frame(height: 220)
                .background(Color(UIColor.systemGray6))
                
                // Scrollable Properties Panel
                ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 20) {
                    
                    // Edit Palette Header
                    HStack {
                        VStack(alignment: .leading) {
                            Text("Редактировать палитру")
                                .font(.headline)
                                .fontWeight(.medium)
                            if !analyzer.detectedProperties.isEmpty {
                                Text("\(analyzer.detectedProperties.count) свойств обнаружено")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                        
                        Spacer()
                        
                        Button("BETA") {
                            // Beta info
                        }
                        .font(.caption)
                        .fontWeight(.bold)
                        .foregroundColor(.orange)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.orange.opacity(0.1))
                        .cornerRadius(4)
                        
                        Button("удалить") {
                            resetColors()
                        }
                        .font(.caption)
                        .foregroundColor(.red)
                    }
                    .padding(.horizontal)
                    
                    // Background Color
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            RoundedRectangle(cornerRadius: 6)
                                .fill(backgroundColorFilter == .clear ? Color.gray.opacity(0.3) : backgroundColorFilter)
                                .frame(width: 30, height: 30)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6)
                                        .stroke(Color.gray.opacity(0.3), lineWidth: 1)
                                )
                                .onTapGesture {
                                    showBackgroundColorPicker()
                                }
                            
                            Text(backgroundColorFilter == .clear ? "#CLEAR" : colorToHex(backgroundColorFilter))
                                .font(.system(.body, design: .monospaced))
                                .foregroundColor(.secondary)
                            
                            Spacer()
                            
                            Button(action: { backgroundColorFilter = .clear }) {
                                Image(systemName: "xmark")
                                    .font(.caption)
                                    .foregroundColor(.gray)
                            }
                        }
                        .padding(.horizontal)
                    }
                    
                    // Detected Colors Palette
                    if !analyzer.colorPalette.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Text("Цвета анимации")
                                    .font(.subheadline)
                                    .fontWeight(.medium)
                                Spacer()
                                Text("\(analyzer.colorPalette.count)")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            .padding(.horizontal)
                            
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 12) {
                                    ForEach(Array(analyzer.colorPalette.enumerated()), id: \.offset) { index, color in
                                        VStack(spacing: 4) {
                                            RoundedRectangle(cornerRadius: 8)
                                                .fill(color)
                                                .frame(width: 50, height: 50)
                                                .overlay(
                                                    RoundedRectangle(cornerRadius: 8)
                                                        .stroke(selectedColor == color ? Color.blue : Color.gray.opacity(0.3), lineWidth: selectedColor == color ? 2 : 1)
                                                )
                                                .onTapGesture {
                                                    selectedColor = color
                                                    showColorPicker()
                                                }
                                            
                                            Text(colorToHex(color))
                                                .font(.system(.caption2, design: .monospaced))
                                                .foregroundColor(.secondary)
                                        }
                                    }
                                    
                                    // Add color button
                                    Button(action: addNewColor) {
                                        RoundedRectangle(cornerRadius: 8)
                                            .fill(Color.black)
                                            .frame(width: 50, height: 50)
                                            .overlay(
                                                Image(systemName: "plus")
                                                    .foregroundColor(.white)
                                                    .font(.title2)
                                            )
                                    }
                                }
                                .padding(.horizontal)
                            }
                        }
                    }
                    
                    // Detected Properties
                    if !analyzer.detectedProperties.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Text("Обнаруженные свойства")
                                    .font(.subheadline)
                                    .fontWeight(.medium)
                                Spacer()
                                Text("⚠️ Редактирование временно отключено")
                                    .font(.caption)
                                    .foregroundColor(.orange)
                            }
                            .padding(.horizontal)
                            
                            LazyVStack(spacing: 8) {
                                ForEach(analyzer.detectedProperties) { property in
                                    PropertyRowView(
                                        property: property,
                                        isSelected: selectedProperty?.id == property.id,
                                        onTap: { selectProperty(property) },
                                        onColorChange: { color in 
                                            print("Color change disabled for property: \(property.name)")
                                        },
                                        onWidthChange: { width in 
                                            print("Width change disabled for property: \(property.name)")
                                        }
                                    )
                                }
                            }
                            .padding(.horizontal)
                        }
                    }
                    
                    // Color Tools
                    VStack(alignment: .leading, spacing: 16) {
                        Text("Инструменты цвета")
                            .font(.subheadline)
                            .fontWeight(.medium)
                            .padding(.horizontal)
                        
                        // Gradient color bar
                        ZStack {
                            LinearGradient(
                                gradient: Gradient(colors: [
                                    .red, .orange, .yellow, .green, .cyan, .blue, .purple, .pink, .red
                                ]),
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                            .frame(height: 30)
                            .cornerRadius(15)
                            .overlay(
                                RoundedRectangle(cornerRadius: 15)
                                    .stroke(Color.gray.opacity(0.3), lineWidth: 1)
                            )
                            .onTapGesture { location in
                                // Handle gradient tap to select color
                                handleGradientTap(location)
                            }
                        }
                        .padding(.horizontal)
                        
                        // Brightness slider
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Яркость")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .padding(.horizontal)
                            
                            ZStack {
                                LinearGradient(
                                    gradient: Gradient(colors: [.black, selectedColor.opacity(0.5), selectedColor, .white]),
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                                .frame(height: 30)
                                .cornerRadius(15)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 15)
                                        .stroke(Color.gray.opacity(0.3), lineWidth: 1)
                                )
                            }
                            .padding(.horizontal)
                        }
                    }
                    
                    // Save Palette Button
                    Button(action: savePalette) {
                        HStack {
                            Spacer()
                            Text("Сохранить палитру")
                                .font(.headline)
                                .foregroundColor(.white)
                            Spacer()
                        }
                        .padding()
                        .background(Color.green)
                        .cornerRadius(12)
                    }
                    .padding(.horizontal)
                    .padding(.bottom, 150) // Extra padding for tab bar and scroll room
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 20)
                }
            }
        }
        .onChange(of: animationURL) { newURL in
            loadAnimation(from: newURL)
        }
        .onAppear {
            if let url = animationURL {
                loadAnimation(from: url)
            }
        }
        .onDisappear {
            updateTimer?.invalidate()
            updateTimer = nil
        }
        .sheet(isPresented: $showingColorPicker) {
            ColorPickerView(selectedColor: $selectedColor, onColorSelected: { color in
                applySelectedColor(color)
            })
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
    }
    
    private func loadAnimation(from url: URL?) {
        guard let url = url else { return }
        
        // Create animation view
        if url.startAccessingSecurityScopedResource() {
            defer { url.stopAccessingSecurityScopedResource() }
            
            do {
                let data = try Data(contentsOf: url)
                let animation = try LottieAnimation.from(data: data)
                
                let newAnimationView = LottieAnimationView(animation: animation)
                newAnimationView.loopMode = .loop
                newAnimationView.animationSpeed = 1.0
                newAnimationView.play()
                
                DispatchQueue.main.async {
                    self.animationView = newAnimationView
                    // Analyze the animation
                    self.analyzer.analyzeAnimation(data: data)
                }
            } catch {
                print("Error loading animation: \(error)")
            }
        }
    }
    
    private func selectProperty(_ property: LottieProperty) {
        selectedProperty = property
        
        switch property.currentValue {
        case .color(let color):
            selectedColor = color
        case .width(let width):
            selectedStrokeWidth = width
        }
    }
    
    private func updatePropertyColor(_ property: LottieProperty, color: Color) {
        // Disable color updates temporarily to prevent crashes
        print("Color update requested for: \(property.name) - Feature temporarily disabled for stability")
        // TODO: Re-enable after implementing safer Lottie keypath handling
    }
    
    private func updatePropertyWidth(_ property: LottieProperty, width: Double) {
        // Disable width updates temporarily to prevent crashes
        print("Width update requested for: \(property.name) - Feature temporarily disabled for stability")
        // TODO: Re-enable after implementing safer Lottie keypath handling
    }
    
    private func generateKeypaths(for property: LottieProperty) -> [String] {
        var keypaths: [String] = []
        
        // Add the original keypath first
        keypaths.append(property.keyPath)
        
        // Generate common variations based on property type
        let basePath = property.keyPath.replacingOccurrences(of: ".Fill Color", with: "")
                                      .replacingOccurrences(of: ".Stroke Color", with: "")
                                      .replacingOccurrences(of: ".Stroke Width", with: "")
        
        switch property.type {
        case .fillColor:
            keypaths.append(contentsOf: [
                "\(basePath).**.Fill",
                "\(basePath).**.Fill Color",
                "\(basePath).**.Fill 1.Color",
                "\(basePath).Fill.Color",
                "**.Fill.Color",
                "**.Fill Color"
            ])
            
        case .strokeColor:
            keypaths.append(contentsOf: [
                "\(basePath).**.Stroke",
                "\(basePath).**.Stroke Color",
                "\(basePath).**.Stroke 1.Color",
                "\(basePath).Stroke.Color",
                "**.Stroke.Color",
                "**.Stroke Color"
            ])
            
        case .strokeWidth:
            keypaths.append(contentsOf: [
                "\(basePath).**.Stroke Width",
                "\(basePath).**.Stroke 1.Stroke Width",
                "\(basePath).Stroke.Stroke Width",
                "**.Stroke.Stroke Width",
                "**.Stroke Width"
            ])
        }
        
        return keypaths
    }
    
    private func showBackgroundColorPicker() {
        selectedColor = backgroundColorFilter == .clear ? .white : backgroundColorFilter
        showingColorPicker = true
    }
    
    private func showColorPicker() {
        showingColorPicker = true
    }
    
    private func applySelectedColor(_ color: Color) {
        // Only apply background color changes for now (safer)
        backgroundColorFilter = color
        
        if let property = selectedProperty {
            print("Property color change disabled for stability. Property: \(property.name)")
        }
    }
    
    private func addNewColor() {
        // Add a new color to the palette
        selectedColor = .blue
        showingColorPicker = true
    }
    
    private func resetColors() {
        backgroundColorFilter = .clear
        selectedProperty = nil
        // Only reset background color for now
        print("Reset applied - only background color reset for stability")
    }
    
    private func savePalette() {
        // Implement palette saving functionality
        print("Saving palette...")
    }
    
    private func handleGradientTap(_ location: CGPoint) {
        // Convert tap location to color selection
        // This is simplified - a real implementation would calculate the exact color
        let colors: [Color] = [.red, .orange, .yellow, .green, .cyan, .blue, .purple, .pink]
        let index = min(Int(location.x / 50), colors.count - 1)
        selectedColor = colors[max(0, index)]
    }
    
    private func colorToHex(_ color: Color) -> String {
        let uiColor = UIColor(color)
        guard let components = uiColor.cgColor.components, components.count >= 3 else {
            return "#000000"
        }
        
        let r = Int(components[0] * 255)
        let g = Int(components[1] * 255)
        let b = Int(components[2] * 255)
        
        return String(format: "#%02X%02X%02X", r, g, b)
    }
}

struct PropertyRowView: View {
    let property: LottieProperty
    let isSelected: Bool
    let onTap: () -> Void
    let onColorChange: (Color) -> Void
    let onWidthChange: (Double) -> Void
    
    @State private var currentColor: Color = .blue
    @State private var currentWidth: Double = 2.0
    
    var body: some View {
        HStack {
            // Property type icon
            Image(systemName: iconForPropertyType(property.type))
                .font(.title2)
                .foregroundColor(colorForPropertyType(property.type))
                .frame(width: 30)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(property.name)
                    .font(.system(.body, design: .default))
                    .lineLimit(1)
                
                Text(property.keyPath)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            
            Spacer()
            
            // Property value controls
            switch property.currentValue {
            case .color(let color):
                ColorButton(color: color) { newColor in
                    currentColor = newColor
                    onColorChange(newColor)
                }
                
            case .width(let width):
                HStack {
                    Text(String(format: "%.1f", width))
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    Slider(value: $currentWidth, in: 0.5...10.0, step: 0.5)
                        .frame(width: 80)
                        .onChange(of: currentWidth) { newWidth in
                            onWidthChange(newWidth)
                        }
                }
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .background(isSelected ? Color.blue.opacity(0.1) : Color.clear)
        .cornerRadius(8)
        .onTapGesture {
            onTap()
        }
        .onAppear {
            switch property.currentValue {
            case .color(let color):
                currentColor = color
            case .width(let width):
                currentWidth = width
            }
        }
    }
    
    private func iconForPropertyType(_ type: LottieProperty.PropertyType) -> String {
        switch type {
        case .fillColor:
            return "paintbucket.fill"
        case .strokeColor:
            return "pencil"
        case .strokeWidth:
            return "lineweight"
        }
    }
    
    private func colorForPropertyType(_ type: LottieProperty.PropertyType) -> Color {
        switch type {
        case .fillColor:
            return .blue
        case .strokeColor:
            return .orange
        case .strokeWidth:
            return .purple
        }
    }
}

struct ColorButton: View {
    let color: Color
    let onColorChange: (Color) -> Void
    
    @State private var showingPicker = false
    @State private var selectedColor: Color
    
    init(color: Color, onColorChange: @escaping (Color) -> Void) {
        self.color = color
        self.onColorChange = onColorChange
        self._selectedColor = State(initialValue: color)
    }
    
    var body: some View {
        Button(action: { showingPicker = true }) {
            RoundedRectangle(cornerRadius: 6)
                .fill(color)
                .frame(width: 30, height: 30)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.gray.opacity(0.3), lineWidth: 1)
                )
        }
        .sheet(isPresented: $showingPicker) {
            ColorPickerView(selectedColor: $selectedColor) { newColor in
                onColorChange(newColor)
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
    }
}

struct ColorPickerView: View {
    @Binding var selectedColor: Color
    let onColorSelected: (Color) -> Void
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        NavigationView {
            VStack {
                ColorPicker("Выберите цвет", selection: $selectedColor)
                    .padding()
                
                Spacer()
                
                Button("Применить") {
                    onColorSelected(selectedColor)
                    dismiss()
                }
                .font(.headline)
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding()
                .background(Color.blue)
                .cornerRadius(12)
                .padding()
            }
            .navigationTitle("Цвет")
            .navigationBarTitleDisplayMode(.inline)
            .navigationBarItems(
                leading: Button("Отмена") { dismiss() }
            )
        }
    }
}
