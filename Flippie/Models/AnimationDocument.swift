import Foundation
import SwiftUI

struct RGBAColor: Hashable, Codable {
    let red: Double
    let green: Double
    let blue: Double
    let alpha: Double

    init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    init(_ color: Color) {
        let uiColor = UIColor(color)
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        uiColor.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        self.init(
            red: Double(red),
            green: Double(green),
            blue: Double(blue),
            alpha: Double(alpha)
        )
    }

    init?(components: [Double]) {
        guard components.count >= 3 else { return nil }
        self.init(
            red: components[0],
            green: components[1],
            blue: components[2],
            alpha: components.count > 3 ? components[3] : 1
        )
    }

    var swiftUIColor: Color {
        Color(red: red, green: green, blue: blue, opacity: alpha)
    }

    var components: [Double] {
        [red, green, blue, alpha]
    }

    var hexRGB: String {
        let red = Int((min(max(red, 0), 1) * 255).rounded())
        let green = Int((min(max(green, 0), 1) * 255).rounded())
        let blue = Int((min(max(blue, 0), 1) * 255).rounded())
        return String(format: "#%02X%02X%02X", red, green, blue)
    }

    func isApproximatelyEqual(to components: [Double], tolerance: Double = 0.001) -> Bool {
        guard let other = RGBAColor(components: components) else { return false }
        return abs(red - other.red) < tolerance
            && abs(green - other.green) < tolerance
            && abs(blue - other.blue) < tolerance
            && abs(alpha - other.alpha) < tolerance
    }
}

struct AnimationMetadata: Equatable {
    let formatVersion: String?
    let frameRate: Double
    let startFrame: Double
    let endFrame: Double
    let width: Int
    let height: Int
    let layerCount: Int
    let assetCount: Int
    let features: LottieFeatureSummary

    var frameCount: Double {
        max(0, endFrame - startFrame)
    }

    var duration: Double {
        guard frameRate > 0 else { return 0 }
        return frameCount / frameRate
    }
}

struct LottieFeatureSummary: Equatable {
    let totalLayerCount: Int
    let precompositionAssetCount: Int
    let imageAssetCount: Int
    let embeddedImageAssetCount: Int
    let externalImageAssetCount: Int
    let markerCount: Int
    let slotCount: Int
    let sidPropertyCount: Int
    let maskCount: Int
    let matteCount: Int
    let effectCount: Int
    let gaussianBlurCount: Int
    let expressionCount: Int
    let keyframedPropertyCount: Int
    let keyframedColorCount: Int
    let gradientCount: Int
    let trimPathCount: Int
    let mergePathCount: Int
    let repeaterCount: Int
    let textLayerCount: Int
    let threeDLayerCount: Int
    let timeRemapCount: Int
    let hiddenLayerCount: Int
    let parentedLayerCount: Int
    let layerTypes: [String: Int]
    let shapeTypes: [String: Int]
    let effectTypes: [String: Int]
    let missingAssetReferences: [String]
    let unknownLayerTypes: [String: Int]
    let unknownShapeTypes: [String: Int]

    var assetSummary: String {
        var parts: [String] = []
        if precompositionAssetCount > 0 {
            parts.append("\(precompositionAssetCount) precomps")
        }
        if imageAssetCount > 0 {
            parts.append("\(imageAssetCount) images")
        }
        if embeddedImageAssetCount > 0 {
            parts.append("\(embeddedImageAssetCount) embedded")
        }
        if externalImageAssetCount > 0 {
            parts.append("\(externalImageAssetCount) external")
        }
        return parts.isEmpty ? "No assets" : parts.joined(separator: " · ")
    }

    var advancedSummary: String {
        var parts: [String] = []
        if maskCount > 0 { parts.append("\(maskCount) masks") }
        if matteCount > 0 { parts.append("\(matteCount) mattes") }
        if gradientCount > 0 { parts.append("\(gradientCount) gradients") }
        if trimPathCount > 0 { parts.append("\(trimPathCount) trim paths") }
        if mergePathCount > 0 { parts.append("\(mergePathCount) merge paths") }
        if repeaterCount > 0 { parts.append("\(repeaterCount) repeaters") }
        if effectCount > 0 { parts.append("\(effectCount) effects") }
        if expressionCount > 0 { parts.append("\(expressionCount) expressions") }
        if slotCount + sidPropertyCount > 0 { parts.append("\(slotCount) slots / \(sidPropertyCount) sid") }
        return parts.isEmpty ? "Basic vector animation" : parts.joined(separator: " · ")
    }
}

