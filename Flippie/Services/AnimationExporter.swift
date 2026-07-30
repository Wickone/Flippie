import AVFoundation
import ImageIO
import SwiftUI
import UniformTypeIdentifiers
import VideoToolbox

enum AnimationExportFormat: String, CaseIterable, Identifiable {
    case json = "JSON"
    case gif = "GIF"
    case mp4 = "MP4"
    case mov = "MOV"

    var id: String { rawValue }

    var fileExtension: String {
        rawValue.lowercased()
    }

    var supportsTransparency: Bool {
        self == .gif || self == .mov
    }

    var systemImage: String {
        switch self {
        case .json: "doc.text"
        case .gif: "photo.stack"
        case .mp4, .mov: "film"
        }
    }
}

struct AnimationExportPlan: Equatable {
    let format: AnimationExportFormat
    let size: CGSize
    let framesPerSecond: Int
    let duration: Double
    let transparent: Bool
    let backgroundColor: RGBAColor
    let gifQuality: Double

    var outputSize: CGSize {
        guard format == .mp4 || format == .mov else { return integralSize }
        return CGSize(
            width: evenPixelCount(integralSize.width),
            height: evenPixelCount(integralSize.height)
        )
    }

    var frameCount: Int {
        max(1, Int(ceil(duration * Double(framesPerSecond))))
    }

    func validate() throws {
        if format == .json {
            return
        }
        guard size.width > 0, size.height > 0 else {
            throw AnimationExportError.invalidSize
        }
        guard framesPerSecond > 0 else {
            throw AnimationExportError.invalidFrameRate
        }
        guard duration > 0 || format == .json else {
            throw AnimationExportError.invalidDuration
        }
        guard !transparent || format.supportsTransparency else {
            throw AnimationExportError.transparencyUnsupported(format)
        }
    }

    private var integralSize: CGSize {
        CGSize(
            width: max(1, size.width.rounded()),
            height: max(1, size.height.rounded())
        )
    }

    private func evenPixelCount(_ value: CGFloat) -> CGFloat {
        let integer = max(2, Int(value.rounded()))
        return CGFloat(integer.isMultiple(of: 2) ? integer : integer + 1)
    }
}

struct AnimationExportRequest {
    let animationData: Data
    let runtime: LottieRuntimeVersion
    let plan: AnimationExportPlan
    let assetBaseURL: URL?
    let preferredFileName: String?

    init(
        animationData: Data,
        runtime: LottieRuntimeVersion,
        plan: AnimationExportPlan,
        assetBaseURL: URL? = nil,
        preferredFileName: String? = nil
    ) {
        self.animationData = animationData
        self.runtime = runtime
        self.plan = plan
        self.assetBaseURL = assetBaseURL
        self.preferredFileName = preferredFileName
    }
}

enum AnimationExportError: LocalizedError {
    case invalidSize
    case invalidFrameRate
    case invalidDuration
    case transparencyUnsupported(AnimationExportFormat)
    case frameCaptureFailed(Int)
    case gifCreationFailed
    case gifFinalizationFailed
    case writerCreationFailed(String)
    case writerInputRejected
    case writerStartFailed(String)
    case pixelBufferPoolUnavailable
    case pixelBufferCreationFailed(Int32)
    case pixelBufferContextFailed
    case frameAppendFailed(Int, String)
    case writerFinishFailed(String)
    case alphaEncodingUnavailable

    var errorDescription: String? {
        switch self {
        case .invalidSize:
            "Export size must be greater than zero."
        case .invalidFrameRate:
            "Frame rate must be greater than zero."
        case .invalidDuration:
            "The animation duration is missing or invalid."
        case .transparencyUnsupported(let format):
            "\(format.rawValue) does not support transparent video. Use MOV or disable transparency."
        case .frameCaptureFailed(let frame):
            "Could not render frame \(frame + 1)."
        case .gifCreationFailed:
            "Could not create the GIF destination."
        case .gifFinalizationFailed:
            "Could not finalize the GIF file."
        case .writerCreationFailed(let reason):
            "Could not create the video writer: \(reason)"
        case .writerInputRejected:
            "The selected video settings are not supported by AVAssetWriter."
        case .writerStartFailed(let reason):
            "Could not start video export: \(reason)"
        case .pixelBufferPoolUnavailable:
            "The video pixel buffer pool is unavailable."
        case .pixelBufferCreationFailed(let status):
            "Could not allocate a video frame buffer (status \(status))."
        case .pixelBufferContextFailed:
            "Could not create the video frame drawing context."
        case .frameAppendFailed(let frame, let reason):
            "Could not write video frame \(frame + 1): \(reason)"
        case .writerFinishFailed(let reason):
            "Could not finish the video file: \(reason)"
        case .alphaEncodingUnavailable:
            "This device could not encode HEVC with Alpha. Try an opaque MOV or export on a compatible Apple device."
        }
    }
}

