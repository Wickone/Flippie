import SwiftUI

struct EditPropertiesSheet: View {
    @ObservedObject var document: AnimationDocument
    @Binding var animationSpeed: Double
    @Binding var totalFrames: Double
    let onDocumentChanged: () throws -> Void
    
    @StateObject private var analyzer = LottieAnalyzer()
    @Environment(\.dismiss) private var dismiss
    
    // Edit states
    @State private var tempSpeed: Double = 1.0
    @State private var tempFrames: Double = 100
    @State private var backgroundColor: Color = .clear
    @State private var hasBackgroundColor = false
    @State private var hasChanges = false
    @State private var colorReplacements: [RGBAColor: RGBAColor] = [:]
    @State private var showingApplyError = false
    @State private var applyErrorMessage = ""
    
    var body: some View {
        NavigationView {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 24) {
                    documentSummary

                // Animation Info
                VStack(alignment: .leading, spacing: 12) {
                    Text("Animation Properties")
                        .font(.headline)
                        .fontWeight(.semibold)
                    
                    VStack(spacing: 16) {
                        // Speed Control
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("Speed")
                                    .font(.subheadline)
                                    .fontWeight(.medium)
                                Spacer()
                                Text("\(tempSpeed, specifier: "%.1f")x")
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                            }
                            
                            Slider(value: $tempSpeed, in: 0.1...3.0, step: 0.1)
                            .onChange(of: tempSpeed) { _, _ in
                                hasChanges = true
                            }
                        }
                        
                        // Frame Count (Read-only for now)
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("Total Frames")
                                    .font(.subheadline)
                                    .fontWeight(.medium)
                                Spacer()
                                Text("\(Int(tempFrames))")
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                            }
                            
                            Text("Frame count is read-only")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        }
                    }
                    .padding()
                    .background(Color(UIColor.systemGray6))
                    .cornerRadius(12)
                }
                
                // Background Color
                VStack(alignment: .leading, spacing: 12) {
                    Text("Background")
                        .font(.headline)
                        .fontWeight(.semibold)
                    
                    VStack(spacing: 12) {
                        HStack {
                            RoundedRectangle(cornerRadius: 8)
                                .fill(!hasBackgroundColor ?
                                      LinearGradient(colors: [.white, .gray.opacity(0.3)], startPoint: .topLeading, endPoint: .bottomTrailing) : 
                                      LinearGradient(colors: [backgroundColor], startPoint: .center, endPoint: .center))
                                .frame(width: 60, height: 40)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8)
                                        .stroke(Color.gray.opacity(0.3), lineWidth: 1)
                                )
                            
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Background Color")
                                    .font(.subheadline)
                                    .fontWeight(.medium)
                                Text(hasBackgroundColor ? colorToHex(backgroundColor) : "Transparent")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            
                            Spacer()
                            
                            ColorPicker("", selection: $backgroundColor)
                                .labelsHidden()
                                .onChange(of: backgroundColor) { _, _ in
                                    hasBackgroundColor = true
                                    hasChanges = true
                                }
                        }
                        
                        Button("Reset to Transparent") {
                            hasBackgroundColor = false
                            hasChanges = true
                        }
                        .font(.caption)
                        .foregroundColor(.blue)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding()
                    .background(Color(UIColor.systemGray6))
                    .cornerRadius(12)
                }
                
                let colorsToShow = editorColors

                if !colorsToShow.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Animation Colors")
                            .font(.headline)
                            .fontWeight(.semibold)
                            
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Editable \(colorsToShow.count) unique colors from \(detectedColorPropertyCount) color occurrences")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                Text("Identical colors are grouped; precomps and keyframes are included")
                                    .font(.caption2)
                                    .foregroundColor(.blue)
                            }
                            
                            VStack(spacing: 12) {
                                ForEach(Array(colorsToShow.enumerated()), id: \.element) { index, color in
                                    let displayColor = colorReplacements[color] ?? color
                                    let hasReplacement = colorReplacements[color] != nil
                                    
                                    HStack {
                                        RoundedRectangle(cornerRadius: 8)
                                            .fill(displayColor.swiftUIColor)
                                            .frame(width: 60, height: 40)
                                            .overlay(
                                                RoundedRectangle(cornerRadius: 8)
                                                    .stroke(hasReplacement ? Color.orange.opacity(0.5) : Color.gray.opacity(0.3), lineWidth: 1)
                                            )
                                        
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text("Animation Color \(index + 1)")
                                                .font(.subheadline)
                                                .fontWeight(.medium)
                                            Text(colorToHex(displayColor.swiftUIColor))
                                                .font(.caption)
                                                .foregroundColor(.secondary)
                                            
                                            if hasReplacement {
                                                Text("Modified")
                                                    .font(.caption2)
                                                    .foregroundColor(.orange)
                                                    .fontWeight(.medium)
                                            }
                                        }
                                        
                                        Spacer()
                                        
                                        ColorPicker("", selection: Binding(
                                            get: { displayColor.swiftUIColor },
                                            set: { newColor in
                                                colorReplacements[color] = RGBAColor(newColor)
                                                hasChanges = true
                                            }
                                        ))
                                        .labelsHidden()
                                    }
                                }
                            }
                            .padding()
                            .background(Color(UIColor.systemGray6))
                            .cornerRadius(12)
                        }
                    } else {
                        Text("No editable fill or stroke colors were found.")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    
                    
                    // Properties List (Read-only for now)
                    if !analyzer.detectedProperties.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Detected Properties")
                                .font(.headline)
                                .fontWeight(.semibold)
                            
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Found \(analyzer.detectedProperties.count) detected properties")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                Text("\(detectedColorPropertyCount) color occurrences · \(detectedStrokeWidthPropertyCount) stroke widths")
                                    .font(.caption2)
                                    .foregroundColor(.blue)
                            }
                            
                            VStack(spacing: 8) {
                                ForEach(analyzer.detectedProperties.prefix(5)) { property in
                                    HStack {
                                        Image(systemName: iconForPropertyType(property.type))
                                            .foregroundColor(colorForPropertyType(property.type))
                                            .frame(width: 20)
                                        
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(property.name)
                                                .font(.subheadline)
                                            Text(property.keyPath)
                                                .font(.caption2)
                                                .foregroundColor(.secondary)
                                        }
                                        
                                        Spacer()
                                        
                                        switch property.currentValue {
                                        case .color(let color):
                                            Circle()
                                                .fill(color)
                                                .frame(width: 20, height: 20)
                                        case .width(let width):
                                            Text("\(width, specifier: "%.1f")")
                                                .font(.caption)
                                                .foregroundColor(.secondary)
                                        }
                                    }
                                    .padding(.vertical, 4)
                                    
                                    if property.id != analyzer.detectedProperties.prefix(5).last?.id {
                                        Divider()
                                    }
                                }
                                
                                if analyzer.detectedProperties.count > 5 {
                                    Text("+ \(analyzer.detectedProperties.count - 5) more properties")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                        .padding(.top, 4)
                                }
                            }
                            .padding()
                            .background(Color(UIColor.systemGray6))
                            .cornerRadius(12)
                        }
                    }
                    
                    
                    
                    Spacer(minLength: 100)
                }
                .padding()
            }
            .navigationTitle("Edit Properties")
            .navigationBarTitleDisplayMode(.inline)
            .navigationBarItems(
                leading: Button("Cancel") { dismiss() },
                trailing: Button("Apply") {
                    applyChanges()
                }
                .disabled(!hasChanges)
            )
        }
        .onAppear {
            loadInitialValues()
            analyzeAnimation()
        }
        .alert("Could Not Apply Changes", isPresented: $showingApplyError) {
            Button("OK") {}
        } message: {
            Text(applyErrorMessage)
        }
    }

    private var documentSummary: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(document.displayName)
                .font(.headline)

            if let metadata = document.metadata {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                    GridRow {
                        Text("Lottie version")
                        Text(metadata.formatVersion ?? "Unknown")
                    }
                    GridRow {
                        Text("Canvas")
                        Text("\(metadata.width) × \(metadata.height)")
                    }
                    GridRow {
                        Text("Timeline")
                        Text("\(Int(metadata.frameCount)) frames · \(metadata.frameRate, specifier: "%.0f") fps")
                    }
                    GridRow {
                        Text("Duration")
                        Text("\(metadata.duration, specifier: "%.2f") s")
                    }
                    GridRow {
                        Text("Contents")
                        Text("\(metadata.layerCount) root / \(metadata.features.totalLayerCount) total layers")
                    }
                    GridRow {
                        Text("Assets")
                        Text(metadata.features.assetSummary)
                    }
                    GridRow {
                        Text("Features")
                        Text(metadata.features.advancedSummary)
                    }
                    GridRow {
                        Text("Animated props")
                        Text("\(metadata.features.keyframedPropertyCount) keyframed · \(metadata.features.expressionCount) expressions")
                    }
                }
                .font(.subheadline)
            }

            ForEach(document.diagnostics) { diagnostic in
                Label(diagnostic.message, systemImage: diagnosticIcon(diagnostic.severity))
                    .font(.caption)
                    .foregroundColor(diagnosticColor(diagnostic.severity))
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(UIColor.systemGray6))
        .cornerRadius(12)
    }

    private func diagnosticIcon(_ severity: AnimationDiagnostic.Severity) -> String {
        switch severity {
        case .info:
            return "info.circle"
        case .warning:
            return "exclamationmark.triangle"
        case .error:
            return "xmark.octagon"
        }
    }

    private func diagnosticColor(_ severity: AnimationDiagnostic.Severity) -> Color {
        switch severity {
        case .info:
            return .secondary
        case .warning:
            return .orange
        case .error:
            return .red
        }
    }
    
    private func loadInitialValues() {
        tempSpeed = document.edits.playbackSpeed
        tempFrames = document.metadata?.frameCount ?? totalFrames
        backgroundColor = document.edits.backgroundColor?.swiftUIColor ?? .clear
        hasBackgroundColor = document.edits.backgroundColor != nil
        colorReplacements = document.edits.colorReplacements
        hasChanges = false
    }
    
    private func analyzeAnimation() {
        guard let data = document.originalData else {
            print("🔍 EditPropertiesSheet: No document data available for analysis")
            return 
        }

        analyzer.analyzeAnimation(data: data)
    }
    
    private func applyChanges() {
        let previousEdits = document.edits
        let newEdits = AnimationEdits(
            colorReplacements: colorReplacements,
            backgroundColor: hasBackgroundColor ? RGBAColor(backgroundColor) : nil,
            playbackSpeed: tempSpeed
        )

        do {
            try document.apply(newEdits)
            try onDocumentChanged()
            animationSpeed = tempSpeed
            totalFrames = tempFrames
            hasChanges = false
            dismiss()
        } catch {
            try? document.apply(previousEdits)
            try? onDocumentChanged()
            applyErrorMessage = error.localizedDescription
            showingApplyError = true
        }
    }

    private var editorColors: [RGBAColor] {
        let analyzed = analyzer.colorPalette.map(RGBAColor.init)
        return (analyzed + Array(colorReplacements.keys)).reduce(into: []) { result, color in
            if !result.contains(where: { $0.isApproximatelyEqual(to: color.components) }) {
                result.append(color)
            }
        }
    }

    private var detectedColorPropertyCount: Int {
        analyzer.detectedProperties.filter {
            switch $0.type {
            case .fillColor, .strokeColor:
                return true
            case .strokeWidth:
                return false
            }
        }.count
    }

    private var detectedStrokeWidthPropertyCount: Int {
        analyzer.detectedProperties.filter {
            if case .strokeWidth = $0.type {
                return true
            }
            return false
        }.count
    }
    
    private func iconForPropertyType(_ type: LottieProperty.PropertyType) -> String {
        switch type {
        case .fillColor:
            return "paintbrush.fill"
        case .strokeColor:
            return "pencil"
        case .strokeWidth:
            return "line.3.horizontal"
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