struct AnimationEdits: Equatable {
    var colorReplacements: [RGBAColor: RGBAColor] = [:]
    var backgroundColor: RGBAColor?
    var playbackSpeed: Double = 1

    var isEmpty: Bool {
        colorReplacements.isEmpty && backgroundColor == nil && playbackSpeed == 1
    }
}

struct AnimationDiagnostic: Identifiable, Equatable {
    enum Severity: String {
        case info
        case warning
        case error
    }

    let id: String
    let severity: Severity
    let message: String
}

enum AnimationDocumentError: LocalizedError {
    case invalidRootObject
    case missingLayers

    var errorDescription: String? {
        switch self {
        case .invalidRootObject:
            return "The selected file is not a valid Lottie JSON object."
        case .missingLayers:
            return "The selected JSON does not contain a Lottie layers array."
        }
    }
}

private enum LottieFeatureScanner {
    private struct AssetInfo {
        enum Kind {
            case precomposition
            case image
            case unknown
        }

        let id: String
        let kind: Kind
        let isEmbeddedImage: Bool
    }

    private struct Accumulator {
        var totalLayerCount = 0
        var markerCount = 0
        var slotCount = 0
        var sidPropertyCount = 0
        var maskCount = 0
        var matteCount = 0
        var effectCount = 0
        var gaussianBlurCount = 0
        var expressionCount = 0
        var keyframedPropertyCount = 0
        var keyframedColorCount = 0
        var gradientCount = 0
        var trimPathCount = 0
        var mergePathCount = 0
        var repeaterCount = 0
        var textLayerCount = 0
        var threeDLayerCount = 0
        var timeRemapCount = 0
        var hiddenLayerCount = 0
        var parentedLayerCount = 0
        var layerTypes: [String: Int] = [:]
        var shapeTypes: [String: Int] = [:]
        var effectTypes: [String: Int] = [:]
        var missingAssetReferences: Set<String> = []
        var unknownLayerTypes: [String: Int] = [:]
        var unknownShapeTypes: [String: Int] = [:]
    }

    static func scan(root: [String: Any]) -> LottieFeatureSummary {
        let assets = root["assets"] as? [[String: Any]] ?? []
        let assetMap = makeAssetMap(from: assets)
        var accumulator = Accumulator()

        accumulator.markerCount = (root["markers"] as? [[String: Any]])?.count ?? 0
        accumulator.slotCount = countRootSlots(in: root)
        accumulator.sidPropertyCount = countSIDProperties(in: root)
        accumulator.expressionCount = countExpressions(in: root)
        accumulator.keyframedPropertyCount = countKeyframedProperties(in: root)
        accumulator.keyframedColorCount = countKeyframedColors(in: root)

        scanLayers(
            root["layers"] as? [[String: Any]] ?? [],
            assetMap: assetMap,
            accumulator: &accumulator
        )

        for asset in assets {
            guard let layers = asset["layers"] as? [[String: Any]] else { continue }
            scanLayers(
                layers,
                assetMap: assetMap,
                accumulator: &accumulator
            )
        }

        let imageAssets = assetMap.values.filter { $0.kind == .image }
        return LottieFeatureSummary(
            totalLayerCount: accumulator.totalLayerCount,
            precompositionAssetCount: assetMap.values.filter { $0.kind == .precomposition }.count,
            imageAssetCount: imageAssets.count,
            embeddedImageAssetCount: imageAssets.filter(\.isEmbeddedImage).count,
            externalImageAssetCount: imageAssets.filter { !$0.isEmbeddedImage }.count,
            markerCount: accumulator.markerCount,
            slotCount: accumulator.slotCount,
            sidPropertyCount: accumulator.sidPropertyCount,
            maskCount: accumulator.maskCount,
            matteCount: accumulator.matteCount,
            effectCount: accumulator.effectCount,
            gaussianBlurCount: accumulator.gaussianBlurCount,
            expressionCount: accumulator.expressionCount,
            keyframedPropertyCount: accumulator.keyframedPropertyCount,
            keyframedColorCount: accumulator.keyframedColorCount,
            gradientCount: accumulator.gradientCount,
            trimPathCount: accumulator.trimPathCount,
            mergePathCount: accumulator.mergePathCount,
            repeaterCount: accumulator.repeaterCount,
            textLayerCount: accumulator.textLayerCount,
            threeDLayerCount: accumulator.threeDLayerCount,
            timeRemapCount: accumulator.timeRemapCount,
            hiddenLayerCount: accumulator.hiddenLayerCount,
            parentedLayerCount: accumulator.parentedLayerCount,
            layerTypes: accumulator.layerTypes,
            shapeTypes: accumulator.shapeTypes,
            effectTypes: accumulator.effectTypes,
            missingAssetReferences: accumulator.missingAssetReferences.sorted(),
            unknownLayerTypes: accumulator.unknownLayerTypes,
            unknownShapeTypes: accumulator.unknownShapeTypes
        )
    }