@MainActor
final class AnimationFrameRenderer {
    private let player = VersionedLottiePlayerView()
    private let window: UIWindow
    private let viewController = UIViewController()
    private let size: CGSize
    private let transparent: Bool
    private let backgroundColor: UIColor

    init(
        animationData: Data,
        runtime: LottieRuntimeVersion,
        size: CGSize,
        transparent: Bool,
        backgroundColor: RGBAColor,
        assetBaseURL: URL? = nil
    ) throws {
        self.size = size
        self.transparent = transparent
        self.backgroundColor = UIColor(backgroundColor)
        window = UIWindow(frame: CGRect(origin: .zero, size: size))

        _ = try player.load(
            data: animationData,
            runtime: runtime,
            baseURL: assetBaseURL
        )
        player.frame = CGRect(origin: .zero, size: size)
        player.contentMode = .scaleAspectFit
        player.loopMode = .playOnce
        player.animationSpeed = 0
        player.backgroundColor = .clear

        viewController.view.frame = window.bounds
        viewController.view.backgroundColor = transparent ? .clear : self.backgroundColor
        viewController.view.addSubview(player)
        window.rootViewController = viewController
        window.backgroundColor = transparent ? .clear : self.backgroundColor
        window.isUserInteractionEnabled = false
        window.alpha = 0.01
        window.isHidden = false
        window.layoutIfNeeded()
        viewController.view.layoutIfNeeded()
        player.layoutIfNeeded()
    }

    func render(progress: Double, frameIndex: Int) async throws -> CGImage {
        try await player.prepareFrame(
            progress: min(max(progress, 0), 1)
        )
        window.layoutIfNeeded()
        viewController.view.layoutIfNeeded()
        player.layoutIfNeeded()
        player.layer.setNeedsDisplay()
        player.layer.displayIfNeeded()
        CATransaction.flush()

        if let webImage = try await player.webSnapshotCGImage(size: size) {
            return composite(image: webImage)
        }

        return try captureNativeFrame(frameIndex: frameIndex)
    }

    private func captureNativeFrame(frameIndex: Int) throws -> CGImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = !transparent
        format.preferredRange = .standard
        let renderer = UIGraphicsImageRenderer(
            bounds: CGRect(origin: .zero, size: size),
            format: format
        )
        let image = renderer.image { context in
            if !transparent {
                context.cgContext.setFillColor(backgroundColor.cgColor)
                context.cgContext.fill(CGRect(origin: .zero, size: size))
            }
            if !player.drawHierarchy(in: player.bounds, afterScreenUpdates: true) {
                player.layer.render(in: context.cgContext)
            }
        }

        guard let cgImage = image.cgImage else {
            throw AnimationExportError.frameCaptureFailed(frameIndex)
        }
        return cgImage
    }

    private func composite(image: CGImage) -> CGImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = !transparent
        let renderer = UIGraphicsImageRenderer(
            bounds: CGRect(origin: .zero, size: size),
            format: format
        )
        return renderer.image { context in
            if !transparent {
                context.cgContext.setFillColor(backgroundColor.cgColor)
                context.cgContext.fill(CGRect(origin: .zero, size: size))
            }
            UIImage(cgImage: image).draw(in: CGRect(origin: .zero, size: size))
        }.cgImage!
    }
}

@MainActor
final class AnimationExporter {
    typealias ProgressHandler = (Double) -> Void

    func export(
        request: AnimationExportRequest,
        progress: @escaping ProgressHandler
    ) async throws -> URL {
        try request.plan.validate()
        let outputURL = Self.outputURL(
            for: request.plan.format,
            preferredFileName: request.preferredFileName
        )

        do {
            switch request.plan.format {
            case .json:
                progress(0.25)
                try Task.checkCancellation()
                try request.animationData.write(to: outputURL, options: .atomic)
            case .gif:
                try await exportGIF(request: request, to: outputURL, progress: progress)
            case .mp4, .mov:
                try await exportVideo(request: request, to: outputURL, progress: progress)
            }
            try Task.checkCancellation()
            progress(1)
            return outputURL
        } catch {
            try? FileManager.default.removeItem(at: outputURL)
            throw error
        }
    }

