import Foundation
import SwiftUI

struct LottieProperty: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let keyPath: String
    let type: PropertyType
    let currentValue: PropertyValue
    
    enum PropertyType: Hashable {
        case fillColor
        case strokeColor
        case strokeWidth
    }
    
    enum PropertyValue: Hashable {
        case color(Color)
        case width(Double)
        
        func hash(into hasher: inout Hasher) {
            switch self {
            case .color(let color):
                hasher.combine("color")
                hasher.combine(color)
            case .width(let width):
                hasher.combine("width")
                hasher.combine(width)
            }
        }
        
        static func == (lhs: PropertyValue, rhs: PropertyValue) -> Bool {
            switch (lhs, rhs) {
            case (.color(let color1), .color(let color2)):
                return color1 == color2
            case (.width(let width1), .width(let width2)):
                return width1 == width2
            default:
                return false
            }
        }
    }
}

@MainActor
final class LottieAnalyzer: ObservableObject {
    @Published var detectedProperties: [LottieProperty] = []
    @Published var colorPalette: [Color] = []
    
    func analyzeAnimation(data: Data) {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            detectedProperties = []
            colorPalette = []
            return
        }

        var properties: [LottieProperty] = []
        var ignoredColors: Set<Color> = []

        if let layers = json["layers"] as? [[String: Any]] {
            properties.append(contentsOf: parseLayers(
                layers,
                scopeName: "Main",
                colors: &ignoredColors
            ))
        }

        if let assets = json["assets"] as? [[String: Any]] {
            for (index, asset) in assets.enumerated() {
                guard let layers = asset["layers"] as? [[String: Any]] else { continue }
                let assetName = asset["id"] as? String
                    ?? asset["nm"] as? String
                    ?? "Precomp \(index + 1)"
                properties.append(contentsOf: parseLayers(
                    layers,
                    scopeName: assetName,
                    colors: &ignoredColors
                ))
            }
        }

        let colors = (try? AnimationDocument.discoveredColors(in: data)) ?? []
        detectedProperties = properties
        colorPalette = colors.map(\.swiftUIColor)
    }

    private func parseLayers(
        _ layers: [[String: Any]],
        scopeName: String,
        colors: inout Set<Color>
    ) -> [LottieProperty] {
        var properties: [LottieProperty] = []

        for (layerIndex, layer) in layers.enumerated() {
            let layerName = layer["nm"] as? String ?? "Layer \(layerIndex + 1)"
            if let shapes = layer["shapes"] as? [[String: Any]] {
                properties.append(contentsOf: parseShapes(
                    shapes,
                    layerName: "\(scopeName).\(layerName)",
                    colors: &colors
                ))
            }
        }

        return properties
    }
    
    private func parseShapes(_ shapes: [[String: Any]], layerName: String, colors: inout Set<Color>) -> [LottieProperty] {
        var properties: [LottieProperty] = []
        
        for (shapeIndex, shape) in shapes.enumerated() {
            let shapeName = shape["nm"] as? String ?? "Shape \(shapeIndex)"
            let shapeType = shape["ty"] as? String ?? ""
            
            switch shapeType {
            case "fl": // Fill
                if let fillColor = extractColor(from: shape["c"]) {
                    colors.insert(fillColor)
                    let fillName = shape["nm"] as? String ?? "Fill"
                    properties.append(LottieProperty(
                        name: "\(layerName) - \(fillName)",
                        keyPath: "**.Fill.Color",
                        type: .fillColor,
                        currentValue: .color(fillColor)
                    ))
                }
                
            case "st": // Stroke
                if let strokeColor = extractColor(from: shape["c"]) {
                    colors.insert(strokeColor)
                    let strokeName = shape["nm"] as? String ?? "Stroke"
                    properties.append(LottieProperty(
                        name: "\(layerName) - \(strokeName) Color",
                        keyPath: "**.Stroke.Color",
                        type: .strokeColor,
                        currentValue: .color(strokeColor)
                    ))
                }
                
                if let strokeWidth = extractStrokeWidth(from: shape["w"]) {
                    let strokeName = shape["nm"] as? String ?? "Stroke"
                    properties.append(LottieProperty(
                        name: "\(layerName) - \(strokeName) Width",
                        keyPath: "**.Stroke.Stroke Width",
                        type: .strokeWidth,
                        currentValue: .width(strokeWidth)
                    ))
                }
                
            case "gr": // Group
                if let groupItems = shape["it"] as? [[String: Any]] {
                    let nestedProperties = parseShapes(groupItems, layerName: "\(layerName).\(shapeName)", colors: &colors)
                    properties.append(contentsOf: nestedProperties)
                }
                
            default:
                if let items = shape["it"] as? [[String: Any]] {
                    let nestedProperties = parseShapes(items, layerName: "\(layerName).\(shapeName)", colors: &colors)
                    properties.append(contentsOf: nestedProperties)
                }
            }
        }
        return properties
    }
    
    private func extractColor(from colorData: Any?) -> Color? {
        guard let colorInfo = colorData as? [String: Any] else { return nil }
        
        // Handle both animated and static colors
        if let colorArray = colorInfo["k"] as? [Double], colorArray.count >= 3 {
            let color = Color(
                red: colorArray[0],
                green: colorArray[1],
                blue: colorArray[2],
                opacity: colorArray.count > 3 ? colorArray[3] : 1.0
            )
            return color
        }
        
        // Handle animated colors (take first keyframe)
        if let keyframes = colorInfo["k"] as? [[String: Any]],
           let firstFrame = keyframes.first,
           let startValue = firstFrame["s"] as? [Double],
           startValue.count >= 3 {
            let color = Color(
                red: startValue[0],
                green: startValue[1],
                blue: startValue[2],
                opacity: startValue.count > 3 ? startValue[3] : 1.0
            )
            return color
        }
        return nil
    }
    
    private func extractStrokeWidth(from widthData: Any?) -> Double? {
        guard let widthInfo = widthData as? [String: Any] else { return nil }
        
        // Handle static width
        if let width = widthInfo["k"] as? Double {
            return width
        }
        
        // Handle animated width (take first keyframe)
        if let keyframes = widthInfo["k"] as? [[String: Any]],
           let firstFrame = keyframes.first,
           let startValue = firstFrame["s"] as? [Double],
           let width = startValue.first {
            return width
        }
        
        return nil
    }
}
