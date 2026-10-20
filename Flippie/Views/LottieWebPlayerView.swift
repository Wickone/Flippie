import UIKit
import WebKit

enum LottieWebPlayerError: LocalizedError {
    case runtimeMissing
    case invalidAnimationData
    case loadFailed(String)
    case timedOut(String)
    case invalidSnapshotSize

    var errorDescription: String? {
        switch self {
        case .runtimeMissing: "The bundled lottie-web renderer is missing."
        case .invalidAnimationData: "The animation could not be passed to lottie-web."
        case .loadFailed(let message): "lottie-web failed to load the animation: \(message)"
        case .timedOut(let operation): "lottie-web timed out waiting for \(operation)."
        case .invalidSnapshotSize: "The requested snapshot dimensions are unsupported."
        }
    }
}

@MainActor
final class LottieWebPlayerView: UIView, WKNavigationDelegate, WKScriptMessageHandler {
    private enum Readiness { case idle, loading, ready, failed(Error) }
    private enum Kind {
        case ready
        case frame(Double)
        case snapshot(Int, Int)
        var name: String {
            switch self { case .ready: "ready"; case .frame: "frame"; case .snapshot: "snapshot" }
        }
    }
    private enum Reply { case ready, frame, snapshot(CGImage) }
    private struct Request {
        let kind: Kind
        let continuation: CheckedContinuation<Reply, Error>
        let deadline: Task<Void, Never>
    }

    private let webView: WKWebView
    private let messageProxy: WeakScriptMessageHandler
    private var readiness: Readiness = .idle
    private var generation = UUID().uuidString
    private var navigation: WKNavigation?
    private var requests: [String: Request] = [:]
    private var pendingScripts: [String] = []
    private var playbackCompletion: ((Bool) -> Void)?
    private var playbackID: String?
    private(set) var timeline = AnimationTimeline(startFrame: 0, endFrame: 0, frameRate: 0)
    private(set) var currentProgress = 0.0
    private(set) var currentFrame = 0.0
    var totalFrames: Double { timeline.frameCount }
    var pendingRequestCount: Int { requests.count }
    var requestTimeout: Duration = .seconds(10)

    override init(frame: CGRect) {
        let configuration = WKWebViewConfiguration()
        let controller = WKUserContentController()
        let proxy = WeakScriptMessageHandler()
        configuration.userContentController = controller
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        webView = WKWebView(frame: .zero, configuration: configuration)
        messageProxy = proxy
        super.init(frame: frame)
        proxy.delegate = self
        controller.add(proxy, name: "flippie")
        webView.navigationDelegate = self
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.scrollView.isScrollEnabled = false
        webView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(webView)
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: trailingAnchor),
            webView.topAnchor.constraint(equalTo: topAnchor),
            webView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { nil }