    private func exportGIF(
        request: AnimationExportRequest,
        to outputURL: URL,
        progress: @escaping ProgressHandler
    ) async throws {
        let plan = request.plan
        let renderer = try makeRenderer(for: request)
        guard let destination = CGImageDestinationCreateWithURL(
            outputURL as CFURL,
            UTType.gif.identifier as CFString,
            plan.frameCount,
            nil
        ) else {
            throw AnimationExportError.gifCreationFailed
        }

        let delay = 1 / Double(plan.framesPerSecond)
        CGImageDestinationSetProperties(destination, [
            kCGImagePropertyGIFDictionary: [
                kCGImagePropertyGIFLoopCount: 0
            ]
        ] as CFDictionary)

        for frameIndex in 0..<plan.frameCount {
            try Task.checkCancellation()
            let cgImage = try await renderer.render(
                progress: Double(frameIndex) / Double(plan.frameCount),
                frameIndex: frameIndex
            )
            let frameProperties: [CFString: Any] = [
                kCGImagePropertyGIFDictionary: [
                    kCGImagePropertyGIFDelayTime: delay,
                    kCGImagePropertyGIFUnclampedDelayTime: delay
                ],
                kCGImageDestinationLossyCompressionQuality: min(max(plan.gifQuality, 0), 1)
            ]
            CGImageDestinationAddImage(destination, cgImage, frameProperties as CFDictionary)
            progress(Double(frameIndex + 1) / Double(plan.frameCount))
            await Task.yield()
        }

        guard CGImageDestinationFinalize(destination) else {
            throw AnimationExportError.gifFinalizationFailed
        }
    }

    private func exportVideo(
        request: AnimationExportRequest,
        to outputURL: URL,
        progress: @escaping ProgressHandler
    ) async throws {
        let plan = request.plan
        let fileType: AVFileType = plan.format == .mp4 ? .mp4 : .mov
        let codec: AVVideoCodecType = plan.transparent ? .hevcWithAlpha : .h264
        let writer: AVAssetWriter

        do {
            writer = try AVAssetWriter(outputURL: outputURL, fileType: fileType)
        } catch {
            throw AnimationExportError.writerCreationFailed(error.localizedDescription)
        }

        var outputSettings: [String: Any] = [
            AVVideoCodecKey: codec,
            AVVideoWidthKey: Int(plan.outputSize.width),
            AVVideoHeightKey: Int(plan.outputSize.height)
        ]
        if plan.transparent {
            outputSettings[AVVideoCompressionPropertiesKey] = [
                kVTCompressionPropertyKey_AlphaChannelMode as String:
                    kVTAlphaChannelMode_PremultipliedAlpha
            ]
        }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: outputSettings)
        input.expectsMediaDataInRealTime = false
        guard writer.canAdd(input) else {
            throw AnimationExportError.writerInputRejected
        }
        writer.add(input)

