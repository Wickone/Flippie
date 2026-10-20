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
        let count = ceil(duration * Double(framesPerSecond))
        guard count.isFinite, count > 0, count <= 18_000 else { return 0 }
        return Int(count)
    }

    var encodedDuration: Double {
        let duration = Double(frameCount) / Double(max(1, framesPerSecond))
        return format == .gif ? (duration * 100).rounded() / 100 : duration
    }

    func sourceProgress(for frameIndex: Int) -> Double {
        AnimationTimeline(startFrame: 0, endFrame: duration * Double(framesPerSecond),
                          frameRate: Double(framesPerSecond))
            .progress(forAbsoluteFrame: Double(frameIndex))
    }

    func presentationTime(for frameIndex: Int) -> CMTime {
        CMTime(value: CMTimeValue(frameIndex), timescale: CMTimeScale(framesPerSecond))
    }

    /// GIF stores delays as integer hundredths. Round accumulated time, not each frame.
    func gifDelay(for frameIndex: Int) -> Double {
        let start = (Double(frameIndex) * 100 / Double(framesPerSecond)).rounded()
        let end = (Double(frameIndex + 1) * 100 / Double(framesPerSecond)).rounded()
        return (end - start) / 100
    }

    func validate() throws {
        if format == .json {
            return
        }
        guard size.width.isFinite, size.height.isFinite,
              size.width > 0, size.height > 0,
              size.width <= 4096, size.height <= 4096 else {
            throw AnimationExportError.invalidSize
        }
        guard framesPerSecond > 0, framesPerSecond <= 120,
              format != .gif || framesPerSecond <= 50 else {
            throw AnimationExportError.invalidFrameRate
        }
        guard duration.isFinite, duration > 0 else {
            throw AnimationExportError.invalidDuration
        }
        guard frameCount > 0,
              Double(outputSize.width * outputSize.height) * Double(frameCount) <= 8_000_000_000 else {
            throw AnimationExportError.workloadTooLarge
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
    case alphaVerificationFailed
    case workloadTooLarge
    case writerTimedOut
    case missingResource(String)

    var errorDescription: String? {
        switch self {
        case .invalidSize:
            "Export dimensions must be between 1 and 4096 pixels."
        case .invalidFrameRate:
            "Use 1–120 fps for video or 1–50 fps for GIF (centisecond delays)."
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
        case .alphaVerificationFailed:
            "The encoded MOV does not advertise an alpha channel. No opaque replacement was saved."
        case .workloadTooLarge:
            "This export exceeds the 18,000-frame or 8-billion-pixel budget. Reduce size, FPS or duration."
        case .writerTimedOut:
            "The video encoder stopped responding. Try a smaller export."
        case .missingResource(let name):
            "Could not embed resource \(name). Repair missing images or outline external fonts before exporting JSON."
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
        try Task.checkCancellation()
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
        format.opaque = false
        format.preferredRange = .standard
        let renderer = UIGraphicsImageRenderer(
            bounds: CGRect(origin: .zero, size: size),
            format: format
        )
        let image = renderer.image { context in
            if !player.drawHierarchy(in: player.bounds, afterScreenUpdates: true) {
                player.layer.render(in: context.cgContext)
            }
        }

        guard let cgImage = image.cgImage else {
            throw AnimationExportError.frameCaptureFailed(frameIndex)
        }
        return composite(image: cgImage)
    }

    func close() {
        player.unload()
        player.removeFromSuperview()
        window.isHidden = true
        window.rootViewController = nil
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
    typealias ProgressHandler = @MainActor (Double) -> Void
    typealias PhaseHandler = @MainActor (AnimationExportPhase) -> Void

    func export(
        request: AnimationExportRequest,
        phase: @escaping PhaseHandler = { _ in },
        progress: @escaping ProgressHandler
    ) async throws -> URL {
        try Task.checkCancellation()
        try request.plan.validate()
        phase(.preparing)
        let outputURL = try Self.outputURL(
            for: request.plan.format,
            preferredFileName: request.preferredFileName
        )

        do {
            switch request.plan.format {
            case .json:
                progress(0.25)
                try Task.checkCancellation()
                try await exportJSON(request: request, to: outputURL)
            case .gif, .mp4, .mov:
                let preparedData = try await prepareRasterData(for: request)
                try Task.checkCancellation()
                let renderer = try AnimationFrameRenderer(
                    animationData: preparedData, runtime: request.runtime,
                    size: request.plan.outputSize, transparent: request.plan.transparent,
                    backgroundColor: request.plan.backgroundColor, assetBaseURL: request.assetBaseURL)
                defer { renderer.close() }
                phase(.rendering)
                if request.plan.format == .gif {
                    try await exportGIF(request: request, renderer: renderer, to: outputURL,
                                        phase: phase, progress: progress)
                } else {
                    try await exportVideo(request: request, renderer: renderer, to: outputURL,
                                          phase: phase, progress: progress)
                }
            }
            try Task.checkCancellation()
            progress(1)
            return outputURL
        } catch {
            ExportFileStore.remove(outputURL)
            throw error
        }
    }

    nonisolated private func exportGIF(
        request: AnimationExportRequest,
        renderer: AnimationFrameRenderer,
        to outputURL: URL,
        phase: @escaping PhaseHandler,
        progress: @escaping ProgressHandler
    ) async throws {
        let plan = request.plan
        guard let destination = CGImageDestinationCreateWithURL(
            outputURL as CFURL,
            UTType.gif.identifier as CFString,
            plan.frameCount,
            nil
        ) else {
            throw AnimationExportError.gifCreationFailed
        }

        CGImageDestinationSetProperties(destination, [
            kCGImagePropertyGIFDictionary: [
                kCGImagePropertyGIFLoopCount: 0
            ]
        ] as CFDictionary)

        for frameIndex in 0..<plan.frameCount {
            try Task.checkCancellation()
            let cgImage = try await renderer.render(
                progress: plan.sourceProgress(for: frameIndex),
                frameIndex: frameIndex
            )
            let frameProperties: [CFString: Any] = [
                kCGImagePropertyGIFDictionary: [
                    kCGImagePropertyGIFDelayTime: plan.gifDelay(for: frameIndex),
                    kCGImagePropertyGIFUnclampedDelayTime: plan.gifDelay(for: frameIndex)
                ]
            ]
            CGImageDestinationAddImage(destination, cgImage, frameProperties as CFDictionary)
            await progress(0.95 * Double(frameIndex + 1) / Double(plan.frameCount))
            await Task.yield()
        }

        await phase(.finalizing)
        try Task.checkCancellation()
        guard CGImageDestinationFinalize(destination) else {
            throw AnimationExportError.gifFinalizationFailed
        }
    }

    nonisolated private func exportVideo(
        request: AnimationExportRequest,
        renderer: AnimationFrameRenderer,
        to outputURL: URL,
        phase: @escaping PhaseHandler,
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
        let transferFunction: String
        if #available(iOS 18.0, *) { transferFunction = AVVideoTransferFunction_IEC_sRGB }
        else { transferFunction = AVVideoTransferFunction_ITU_R_709_2 }
        outputSettings[AVVideoColorPropertiesKey] = [
            AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
            AVVideoTransferFunctionKey: transferFunction,
            AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2
        ]
        if plan.transparent {
            outputSettings[AVVideoCompressionPropertiesKey] = [
                kVTCompressionPropertyKey_AlphaChannelMode as String:
                    kVTAlphaChannelMode_PremultipliedAlpha
            ]
        }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: outputSettings)
        input.expectsMediaDataInRealTime = false
        guard writer.canApply(outputSettings: outputSettings, forMediaType: .video),
              writer.canAdd(input) else {
            if plan.transparent { throw AnimationExportError.alphaEncodingUnavailable }
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
            for frameIndex in 0..<plan.frameCount {
                try Task.checkCancellation()
                try await ExportWriterWait.untilReady(
                    ready: { input.isReadyForMoreMediaData },
                    failure: {
                        writer.status == .writing ? nil : AnimationExportError.frameAppendFailed(
                            frameIndex, writer.error?.localizedDescription ?? "Encoder is no longer writing.")
                    })

                let image = try await renderer.render(
                    progress: plan.sourceProgress(for: frameIndex),
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
                CVBufferSetAttachment(pixelBuffer, kCVImageBufferCGColorSpaceKey,
                    CGColorSpace(name: CGColorSpace.sRGB)!, .shouldPropagate)
                CVBufferSetAttachment(pixelBuffer, kCVImageBufferColorPrimariesKey,
                    kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
                CVBufferSetAttachment(pixelBuffer, kCVImageBufferTransferFunctionKey,
                    kCVImageBufferTransferFunction_sRGB, .shouldPropagate)
                CVBufferSetAttachment(pixelBuffer, kCVImageBufferYCbCrMatrixKey,
                    kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
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

                let presentationTime = plan.presentationTime(for: frameIndex)
                guard adaptor.append(pixelBuffer, withPresentationTime: presentationTime) else {
                    throw AnimationExportError.frameAppendFailed(
                        frameIndex,
                        writer.error?.localizedDescription ?? "AVAssetWriter rejected the frame."
                    )
                }
                await progress(0.95 * Double(frameIndex + 1) / Double(plan.frameCount))
                await Task.yield()
            }

            await phase(.finalizing)
            try Task.checkCancellation()
            writer.endSession(atSourceTime: plan.presentationTime(for: plan.frameCount))
            input.markAsFinished()
            try await ExportVideoFinalization(writer: writer).finish()
            try Task.checkCancellation()
            guard writer.status == .completed else {
                throw AnimationExportError.writerFinishFailed(
                    writer.error?.localizedDescription ?? "Unknown AVAssetWriter error."
                )
            }
            if plan.transparent {
                try await verifyAlphaVideo(at: outputURL)
            }
        } catch {
            if writer.status == .writing { writer.cancelWriting() }
            throw error
        }
    }

    nonisolated private func verifyAlphaVideo(at url: URL) async throws {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaCharacteristic: .containsAlphaChannel)
        guard !tracks.isEmpty else {
            throw AnimationExportError.alphaVerificationFailed
        }
    }

    nonisolated private func draw(
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
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
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
        // Both CGImage rows and the video buffer are top-to-bottom. An extra
        // UIKit-style flip here vertically mirrors the encoded animation.
        context.draw(image, in: CGRect(origin: .zero, size: size))
    }

    private static func outputURL(
        for format: AnimationExportFormat,
        preferredFileName: String?
    ) throws -> URL {
        let baseName = sanitizedFileName(preferredFileName) ?? "Flippie"
        let uniqueSuffix = UUID().uuidString.prefix(8)
        try ExportFileStore.prepare()
        let container = ExportFileStore.directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        return container
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
        var result = ""
        for character in cleaned {
            guard result.utf8.count + String(character).utf8.count <= 120 else { break }
            result.append(character)
        }
        return result.isEmpty ? nil : result
    }

    nonisolated private func exportJSON(request: AnimationExportRequest, to url: URL) async throws {
        let data = try PortableLottieJSON.make(data: request.animationData, baseURL: request.assetBaseURL)
        try Task.checkCancellation()
        try data.write(to: url, options: .atomic)
    }

    nonisolated private func prepareRasterData(for request: AnimationExportRequest) async throws -> Data {
        // SVG snapshots are drawn from a blob and cannot retain relative file:// images.
        // Embed once before constructing either renderer, not on each captured frame.
        try PortableLottieJSON.make(data: request.animationData, baseURL: request.assetBaseURL,
                                   requireSelfContainedFonts: false)
    }
}

enum AnimationExportPhase: String {
    case preparing = "Preparing"
    case rendering = "Rendering"
    case finalizing = "Finalizing"
}

/// One captured frame is awaited, encoded, then released before capturing the next.
/// The nonisolated async encoder runs on the cooperative executor, not MainActor.
enum ExportWriterWait {
    static func untilReady(timeout: Duration = .seconds(10),
                           ready: () -> Bool, failure: () -> Error?) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while true {
            try Task.checkCancellation()
            if let error = failure() { throw error }
            if ready() { return }
            guard ContinuousClock.now < deadline else { throw AnimationExportError.writerTimedOut }
            try await Task.sleep(for: .milliseconds(2))
        }
    }
}

/// Unlike a task group, this does not wait indefinitely for an uncooperative callback.
/// Starting/cancelling the writer is serialized; the continuation resumes exactly once.
enum ExportFinishWait {
    static func run(timeout: Duration = .seconds(30),
                    start: @escaping @Sendable (@escaping @Sendable () -> Void) -> Void,
                    cancel: @escaping @Sendable () -> Void) async throws {
        let state = ExportFinishState()
        let queue = DispatchQueue(label: "com.flippie.export.finalize")
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                state.install(continuation)
                queue.async {
                    guard state.pending else { return }
                    start { state.resolve(.success(())) }
                }
                let timer = Task.detached {
                    do { try await Task.sleep(for: timeout) } catch { return }
                    queue.async {
                        guard state.pending else { return }
                        state.resolve(.failure(AnimationExportError.writerTimedOut), beforeResume: cancel)
                    }
                }
                state.setTimer(timer)
            }
        } onCancel: {
            queue.async {
                guard state.pending else { return }
                state.resolve(.failure(CancellationError()), beforeResume: cancel)
            }
        }
    }
}

/// Exclusive handoff: the encoding loop does not touch its writer while this
/// finalizer owns it. Start and cancellation execute only on ExportFinishWait's
/// serial queue; its callback touches the locked continuation state, not writer.
private final class ExportVideoFinalization: @unchecked Sendable {
    private let writer: AVAssetWriter
    init(writer: AVAssetWriter) { self.writer = writer }
    func finish() async throws {
        try await ExportFinishWait.run(start: { [self] completion in
            writer.finishWriting(completionHandler: completion)
        }, cancel: { [self] in writer.cancelWriting() })
    }
}

private final class ExportFinishState: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<Void, Error>?
    private var continuation: CheckedContinuation<Void, Error>?
    private var timer: Task<Void, Never>?

    var pending: Bool { lock.lock(); defer { lock.unlock() }; return result == nil }

    func install(_ continuation: CheckedContinuation<Void, Error>) {
        lock.lock()
        if let result { lock.unlock(); continuation.resume(with: result) }
        else { self.continuation = continuation; lock.unlock() }
    }

    func setTimer(_ timer: Task<Void, Never>) {
        lock.lock()
        if result != nil { lock.unlock(); timer.cancel() }
        else { self.timer = timer; lock.unlock() }
    }

    func resolve(_ result: Result<Void, Error>, beforeResume: () -> Void = {}) {
        lock.lock()
        guard self.result == nil else { lock.unlock(); return }
        self.result = result
        let continuation = self.continuation; self.continuation = nil
        let timer = self.timer; self.timer = nil
        lock.unlock()
        timer?.cancel()
        beforeResume()
        continuation?.resume(with: result)
    }
}