    func load(data: Data, baseURL: URL? = nil) throws -> AnimationFrameRange {
        try LottieImportService.validate(data)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LottieWebPlayerError.invalidAnimationData
        }
        guard let runtimeURL = Bundle.main.url(forResource: "lottie_svg", withExtension: "min.js") else {
            throw LottieWebPlayerError.runtimeMissing
        }
        let runtime = try String(contentsOf: runtimeURL, encoding: .utf8).replacingOccurrences(
            of: #"1==this.filterManager.effectElements[2].p.v?"wrap":"duplicate""#,
            with: #"1==this.filterManager.effectElements[2].p.v?"wrap":"none""#
        )
        finishAll(throwing: CancellationError())
        playbackCompletion = nil
        playbackID = nil
        generation = UUID().uuidString
        readiness = .loading
        pendingScripts.removeAll()
        timeline = AnimationTimeline(startFrame: Self.number(root["ip"]),
            endFrame: Self.number(root["op"]), frameRate: Self.number(root["fr"]))
        currentFrame = timeline.startFrame
        currentProgress = 0
        navigation = webView.loadHTMLString(
            Self.html(runtime: runtime, encodedAnimation: data.base64EncodedString(), generation: generation),
            baseURL: baseURL ?? Bundle.main.bundleURL
        )
        return AnimationFrameRange(start: timeline.startFrame, end: timeline.endFrame, duration: timeline.duration)
    }

    func play(completion: ((Bool) -> Void)? = nil) {
        if case .failed = readiness { completion?(false); return }
        let id = UUID().uuidString
        playbackID = id
        playbackCompletion = completion
        runWhenReady("window.playFlippie('\(id)');")
    }

    func pause() {
        playbackCompletion = nil
        playbackID = nil
        runWhenReady("window.flippiePlayer.pause();")
    }

    func stop() {
        playbackCompletion = nil
        playbackID = nil
        setProgress(0)
    }

    func setProgress(_ progress: Double) {
        setFrame(timeline.absoluteFrame(forProgress: progress))
    }

    func setFrame(_ frame: Double) {
        let progress = timeline.progress(forAbsoluteFrame: frame)
        currentFrame = timeline.renderableFrame(forProgress: progress)
        currentProgress = timeline.progress(forAbsoluteFrame: currentFrame)
        let relative = currentFrame - timeline.startFrame
        runWhenReady("window.setLottieFrame(\(relative));")
    }

    func setSpeed(_ speed: Double) {
        guard speed.isFinite, speed >= 0 else { return }
        runWhenReady("window.flippiePlayer.setSpeed(\(speed));")
    }

    func setLoopMode(_ mode: PlayerLoopMode) {
        let value: String
        switch mode { case .playOnce: value = "once"; case .loop: value = "loop"; case .autoReverse: value = "reverse" }
        runWhenReady("window.setFlippieLoopMode('\(value)');")
    }

    func waitForPlaybackReadiness() async throws {
        try Task.checkCancellation()
        let epoch = generation
        switch readiness {
        case .ready: return
        case .failed(let error): throw error
        case .idle: throw LottieWebPlayerError.loadFailed("No animation has been loaded.")
        case .loading:
            _ = try await request(.ready) { _ in }
        }
        try Task.checkCancellation()
        guard generation == epoch else { throw CancellationError() }
        if case .failed(let error) = readiness { throw error }
    }

    func prepareFrame(progress: Double) async throws {
        try await waitForPlaybackReadiness()
        let relative = timeline.renderableFrame(forProgress: progress) - timeline.startFrame
        _ = try await request(.frame(relative)) { id in
            self.evaluate("window.prepareLottieFrame('\(id)', \(relative));", requestID: id)
        }
    }

    func snapshotCGImage(size: CGSize) async throws -> CGImage {
        guard size.width.isFinite, size.height.isFinite,
              size.width >= 1, size.height >= 1,
              size.width <= 16384, size.height <= 16384,
              size.width * size.height <= 67_108_864 else {
            throw LottieWebPlayerError.invalidSnapshotSize
        }
        try await waitForPlaybackReadiness()
        let width = Int(size.width), height = Int(size.height)
        let reply = try await request(.snapshot(width, height)) { id in
            self.evaluate("window.captureLottieSnapshot('\(id)', \(width), \(height));", requestID: id)
        }
        guard case .snapshot(let image) = reply else {
            throw LottieWebPlayerError.loadFailed("Invalid snapshot response.")
        }
        return image
    }

    func invalidate() {
        fail(CancellationError())
        webView.stopLoading()
        webView.evaluateJavaScript("if(window.flippiePlayer){window.flippiePlayer.destroy();}")
    }

    private func request(_ kind: Kind, start: (String) -> Void) async throws -> Reply {
        try Task.checkCancellation()
        if case .failed(let error) = readiness { throw error }
        let id = UUID().uuidString
        let timeout = requestTimeout
        let epoch = generation
        let reply: Reply = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let deadline = Task { @MainActor [weak self] in
                    do { try await Task.sleep(for: timeout) } catch { return }
                    self?.timeout(id)
                }
                requests[id] = Request(kind: kind, continuation: continuation, deadline: deadline)
                if Task.isCancelled { cancel(id); return }
                start(id)
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancel(id) }
        }
        try Task.checkCancellation()
        guard generation == epoch else { throw CancellationError() }
        if case .failed(let error) = readiness { throw error }
        return reply
    }

    private func finish(_ id: String, with result: Result<Reply, Error>) {
        guard let request = requests.removeValue(forKey: id) else { return }
        request.deadline.cancel()
        request.continuation.resume(with: result)
    }

    private func finishAll(throwing error: Error) {
        let pending = requests
        requests.removeAll()
        for request in pending.values {
            request.deadline.cancel()
            request.continuation.resume(throwing: error)
        }
    }

    private func cancel(_ id: String) {
        finish(id, with: .failure(CancellationError()))
        webView.evaluateJavaScript("if(window.cancelFlippieRequest){window.cancelFlippieRequest('\(id)');}")
    }

    private func timeout(_ id: String) {
        guard let request = requests[id] else { return }
        #if DEBUG
        print("WEB TIMEOUT: \(request.kind.name)")
        #endif
        let error = LottieWebPlayerError.timedOut(request.kind.name)
        if case .ready = request.kind {
            fail(error)
        } else {
            finish(id, with: .failure(error))
            webView.evaluateJavaScript("if(window.cancelFlippieRequest){window.cancelFlippieRequest('\(id)');}")
        }
    }

    private func fail(_ error: Error) {
        if case .failed = readiness { return }
        #if DEBUG
        print("WEB FAILURE: \((error as NSError).domain) \((error as NSError).code) \(error)")
        #endif
        readiness = .failed(error)
        // Terminal cleanup cannot go through runWhenReady, which now rejects
        // commands. Also release JS-side work whose Swift deadline is removed.
        webView.evaluateJavaScript("if(window.stopFlippieRenderer){window.stopFlippieRenderer();}")
        pendingScripts.removeAll()
        finishAll(throwing: error)
        let completion = playbackCompletion
        playbackCompletion = nil
        playbackID = nil
        completion?(false)
    }

    private func evaluate(_ script: String, requestID: String? = nil) {
        let epoch = generation
        webView.evaluateJavaScript(script) { [weak self] _, error in
            guard let self, self.generation == epoch, let error else { return }
            if let requestID { self.finish(requestID, with: .failure(error)) }
            else { self.fail(error) }
        }
    }

    private func runWhenReady(_ script: String) {
        switch readiness {
        case .ready: evaluate(script)
        case .loading: pendingScripts.append(script)
        case .idle, .failed: break
        }
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any] else { return }
        receive(body)
    }

    func receive(_ body: [String: Any]) {
        guard body["generation"] as? String == generation,
              let type = body["type"] as? String else { return }
        switch type {
        case "ready":
            guard case .loading = readiness else { return }
            readiness = .ready
            let readyIDs = requests.compactMap { id, request -> String? in
                if case .ready = request.kind { return id }; return nil
            }
            readyIDs.forEach { finish($0, with: .success(.ready)) }
            let scripts = pendingScripts
            pendingScripts.removeAll()
            scripts.forEach { evaluate($0) }
        case "frame":
            guard case .ready = readiness else { return }
            updateRelativeFrame(Self.number(body["frame"]))
        case "frameReady":
            guard let id = body["id"] as? String, let request = requests[id],
                  case .frame(let expected) = request.kind else { return }
            let frame = Self.number(body["frame"])
            guard frame.isFinite, abs(frame - expected) < 0.01 else {
                finish(id, with: .failure(LottieWebPlayerError.loadFailed("The prepared frame did not match its request.")))
                return
            }
            updateRelativeFrame(frame)
            finish(id, with: .success(.frame))
        case "complete":
            guard let playbackID, body["playbackID"] as? String == playbackID else { return }
            currentFrame = timeline.endFrame
            currentProgress = 1
            let completion = playbackCompletion
            playbackCompletion = nil
            self.playbackID = nil
            completion?(true)
        case "error":
            fail(LottieWebPlayerError.loadFailed(body["message"] as? String ?? "Unknown JavaScript error."))
        case "snapshot":
            guard let id = body["id"] as? String, let request = requests[id],
                  case .snapshot(let width, let height) = request.kind else { return }
            guard let encoded = body["data"] as? String,
                  encoded.hasPrefix("data:image/png;base64,"),
                  let comma = encoded.firstIndex(of: ","),
                  let data = Data(base64Encoded: String(encoded[encoded.index(after: comma)...])),
                  let image = UIImage(data: data)?.cgImage, image.width == width, image.height == height else {
                finish(id, with: .failure(LottieWebPlayerError.loadFailed("Invalid PNG snapshot response.")))
                return
            }
            finish(id, with: .success(.snapshot(image)))
        case "snapshotError", "frameError":
            guard let id = body["id"] as? String else { return }
            finish(id, with: .failure(LottieWebPlayerError.loadFailed(body["message"] as? String ?? "Renderer request failed.")))
        default: break
        }
    }

    private func updateRelativeFrame(_ frame: Double) {
        guard frame.isFinite else { return }
        currentFrame = timeline.absoluteFrame(forProgress: totalFrames > 0 ? frame / totalFrames : 0)
        currentProgress = timeline.progress(forAbsoluteFrame: currentFrame)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        if navigation == nil || navigation === self.navigation { fail(error) }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        if navigation == nil || navigation === self.navigation { fail(error) }
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        fail(LottieWebPlayerError.loadFailed("Web renderer process terminated."))
    }

    private static func html(
        runtime: String,
        encodedAnimation: String,
        generation: String
    ) -> String {
        """
        <!doctype html>
        <html>
        <head>
          <meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1">
          <style>
            html,body,#animation{width:100%;height:100%;margin:0;background:transparent;overflow:hidden}
            svg{width:100%!important;height:100%!important;display:block;overflow:visible}
          </style>
        </head>
        <body>
          <div id="animation"></div>
          <script>\(runtime)</script>
          <script>
            window.flippieGeneration = '\(generation)';
            window.postFlippie = function(message) {
              message.generation = '\(generation)';
              window.webkit.messageHandlers.flippie.postMessage(message);
            };
            window.failFlippie = function(message) {
              if (window.flippieFailed) { return; }
              window.flippieFailed = true;
              if (window.stopFlippieRenderer) { window.stopFlippieRenderer(); }
              window.postFlippie({type:'error', message:message});
            };
            window.addEventListener('error', function(event) {
              if (event.message) { window.failFlippie(event.message); }
            });
            window.addEventListener('unhandledrejection', function(event) {
              window.failFlippie(String(event.reason));
            });
            try {
              const bytes = Uint8Array.from(atob('\(encodedAnimation)'), function(c){return c.charCodeAt(0);});
              const animationData = JSON.parse(new TextDecoder('utf-8', {fatal:true}).decode(bytes));
              const player = lottie.loadAnimation({
                container: document.getElementById('animation'),
                renderer: 'svg',
                loop: true,
                autoplay: false,
                animationData: animationData,
                rendererSettings: {
                  preserveAspectRatio: 'xMidYMid meet',
                  filterSize: {
                    x: '-250%',
                    y: '-250%',
                    width: '600%',
                    height: '600%'
                  },
                  progressiveLoad: false
                }
              });
              window.flippiePlayer = player;
              player.addEventListener('error', function(event) {
                const error = event && (event.nativeError || event);
                window.failFlippie(String(error && error.message || 'The lottie-web renderer failed.'));
              });
              window.flippieLoopMode = 'loop';
              window.flippieDirection = 1;
              window.setFlippieLoopMode = function(mode) {
                window.flippieLoopMode = mode;
                player.loop = mode === 'loop';
                if (mode !== 'reverse') {
                  window.flippieDirection = 1;
                  player.setDirection(1);
                }
              };
              window.playFlippie = function(id) {
                window.flippiePlaybackID = id;
                player.setDirection(window.flippieDirection);
                player.play();
              };
              window.normalizeLottieBlurFilters = function(root) {
                const scope = root || document;
                window.promoteMaskedGaussianBlurGroups(scope);
                scope.querySelectorAll('filter').forEach(function(filter) {
                  if (!filter.querySelector('feGaussianBlur')) { return; }
                  filter.setAttribute('filterUnits', 'userSpaceOnUse');
                  filter.setAttribute('x', '-10000');
                  filter.setAttribute('y', '-10000');
                  filter.setAttribute('width', '20000');
                  filter.setAttribute('height', '20000');
                  filter.setAttribute('color-interpolation-filters', 'sRGB');
                });
                scope.querySelectorAll('feGaussianBlur').forEach(function(blur) {
                  blur.setAttribute('edgeMode', 'none');
                });
              };
              window.promoteMaskedGaussianBlurGroups = function(root) {
                const scope = root || document;
                const svgNamespace = 'http://www.w3.org/2000/svg';
                const gaussianFilterIDs = new Set();
                scope.querySelectorAll('filter').forEach(function(filter) {
                  if (filter.id && filter.querySelector('feGaussianBlur')) {
                    gaussianFilterIDs.add(filter.id);
                  }
                });
                if (gaussianFilterIDs.size === 0) { return; }

                scope.querySelectorAll('g[mask]').forEach(function(maskedGroup) {
                  if (maskedGroup.getAttribute('data-flippie-blur-promoted') === 'true') {
                    return;
                  }
                  const children = Array.prototype.slice.call(maskedGroup.children);
                  const filteredChild = children.find(function(child) {
                    const filterReference = child.getAttribute && child.getAttribute('filter');
                    if (!filterReference) { return false; }
                    const match = filterReference.match(/url\\(#([^\\)]+)\\)/);
                    return match && gaussianFilterIDs.has(match[1]);
                  });
                  if (!filteredChild) { return; }

                  const filterReference = filteredChild.getAttribute('filter');
                  const parent = maskedGroup.parentNode;
                  if (!parent) { return; }

                  const wrapper = document.createElementNS(svgNamespace, 'g');
                  wrapper.setAttribute('filter', filterReference);
                  wrapper.setAttribute('data-flippie-blur-wrapper', 'true');
                  parent.insertBefore(wrapper, maskedGroup);
                  filteredChild.removeAttribute('filter');
                  maskedGroup.setAttribute('data-flippie-blur-promoted', 'true');
                  wrapper.appendChild(maskedGroup);
                });
              };
              window.setLottieProgress = function(progress) {
                const frame = Math.max(0, Math.min(player.totalFrames - 0.001, progress * player.totalFrames));
                player.goToAndStop(frame, true);
                window.normalizeLottieBlurFilters();
                return frame;
              };
              window.setLottieFrame = function(frame) {
                frame = Math.max(0, Math.min(player.totalFrames - 0.001, frame));
                window.flippieDirection = 1;
                player.setDirection(1);
                player.goToAndStop(frame, true);
                window.normalizeLottieBlurFilters();
                return frame;
              };
              const frameRequests = new Map();
              const snapshotRequests = new Map();
              window.cancelFlippieRequest = function(id) {
                const listener = frameRequests.get(id);
                if (listener) { player.removeEventListener('drawnFrame', listener); frameRequests.delete(id); }
                const snapshot = snapshotRequests.get(id);
                if (snapshot) {
                  snapshotRequests.delete(id);
                  snapshot.image.onload = null;
                  snapshot.image.onerror = null;
                  snapshot.image.src = '';
                  URL.revokeObjectURL(snapshot.url);
                }
              };
              window.stopFlippieRenderer = function() {
                player.pause();
                Array.from(frameRequests.keys()).forEach(window.cancelFlippieRequest);
                Array.from(snapshotRequests.keys()).forEach(window.cancelFlippieRequest);
              };
              window.prepareLottieFrame = function(id, frame) {
                try {
                  const listener = function(event) {
                    if (window.flippieFailed) { return; }
                    if (Math.abs(event.currentTime - frame) > 0.01) { return; }
                    player.removeEventListener('drawnFrame', listener);
                    frameRequests.delete(id);
                    window.normalizeLottieBlurFilters();
                    window.postFlippie({type:'frameReady', id:id, frame:event.currentTime});
                  };
                  frameRequests.set(id, listener);
                  player.addEventListener('drawnFrame', listener);
                  window.setLottieFrame(frame);
                } catch(error) {
                  window.cancelFlippieRequest(id);
                  window.postFlippie({type:'frameError', id:id, message:String(error)});
                }
              };
              window.captureLottieSnapshot = function(id, width, height) {
                try {
                  const svg = document.querySelector('#animation svg');
                  const clone = svg.cloneNode(true);
                  window.normalizeLottieBlurFilters(clone);
                  clone.setAttribute('width', width);
                  clone.setAttribute('height', height);
                  const source = new XMLSerializer().serializeToString(clone);
                  const blob = new Blob([source], {type: 'image/svg+xml;charset=utf-8'});
                  const url = URL.createObjectURL(blob);
                  const image = new Image();
                  snapshotRequests.set(id, {image:image, url:url});
                  image.onload = function() {
                    if (!snapshotRequests.has(id)) { return; }
                    snapshotRequests.delete(id);
                    try {
                    const canvas = document.createElement('canvas');
                    canvas.width = width;
                    canvas.height = height;
                    const context = canvas.getContext('2d');
                    context.clearRect(0, 0, width, height);
                    context.drawImage(image, 0, 0, width, height);
                    URL.revokeObjectURL(url);
                    window.postFlippie({
                      type: 'snapshot',
                      id: id,
                      data: canvas.toDataURL('image/png')
                    });
                    } catch(error) {
                      URL.revokeObjectURL(url);
                      window.postFlippie({type:'snapshotError', id:id, message:String(error)});
                    }
                  };
                  image.onerror = function(error) {
                    if (!snapshotRequests.has(id)) { return; }
                    snapshotRequests.delete(id);
                    URL.revokeObjectURL(url);
                    window.postFlippie({
                      type: 'snapshotError',
                      id: id,
                      message: String(error)
                    });
                  };
                  image.src = url;
                } catch (error) {
                  window.postFlippie({
                    type: 'snapshotError',
                    id: id,
                    message: String(error)
                  });
                }
              };
              player.addEventListener('DOMLoaded', function() {
                // The default runtime rounds ip and floors op-ip. Its public
                // segment API retains exact fractional source boundaries.
                player.setSegment(animationData.ip, animationData.op);
                player.goToAndStop(0, true);
                window.normalizeLottieBlurFilters();
                window.postFlippie({
                  type: 'ready',
                  totalFrames: player.totalFrames
                });
              });
              player.addEventListener('enterFrame', function(event) {
                window.normalizeLottieBlurFilters();
                window.postFlippie({
                  type: 'frame',
                  frame: event.currentTime
                });
              });
              player.addEventListener('data_failed', function() {
                window.postFlippie({
                  type: 'error',
                  message: 'Animation data failed to load.'
                });
              });
              player.addEventListener('complete', function() {
                if (window.flippieLoopMode === 'reverse') {
                  window.flippieDirection *= -1;
                  player.setDirection(window.flippieDirection);
                  player.play();
                } else {
                  window.postFlippie({type: 'complete', playbackID: window.flippiePlaybackID});
                }
              });
            } catch (error) {
              window.postFlippie({
                type: 'error',
                message: String(error)
              });
            }
          </script>
        </body>
        </html>
        """
    }

    private static func number(_ value: Any?) -> Double {
        (value as? NSNumber)?.doubleValue ?? 0
    }
}

private final class WeakScriptMessageHandler: NSObject, WKScriptMessageHandler {
    weak var delegate: WKScriptMessageHandler?

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        delegate?.userContentController(
            userContentController,
            didReceive: message
        )
    }
}