        let pixelBufferAttributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(plan.outputSize.width),
            kCVPixelBufferHeightKey as String: Int(plan.outputSize.height),
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ]
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: pixelBufferAttributes
        )

        guard writer.startWriting() else {
            throw AnimationExportError.writerStartFailed(
                writer.error?.localizedDescription ?? "Unknown AVAssetWriter error."
            )
        }
        writer.startSession(atSourceTime: .zero)

        do {
            let renderer = try makeRenderer(for: request)
            for frameIndex in 0..<plan.frameCount {
                try Task.checkCancellation()
                while !input.isReadyForMoreMediaData {
                    try Task.checkCancellation()
                    try await Task.sleep(nanoseconds: 2_000_000)
                }

                let image = try await renderer.render(
                    progress: Double(frameIndex) / Double(plan.frameCount),
                    frameIndex: frameIndex
                )
                guard let pool = adaptor.pixelBufferPool else {
                    throw AnimationExportError.pixelBufferPoolUnavailable
                }
                var optionalBuffer: CVPixelBuffer?
                let status = CVPixelBufferPoolCreatePixelBuffer(
                    nil,
                    pool,
                    &optionalBuffer
                )
                guard status == kCVReturnSuccess, let pixelBuffer = optionalBuffer else {
                    throw AnimationExportError.pixelBufferCreationFailed(status)
                }
                if plan.transparent {
                    CVBufferSetAttachment(
                        pixelBuffer,
                        kCVImageBufferAlphaChannelModeKey,
                        kCVImageBufferAlphaChannelMode_PremultipliedAlpha,
                        .shouldPropagate
                    )
                }
                try draw(
                    image,
                    into: pixelBuffer,
                    size: plan.outputSize,
                    transparent: plan.transparent,
                    backgroundColor: plan.backgroundColor
                )

                let presentationTime = CMTime(
                    value: CMTimeValue(frameIndex),
                    timescale: CMTimeScale(plan.framesPerSecond)
                )
                guard adaptor.append(pixelBuffer, withPresentationTime: presentationTime) else {
                    throw AnimationExportError.frameAppendFailed(
                        frameIndex,
                        writer.error?.localizedDescription ?? "AVAssetWriter rejected the frame."
                    )
                }
                progress(Double(frameIndex + 1) / Double(plan.frameCount))
                await Task.yield()
            }

            input.markAsFinished()
            await withCheckedContinuation { continuation in
                writer.finishWriting {
                    continuation.resume()
                }
            }
            guard writer.status == .completed else {
                throw AnimationExportError.writerFinishFailed(
                    writer.error?.localizedDescription ?? "Unknown AVAssetWriter error."
                )
            }
            if plan.transparent {
                try await verifyAlphaVideo(at: outputURL)
            }
        } catch {
            writer.cancelWriting()
            throw error
        }
    }

    private func verifyAlphaVideo(at url: URL) async throws {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard let track = tracks.first else {
            throw AnimationExportError.alphaEncodingUnavailable
        }
        let descriptions = try await track.load(.formatDescriptions)
        guard let description = descriptions.first,
              CMFormatDescriptionGetMediaSubType(description)
                == kCMVideoCodecType_HEVCWithAlpha else {
            throw AnimationExportError.alphaEncodingUnavailable
        }
    }

    private func makeRenderer(
        for request: AnimationExportRequest
    ) throws -> AnimationFrameRenderer {
        try AnimationFrameRenderer(
            animationData: request.animationData,
            runtime: request.runtime,
            size: request.plan.outputSize,
            transparent: request.plan.transparent,
            backgroundColor: request.plan.backgroundColor,
            assetBaseURL: request.assetBaseURL
        )
    }

    private func draw(
        _ image: CGImage,
        into pixelBuffer: CVPixelBuffer,
        size: CGSize,
        transparent: Bool,
        backgroundColor: RGBAColor
    ) throws {
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            throw AnimationExportError.pixelBufferContextFailed
        }
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo.byteOrder32Little.rawValue
            | CGImageAlphaInfo.premultipliedFirst.rawValue
        guard let context = CGContext(
            data: baseAddress,
            width: Int(size.width),
            height: Int(size.height),
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            throw AnimationExportError.pixelBufferContextFailed
        }

        context.clear(CGRect(origin: .zero, size: size))
        if !transparent {
            context.setFillColor(UIColor(backgroundColor).cgColor)
            context.fill(CGRect(origin: .zero, size: size))
        }
        context.translateBy(x: 0, y: size.height)
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: CGRect(origin: .zero, size: size))
    }

    private static func outputURL(
        for format: AnimationExportFormat,
        preferredFileName: String?
    ) -> URL {
        let baseName = sanitizedFileName(preferredFileName) ?? "Flippie"
        let uniqueSuffix = UUID().uuidString.prefix(8)
        return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("\(baseName)-\(uniqueSuffix).\(format.fileExtension)")
    }

    private static func sanitizedFileName(_ name: String?) -> String? {
        guard let name else { return nil }
        let invalidCharacters = CharacterSet(charactersIn: "/\\?%*|\"<>:")
            .union(.newlines)
            .union(.controlCharacters)
        let cleaned = name
            .components(separatedBy: invalidCharacters)
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : cleaned
    }
}

private extension UIColor {
    convenience init(_ color: RGBAColor) {
        self.init(
            red: color.red,
            green: color.green,
            blue: color.blue,
            alpha: color.alpha
        )
    }
}