    private static func makeAssetMap(from assets: [[String: Any]]) -> [String: AssetInfo] {
        Dictionary(
            uniqueKeysWithValues: assets.compactMap { asset in
                guard let id = asset["id"] as? String else { return nil }
                let kind: AssetInfo.Kind
                let isEmbeddedImage: Bool

                if asset["layers"] is [[String: Any]] {
                    kind = .precomposition
                    isEmbeddedImage = false
                } else if asset["p"] != nil || asset["u"] != nil {
                    kind = .image
                    let path = asset["p"] as? String ?? ""
                    let embeddedFlag = Int(number(asset["e"])) == 1
                    isEmbeddedImage = embeddedFlag || path.hasPrefix("data:")
                } else {
                    kind = .unknown
                    isEmbeddedImage = false
                }

                return (id, AssetInfo(id: id, kind: kind, isEmbeddedImage: isEmbeddedImage))
            }
        )
    }

    private static func scanLayers(
        _ layers: [[String: Any]],
        assetMap: [String: AssetInfo],
        accumulator: inout Accumulator
    ) {
        for (index, layer) in layers.enumerated() {
            accumulator.totalLayerCount += 1

            let layerType = Int(number(layer["ty"]))
            increment(layerTypeName(layerType), in: &accumulator.layerTypes)
            if layerTypeName(layerType).hasPrefix("Unknown") {
                increment("ty \(layerType)", in: &accumulator.unknownLayerTypes)
            }

            if bool(layer["hd"]) {
                accumulator.hiddenLayerCount += 1
            }
            if Int(number(layer["ddd"])) == 1 {
                accumulator.threeDLayerCount += 1
            }
            if layer["parent"] != nil {
                accumulator.parentedLayerCount += 1
            }
            if layer["tt"] != nil || layer["tp"] != nil {
                accumulator.matteCount += 1
            }
            if layer["tm"] != nil {
                accumulator.timeRemapCount += 1
            }
            if layerType == 5 {
                accumulator.textLayerCount += 1
            }

            if let masks = layer["masksProperties"] as? [[String: Any]] {
                accumulator.maskCount += masks.count
            }

            if let refId = layer["refId"] as? String,
               assetMap[refId] == nil {
                let layerName = layer["nm"] as? String ?? "Layer \(index + 1)"
                accumulator.missingAssetReferences.insert("\(layerName) → \(refId)")
            }

            if let effects = layer["ef"] as? [[String: Any]] {
                scanEffects(effects, layer: layer, accumulator: &accumulator)
            }

            if let shapes = layer["shapes"] as? [[String: Any]] {
                scanShapes(shapes, accumulator: &accumulator)
            }
        }
    }

    private static func scanEffects(
        _ effects: [[String: Any]],
        layer: [String: Any],
        accumulator: inout Accumulator
    ) {
        for effect in effects {
            accumulator.effectCount += 1
            let effectType = Int(number(effect["ty"]))
            if effectType == 29 {
                accumulator.gaussianBlurCount += 1
            }
            increment(effectTypeName(effectType, effect: effect), in: &accumulator.effectTypes)
        }
    }

    private static func scanShapes(
        _ shapes: [[String: Any]],
        accumulator: inout Accumulator
    ) {
        for shape in shapes {
            let shapeType = shape["ty"] as? String ?? "unknown"
            increment(shapeTypeName(shapeType), in: &accumulator.shapeTypes)

            if shapeTypeName(shapeType).hasPrefix("Unknown") {
                increment(shapeType, in: &accumulator.unknownShapeTypes)
            }

            switch shapeType {
            case "gf", "gs":
                accumulator.gradientCount += 1
            case "tm":
                accumulator.trimPathCount += 1
            case "mm":
                accumulator.mergePathCount += 1
            case "rp":
                accumulator.repeaterCount += 1
            default:
                break
            }

            if let items = shape["it"] as? [[String: Any]] {
                scanShapes(items, accumulator: &accumulator)
            }
        }
    }