enum PortableLottieJSON {
    static func make(data: Data, baseURL: URL?, requireSelfContainedFonts: Bool = true) throws -> Data {
        try LottieImportService.validate(data)
        guard var root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AnimationDocumentError.invalidRootObject
        }
        if requireSelfContainedFonts { try normalizeFonts(in: &root) }
        var budget = 50 * 1024 * 1024 - data.count
        if var assets = root["assets"] as? [[String: Any]] {
            for index in assets.indices {
                try Task.checkCancellation()
                guard let name = assets[index]["p"] as? String else { continue }
                guard name.hasPrefix("data:") || baseURL != nil else {
                    throw AnimationExportError.missingResource(name)
                }
                let directory = assets[index]["u"] as? String ?? ""
                let resolution = LottieAssetResolver.resolve(name: name, directory: directory,
                    baseURL: baseURL ?? FileManager.default.temporaryDirectory)
                guard let image = resolution.image else { throw AnimationExportError.missingResource(name) }
                if name.hasPrefix("data:") {
                    assets[index]["u"] = ""; assets[index]["e"] = 1
                    continue
                }
                let png = NSMutableData()
                guard let destination = CGImageDestinationCreateWithData(png, UTType.png.identifier as CFString, 1, nil) else {
                    throw AnimationExportError.missingResource(name)
                }
                CGImageDestinationAddImage(destination, image, nil)
                guard CGImageDestinationFinalize(destination) else { throw AnimationExportError.missingResource(name) }
                let embedded = "data:image/png;base64," + (png as Data).base64EncodedString()
                guard embedded.utf8.count <= budget else { throw AnimationExportError.workloadTooLarge }
                budget -= embedded.utf8.count
                assets[index]["p"] = embedded; assets[index]["u"] = ""; assets[index]["e"] = 1
            }
            root["assets"] = assets
        }
        try Task.checkCancellation()
        let output = try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
        guard output.count <= 50 * 1024 * 1024 else { throw AnimationExportError.workloadTooLarge }
        return output
    }

    private static func normalizeFonts(in root: inout [String: Any]) throws {
        guard var fontContainer = root["fonts"] as? [String: Any],
              var fonts = fontContainer["list"] as? [[String: Any]] else { return }
        var usage: [String: [String]] = [:]
        func collect(_ layers: [[String: Any]]) {
            for layer in layers where (layer["ty"] as? Int) == 5 {
                let text = layer["t"] as? [String: Any]
                let document = text?["d"] as? [String: Any]
                for frame in document?["k"] as? [[String: Any]] ?? [] {
                    if let value = frame["s"] as? [String: Any],
                       let font = value["f"] as? String, let text = value["t"] as? String {
                        usage[font, default: []].append(text)
                    }
                }
            }
        }
        collect(root["layers"] as? [[String: Any]] ?? [])
        for asset in root["assets"] as? [[String: Any]] ?? [] {
            collect(asset["layers"] as? [[String: Any]] ?? [])
        }
        let glyphs = root["chars"] as? [[String: Any]] ?? []
        for index in fonts.indices {
            guard let path = fonts[index]["fPath"] as? String,
                  !path.isEmpty, !path.hasPrefix("data:") else { continue }
            let name = fonts[index]["fName"] as? String ?? ""
            let family = fonts[index]["fFamily"] as? String ?? name
            let style = fonts[index]["fStyle"] as? String ?? "Regular"
            let covered = Set(glyphs.compactMap { glyph -> String? in
                guard glyph["fFamily"] as? String == family,
                      glyph["style"] as? String == style,
                      glyph["data"] as? [String: Any] != nil else { return nil }
                return glyph["ch"] as? String
            })
            let texts = usage[name] ?? []
            let complete = texts.allSatisfy { text in
                text.allSatisfy { character in
                    character == "\n" || character == "\r" || character == "\u{3}"
                        || covered.contains(String(character))
                }
            }
            guard complete else { throw AnimationExportError.missingResource(name) }
            // A preloader may fetch even an unused font. Strip the stale URL,
            // but retain all font metrics and actual outlined glyphs.
            fonts[index].removeValue(forKey: "fPath")
            fonts[index]["fOrigin"] = 0
        }
        fontContainer["list"] = fonts; root["fonts"] = fontContainer
    }
}

enum ExportFileStore {
    static var directory: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("FlippieExports", isDirectory: true)
    }

    /// Keep a result through the system share operation; remove on dismissal.
    /// After interrupted sessions, only exports older than 24 hours are swept.
    static func prepare(now: Date = Date()) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for url in try FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey]) {
            if let date = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
               now.timeIntervalSince(date) > 24 * 60 * 60 { remove(url) }
        }
    }

    static func remove(_ url: URL) {
        let parent = url.deletingLastPathComponent().standardizedFileURL
        if parent.deletingLastPathComponent() == directory.standardizedFileURL {
            // ImageIO may leave a hidden sibling file if GIF finalization is cancelled.
            // Each operation owns its whole container, including encoder scratch files.
            try? FileManager.default.removeItem(at: parent)
        } else if parent == directory.standardizedFileURL {
            try? FileManager.default.removeItem(at: url)
        }
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