    private static func countRootSlots(in root: [String: Any]) -> Int {
        if let slots = root["slots"] as? [[String: Any]] {
            return slots.count
        }
        if let slots = root["slots"] as? [String: Any] {
            return slots.count
        }
        return 0
    }

    private static func countSIDProperties(in value: Any) -> Int {
        countDictionaries(in: value) { dictionary in
            dictionary["sid"] is String
        }
    }

    private static func countExpressions(in value: Any) -> Int {
        countDictionaries(in: value) { dictionary in
            dictionary["x"] is String
        }
    }

    private static func countKeyframedProperties(in value: Any) -> Int {
        countDictionaries(in: value) { dictionary in
            Int(number(dictionary["a"])) == 1 && dictionary["k"] != nil
        }
    }

    private static func countKeyframedColors(in value: Any) -> Int {
        countDictionaries(in: value) { dictionary in
            guard let type = dictionary["ty"] as? String,
                  type == "fl" || type == "st" || type == "gf" || type == "gs",
                  let color = dictionary["c"] as? [String: Any] else {
                return false
            }
            return color["k"] is [[String: Any]]
        }
    }

    private static func countDictionaries(
        in value: Any,
        matching predicate: ([String: Any]) -> Bool
    ) -> Int {
        if let dictionary = value as? [String: Any] {
            let ownCount = predicate(dictionary) ? 1 : 0
            return ownCount + dictionary.values.reduce(0) {
                $0 + countDictionaries(in: $1, matching: predicate)
            }
        }
        if let array = value as? [Any] {
            return array.reduce(0) {
                $0 + countDictionaries(in: $1, matching: predicate)
            }
        }
        return 0
    }

    private static func increment(_ key: String, in dictionary: inout [String: Int]) {
        dictionary[key, default: 0] += 1
    }

    private static func layerTypeName(_ type: Int) -> String {
        switch type {
        case 0: "Precomposition"
        case 1: "Solid"
        case 2: "Image"
        case 3: "Null"
        case 4: "Shape"
        case 5: "Text"
        case 6: "Audio"
        case 13: "Camera"
        case 15: "Light"
        default: "Unknown layer ty \(type)"
        }
    }

    private static func shapeTypeName(_ type: String) -> String {
        switch type {
        case "el": "Ellipse"
        case "fl": "Fill"
        case "gf": "Gradient Fill"
        case "gr": "Group"
        case "gs": "Gradient Stroke"
        case "mm": "Merge Paths"
        case "pb": "Pucker & Bloat"
        case "rc": "Rectangle"
        case "rd": "Rounded Corners"
        case "rp": "Repeater"
        case "sh": "Path"
        case "sr": "Star"
        case "st": "Stroke"
        case "tm": "Trim Paths"
        case "tr": "Transform"
        default: "Unknown shape \(type)"
        }
    }

    private static func effectTypeName(_ type: Int, effect: [String: Any]) -> String {
        if type == 29 {
            return "Gaussian Blur"
        }
        let name = effect["nm"] as? String
            ?? effect["mn"] as? String
            ?? "Effect"
        return "\(name) (ty \(type))"
    }

    private static func bool(_ value: Any?) -> Bool {
        if let bool = value as? Bool { return bool }
        return Int(number(value)) != 0
    }

    private static func number(_ value: Any?) -> Double {
        if let value = value as? NSNumber {
            return value.doubleValue
        }
        if let value = value as? Double {
            return value
        }
        if let value = value as? Int {
            return Double(value)
        }
        return 0
    }
}

@MainActor
final class AnimationDocument: ObservableObject {
    @Published private(set) var sourceURL: URL?
    @Published private(set) var originalData: Data?
    @Published private(set) var metadata: AnimationMetadata?
    @Published private(set) var diagnostics: [AnimationDiagnostic] = []
    @Published private(set) var edits = AnimationEdits()
    @Published var selectedRuntime: LottieRuntimeVersion = .embedded

    var isLoaded: Bool {
        originalData != nil && metadata != nil
    }

    var displayName: String {
        sourceURL?.deletingPathExtension().lastPathComponent ?? "Untitled Animation"
    }

    var renderedData: Data? {
        guard let originalData else { return nil }
        return try? Self.renderedData(from: originalData, edits: edits)
    }

    var renderingDiagnostics: [AnimationDiagnostic] {
        diagnostics.filter { $0.id.hasPrefix("render-") }
    }

    var hasRenderingLimitations: Bool {
        !renderingDiagnostics.isEmpty
    }

    static func requiresWebRenderer(_ data: Data) -> Bool {
        guard let root = try? rootObject(from: data) else { return false }
        return containsGaussianBlur(in: root)
    }

    func load(from url: URL) throws {
        let data = try Self.readData(from: url)
        try load(data: data, sourceURL: url)
    }

    func load(data: Data, sourceURL: URL? = nil) throws {
        let root = try Self.rootObject(from: data)
        guard root["layers"] is [[String: Any]] else {
            throw AnimationDocumentError.missingLayers
        }

        self.sourceURL = sourceURL
        originalData = data
        metadata = Self.makeMetadata(from: root)
        diagnostics = Self.makeDiagnostics(from: root)
        edits = AnimationEdits()
        selectedRuntime = .embedded
    }

    func updateColorReplacements(_ replacements: [Color: Color]) {
        edits.colorReplacements = Dictionary(
            uniqueKeysWithValues: replacements.map { (RGBAColor($0.key), RGBAColor($0.value)) }
        )
    }

    func updateBackgroundColor(_ color: Color?) {
        edits.backgroundColor = color.map(RGBAColor.init)
    }

    func updatePlaybackSpeed(_ speed: Double) {
        edits.playbackSpeed = speed
    }

    func selectRuntime(_ runtime: LottieRuntimeVersion) {
        selectedRuntime = runtime
    }

    func apply(_ newEdits: AnimationEdits) throws {
        guard let originalData else {
            throw AnimationDocumentError.invalidRootObject
        }

        _ = try Self.renderedData(from: originalData, edits: newEdits)
        edits = newEdits
    }

    var colorReplacementsForUI: [Color: Color] {
        Dictionary(
            uniqueKeysWithValues: edits.colorReplacements.map {
                ($0.key.swiftUIColor, $0.value.swiftUIColor)
            }
        )
    }

    static func renderedData(from data: Data, edits: AnimationEdits) throws -> Data {
        var root = try rootObject(from: data)
        root = apply(edits: edits, to: root)
        return try JSONSerialization.data(withJSONObject: root, options: [])
    }

    static func discoveredColors(in data: Data) throws -> [RGBAColor] {
        let root = try rootObject(from: data)
        var colors: [RGBAColor] = []
        collectColors(in: root, into: &colors)

        return colors.reduce(into: []) { result, color in
            if !result.contains(where: { approximatelyEqual($0, color) }) {
                result.append(color)
            }
        }
    }

    private static func readData(from url: URL) throws -> Data {
        let isBundled = url.path.contains(Bundle.main.bundlePath)
        let isInDocuments = url.path.contains(FileManager.documentsDirectory().path)
        let needsSecurityAccess = !isBundled && !isInDocuments
        let hasAccess = !needsSecurityAccess || url.startAccessingSecurityScopedResource()

        guard hasAccess else {
            throw CocoaError(.fileReadNoPermission)
        }

        defer {
            if needsSecurityAccess {
                url.stopAccessingSecurityScopedResource()
            }
        }

        return try Data(contentsOf: url)
    }

    private static func rootObject(from data: Data) throws -> [String: Any] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AnimationDocumentError.invalidRootObject
        }
        return root
    }

    private static func makeMetadata(from root: [String: Any]) -> AnimationMetadata {
        let layers = root["layers"] as? [[String: Any]] ?? []
        let assets = root["assets"] as? [[String: Any]] ?? []
        let features = LottieFeatureScanner.scan(root: root)

        return AnimationMetadata(
            formatVersion: root["v"] as? String,
            frameRate: number(root["fr"]),
            startFrame: number(root["ip"]),
            endFrame: number(root["op"]),
            width: Int(number(root["w"])),
            height: Int(number(root["h"])),
            layerCount: layers.count,
            assetCount: assets.count,
            features: features
        )
    }

    private static func makeDiagnostics(from root: [String: Any]) -> [AnimationDiagnostic] {
        var result: [AnimationDiagnostic] = []
        let features = LottieFeatureScanner.scan(root: root)

        if root["v"] as? String == nil {
            result.append(.init(
                id: "missing-version",
                severity: .warning,
                message: "The Lottie format version is missing."
            ))
        }

        if number(root["fr"]) <= 0 {
            result.append(.init(
                id: "invalid-frame-rate",
                severity: .error,
                message: "Frame rate must be greater than zero."
            ))
        }

        if number(root["op"]) <= number(root["ip"]) {
            result.append(.init(
                id: "invalid-frame-range",
                severity: .error,
                message: "The animation end frame must be after its start frame."
            ))
        }

        if containsExpressions(in: root) {
            result.append(.init(
                id: "expressions",
                severity: .warning,
                message: "Expressions were detected and may not render consistently."
            ))
        }

        if containsKeyframedColors(in: root) {
            result.append(.init(
                id: "keyframed-colors",
                severity: .info,
                message: "The animation contains keyframed colors."
            ))
        }

        result.append(contentsOf: makeFeatureDiagnostics(from: features))
        collectRenderingDiagnostics(in: root, into: &result)
        return result
    }

    private static func makeFeatureDiagnostics(
        from features: LottieFeatureSummary
    ) -> [AnimationDiagnostic] {
        var diagnostics: [AnimationDiagnostic] = []

        if !features.missingAssetReferences.isEmpty {
            diagnostics.append(.init(
                id: "missing-asset-references",
                severity: .error,
                message: "Missing asset references: \(features.missingAssetReferences.prefix(3).joined(separator: ", "))"
            ))
        }

        if features.externalImageAssetCount > 0 {
            diagnostics.append(.init(
                id: "external-image-assets",
                severity: .warning,
                message: "\(features.externalImageAssetCount) external image asset(s) detected. Import should keep these files together with the JSON or embed them."
            ))
        }

        if features.precompositionAssetCount > 0 {
            diagnostics.append(.init(
                id: "precompositions",
                severity: .info,
                message: "\(features.precompositionAssetCount) precomposition asset(s) scanned recursively."
            ))
        }

        if features.maskCount > 0 || features.matteCount > 0 {
            diagnostics.append(.init(
                id: "masks-mattes",
                severity: .info,
                message: "\(features.maskCount) mask(s) and \(features.matteCount) matte relationship(s) detected."
            ))
        }

        if features.textLayerCount > 0 {
            diagnostics.append(.init(
                id: "text-layers",
                severity: .warning,
                message: "\(features.textLayerCount) text layer(s) detected. Font availability can change rendering between platforms."
            ))
        }

        if features.threeDLayerCount > 0 {
            diagnostics.append(.init(
                id: "three-d-layers",
                severity: .warning,
                message: "\(features.threeDLayerCount) 3D layer(s) detected. 3D support varies across Lottie renderers."
            ))
        }

        if features.timeRemapCount > 0 {
            diagnostics.append(.init(
                id: "time-remap",
                severity: .warning,
                message: "\(features.timeRemapCount) time-remapped layer(s) detected."
            ))
        }

        if features.gradientCount > 0 || features.trimPathCount > 0 || features.mergePathCount > 0 || features.repeaterCount > 0 {
            diagnostics.append(.init(
                id: "advanced-shapes",
                severity: .info,
                message: "Advanced shapes: \(features.advancedSummary)."
            ))
        }

        if features.slotCount > 0 || features.sidPropertyCount > 0 {
            diagnostics.append(.init(
                id: "slots",
                severity: .info,
                message: "Slot-ready properties detected: \(features.slotCount) slot(s), \(features.sidPropertyCount) sid-tagged property/properties."
            ))
        }

        if !features.unknownLayerTypes.isEmpty {
            diagnostics.append(.init(
                id: "unknown-layer-types",
                severity: .warning,
                message: "Unknown layer type(s): \(formatCounts(features.unknownLayerTypes))."
            ))
        }

        if !features.unknownShapeTypes.isEmpty {
            diagnostics.append(.init(
                id: "unknown-shape-types",
                severity: .warning,
                message: "Unknown shape type(s): \(formatCounts(features.unknownShapeTypes))."
            ))
        }

        return diagnostics
    }

    private static func formatCounts(_ counts: [String: Int]) -> String {
        counts
            .sorted { lhs, rhs in
                if lhs.value == rhs.value {
                    return lhs.key < rhs.key
                }
                return lhs.value > rhs.value
            }
            .prefix(5)
            .map { "\($0.key) ×\($0.value)" }
            .joined(separator: ", ")
    }

    private static func collectRenderingDiagnostics(
        in root: [String: Any],
        into diagnostics: inout [AnimationDiagnostic]
    ) {
        collectLayerDiagnostics(
            in: root["layers"] as? [[String: Any]] ?? [],
            location: "root composition",
            into: &diagnostics
        )

        for asset in root["assets"] as? [[String: Any]] ?? [] {
            guard let layers = asset["layers"] as? [[String: Any]] else { continue }
            let assetName = asset["id"] as? String ?? "precomposition"
            collectLayerDiagnostics(
                in: layers,
                location: assetName,
                into: &diagnostics
            )
        }
    }

    private static func collectLayerDiagnostics(
        in layers: [[String: Any]],
        location: String,
        into diagnostics: inout [AnimationDiagnostic]
    ) {
        for layer in layers {
            let layerName = layer["nm"] as? String ?? "Unnamed layer"
            let layerIndex = Int(number(layer["ind"]))

            for effect in layer["ef"] as? [[String: Any]] ?? [] {
                let effectType = Int(number(effect["ty"]))
                guard effectType != 25 else { continue }

                let effectName = effect["nm"] as? String
                    ?? effect["mn"] as? String
                    ?? "Effect \(effectType)"
                let knownName = effectType == 29 ? "Gaussian Blur" : effectName
                let message: String

                if effectType == 29 {
                    message = "\(knownName) on layer “\(layerName)” is rendered with the lottie-web SVG fallback because lottie-ios does not support this effect."
                } else {
                    message = "\(knownName) on layer “\(layerName)” is not supported by lottie-ios and may render differently."
                }

                diagnostics.append(.init(
                    id: "render-effect-\(location)-\(layerIndex)-\(effectType)",
                    severity: .warning,
                    message: message
                ))
            }
        }
    }

    private static func apply(edits: AnimationEdits, to root: [String: Any]) -> [String: Any] {
        var updated = root

        if let layers = root["layers"] as? [[String: Any]] {
            updated["layers"] = layers.map {
                processLayer($0, replacements: edits.colorReplacements)
            }
        }

        if let assets = root["assets"] as? [[String: Any]] {
            updated["assets"] = assets.map { asset in
                var updatedAsset = asset
                if let layers = asset["layers"] as? [[String: Any]] {
                    updatedAsset["layers"] = layers.map {
                        processLayer($0, replacements: edits.colorReplacements)
                    }
                }
                return updatedAsset
            }
        }

        applyBackground(edits.backgroundColor, to: &updated)
        return updated
    }

    private static func applyBackground(
        _ backgroundColor: RGBAColor?,
        to root: inout [String: Any]
    ) {
        let layerName = "__FlippieBackground"
        var layers = (root["layers"] as? [[String: Any]] ?? []).filter {
            $0["nm"] as? String != layerName
        }

        guard let backgroundColor else {
            root["layers"] = layers
            return
        }

        let width = max(1, Int(number(root["w"])))
        let height = max(1, Int(number(root["h"])))
        let startFrame = number(root["ip"])
        let endFrame = number(root["op"])
        let maximumIndex = layers.compactMap { ($0["ind"] as? NSNumber)?.intValue }.max() ?? 0

        let backgroundLayer: [String: Any] = [
            "ddd": 0,
            "ind": maximumIndex + 1,
            "ty": 1,
            "nm": layerName,
            "sr": 1,
            "ks": [
                "o": ["a": 0, "k": backgroundColor.alpha * 100],
                "r": ["a": 0, "k": 0],
                "p": ["a": 0, "k": [Double(width) / 2, Double(height) / 2, 0]],
                "a": ["a": 0, "k": [Double(width) / 2, Double(height) / 2, 0]],
                "s": ["a": 0, "k": [100, 100, 100]],
            ],
            "ao": 0,
            "sw": width,
            "sh": height,
            "sc": backgroundColor.hexRGB,
            "ip": startFrame,
            "op": endFrame,
            "st": startFrame,
            "bm": 0,
        ]

        layers.append(backgroundLayer)
        root["layers"] = layers
    }

    private static func processLayer(
        _ layer: [String: Any],
        replacements: [RGBAColor: RGBAColor]
    ) -> [String: Any] {
        var updated = layer
        if let shapes = layer["shapes"] as? [[String: Any]] {
            updated["shapes"] = shapes.map {
                processShape($0, replacements: replacements)
            }
        }
        return updated
    }

    private static func processShape(
        _ shape: [String: Any],
        replacements: [RGBAColor: RGBAColor]
    ) -> [String: Any] {
        var updated = shape

        if let type = shape["ty"] as? String,
           type == "fl" || type == "st",
           var color = shape["c"] as? [String: Any] {
            color["k"] = replaceColorValue(color["k"], replacements: replacements)
            updated["c"] = color
        }

        if let items = shape["it"] as? [[String: Any]] {
            updated["it"] = items.map {
                processShape($0, replacements: replacements)
            }
        }

        return updated
    }

    private static func replaceColorValue(
        _ value: Any?,
        replacements: [RGBAColor: RGBAColor]
    ) -> Any? {
        if let components = colorComponents(from: value) {
            return replacementComponents(
                for: components,
                in: replacements
            ) ?? components
        }

        guard let keyframes = value as? [[String: Any]] else {
            return value
        }

        return keyframes.map { keyframe in
            var updated = keyframe
            for key in ["s", "e"] {
                if let components = colorComponents(from: keyframe[key]),
                   let replacement = replacementComponents(
                       for: components,
                       in: replacements
                   ) {
                    updated[key] = replacement
                }
            }
            return updated
        }
    }

    private static func replacementComponents(
        for components: [Double],
        in replacements: [RGBAColor: RGBAColor]
    ) -> [Double]? {
        guard let replacement = replacement(for: components, in: replacements) else {
            return nil
        }

        return components.count == 3
            ? Array(replacement.components.prefix(3))
            : replacement.components
    }

    private static func replacement(
        for components: [Double],
        in replacements: [RGBAColor: RGBAColor]
    ) -> RGBAColor? {
        replacements.first { original, _ in
            original.isApproximatelyEqual(to: components)
        }?.value
    }

    private static func collectColors(in value: Any, into colors: inout [RGBAColor]) {
        if let dictionary = value as? [String: Any] {
            if let type = dictionary["ty"] as? String,
               (type == "fl" || type == "st"),
               let color = dictionary["c"] as? [String: Any] {
                collectColorValues(from: color["k"], into: &colors)
            }

            for nestedValue in dictionary.values {
                collectColors(in: nestedValue, into: &colors)
            }
        } else if let array = value as? [Any] {
            for nestedValue in array {
                collectColors(in: nestedValue, into: &colors)
            }
        }
    }

    private static func collectColorValues(from value: Any?, into colors: inout [RGBAColor]) {
        if let components = colorComponents(from: value),
           let color = RGBAColor(components: components) {
            colors.append(color)
            return
        }

        guard let keyframes = value as? [[String: Any]] else { return }
        for keyframe in keyframes {
            for key in ["s", "e"] {
                if let components = colorComponents(from: keyframe[key]),
                   let color = RGBAColor(components: components) {
                    colors.append(color)
                }
            }
        }
    }

    private static func colorComponents(from value: Any?) -> [Double]? {
        if let values = value as? [NSNumber], values.count >= 3 {
            return values.map(\.doubleValue)
        }
        if let values = value as? [Double], values.count >= 3 {
            return values
        }
        return nil
    }

    private static func approximatelyEqual(_ lhs: RGBAColor, _ rhs: RGBAColor) -> Bool {
        lhs.isApproximatelyEqual(to: rhs.components)
    }

    private static func containsExpressions(in value: Any) -> Bool {
        if let dictionary = value as? [String: Any] {
            if dictionary["x"] is String {
                return true
            }
            return dictionary.values.contains(where: containsExpressions)
        }
        if let array = value as? [Any] {
            return array.contains(where: containsExpressions)
        }
        return false
    }

    private static func containsKeyframedColors(in value: Any) -> Bool {
        if let dictionary = value as? [String: Any] {
            if let type = dictionary["ty"] as? String,
               (type == "fl" || type == "st"),
               let color = dictionary["c"] as? [String: Any],
               color["k"] is [[String: Any]] {
                return true
            }
            return dictionary.values.contains(where: containsKeyframedColors)
        }
        if let array = value as? [Any] {
            return array.contains(where: containsKeyframedColors)
        }
        return false
    }

    private static func containsGaussianBlur(in value: Any) -> Bool {
        if let dictionary = value as? [String: Any] {
            if let effects = dictionary["ef"] as? [[String: Any]],
               effects.contains(where: { Int(number($0["ty"])) == 29 }) {
                return true
            }
            return dictionary.values.contains(where: containsGaussianBlur)
        }
        if let array = value as? [Any] {
            return array.contains(where: containsGaussianBlur)
        }
        return false
    }

    private static func number(_ value: Any?) -> Double {
        if let value = value as? NSNumber {
            return value.doubleValue
        }
        return 0
    }
}
