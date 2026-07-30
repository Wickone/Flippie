import UIKit
import WebKit

enum LottieWebPlayerError: LocalizedError {
    case runtimeMissing
    case invalidAnimationData
    case loadFailed(String)

    var errorDescription: String? {
        switch self {
        case .runtimeMissing:
            "The bundled lottie-web renderer is missing."
        case .invalidAnimationData:
            "The animation could not be passed to lottie-web."
        case .loadFailed(let message):
            "lottie-web failed to load the animation: \(message)"
        }
    }
}

@MainActor
final class LottieWebPlayerView: UIView, WKNavigationDelegate, WKScriptMessageHandler {
    private let webView: WKWebView
    private let messageProxy: WeakScriptMessageHandler
    private var isReady = false
    private var pendingScripts: [String] = []
    private var readyContinuations: [CheckedContinuation<Void, Error>] = []
    private var snapshotContinuations: [
        String: CheckedContinuation<CGImage, Error>
    ] = [:]
    private(set) var currentProgress = 0.0
    private(set) var currentFrame = 0.0
    private(set) var totalFrames = 0.0

    override init(frame: CGRect) {
        let configuration = WKWebViewConfiguration()
        let controller = WKUserContentController()
        let messageProxy = WeakScriptMessageHandler()
        configuration.userContentController = controller
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        webView = WKWebView(frame: .zero, configuration: configuration)
        self.messageProxy = messageProxy

        super.init(frame: frame)

        messageProxy.delegate = self
        controller.add(messageProxy, name: "flippie")
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

    required init?(coder: NSCoder) {
        nil
    }

    func load(data: Data, baseURL: URL? = nil) throws -> AnimationFrameRange {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LottieWebPlayerError.invalidAnimationData
        }
        guard let runtimeURL = Bundle.main.url(
            forResource: "lottie_svg",
            withExtension: "min.js"
        ) else {
            throw LottieWebPlayerError.runtimeMissing
        }

        let bundledRuntime = try String(contentsOf: runtimeURL, encoding: .utf8)
        // lottie-web maps AE's "Repeat Edge Pixels = Off" to SVG
        // edgeMode="duplicate". That stretches the outer pixels of the
        // filtered layer and can produce a visible rectangular halo.
        // SVG edgeMode="none" correctly fades the blur into transparency.
        let runtime = bundledRuntime.replacingOccurrences(
            of: #"1==this.filterManager.effectElements[2].p.v?"wrap":"duplicate""#,
            with: #"1==this.filterManager.effectElements[2].p.v?"wrap":"none""#
        )
        let encodedAnimation = data.base64EncodedString()
        let startFrame = Self.number(root["ip"])
        let endFrame = Self.number(root["op"])
        let frameRate = Self.number(root["fr"])
        let duration = frameRate > 0 ? (endFrame - startFrame) / frameRate : 0

        isReady = false
        pendingScripts.removeAll()
        currentProgress = 0
        currentFrame = 0
        totalFrames = max(0, endFrame - startFrame)

        webView.loadHTMLString(
            Self.html(runtime: runtime, encodedAnimation: encodedAnimation),
            baseURL: baseURL ?? Bundle.main.bundleURL
        )

        return AnimationFrameRange(
            start: startFrame,
            end: endFrame,
            duration: duration
        )
    }

    func play() {
        runWhenReady("window.flippiePlayer.play();")
    }

    func pause() {
        runWhenReady("window.flippiePlayer.pause();")
    }

    func stop() {
        currentProgress = 0
        currentFrame = 0
        runWhenReady("window.flippiePlayer.goToAndStop(0, true);")
    }

    func setProgress(_ progress: Double) {
        currentProgress = min(max(progress, 0), 1)
        currentFrame = currentProgress * totalFrames
        let script = "window.setLottieProgress(\(currentProgress));"
        runWhenReady(script)
    }

    func setFrame(_ frame: Double) {
        currentFrame = min(max(frame, 0), totalFrames)
        currentProgress = totalFrames > 0 ? currentFrame / totalFrames : 0
        let script = "window.setLottieFrame(\(currentFrame));"
        runWhenReady(script)
    }

    func setSpeed(_ speed: Double) {
        runWhenReady("window.flippiePlayer.setSpeed(\(speed));")
    }

    func setLoopMode(_ mode: PlayerLoopMode) {
        switch mode {
        case .playOnce:
            runWhenReady("window.flippiePlayer.loop=false;")
        case .loop:
            runWhenReady("window.flippiePlayer.loop=true;")
        case .autoReverse:
            // lottie-web has no direct ping-pong mode. Regular looping keeps
            // the fallback deterministic until a custom segment driver is added.
            runWhenReady("window.flippiePlayer.loop=true;")
        }
    }

    func prepareFrame(progress: Double) async throws {
        try await waitUntilReady()
        currentProgress = min(max(progress, 0), 1)
        currentFrame = currentProgress * totalFrames
        _ = try await webView.evaluateJavaScript(
            "window.setLottieProgress(\(currentProgress));"
        )
        try await Task.sleep(nanoseconds: 100_000_000)
    }

    func snapshotCGImage(size: CGSize) async throws -> CGImage {
        try await waitUntilReady()
        let requestID = UUID().uuidString
        return try await withCheckedThrowingContinuation { continuation in
            snapshotContinuations[requestID] = continuation
            webView.evaluateJavaScript(
                "window.captureLottieSnapshot('\(requestID)', \(Int(size.width)), \(Int(size.height)));"
            ) { [weak self] _, error in
                guard let error,
                      let continuation = self?.snapshotContinuations.removeValue(
                        forKey: requestID
                      ) else { return }
                continuation.resume(throwing: error)
            }
        }
    }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard let body = message.body as? [String: Any],
              let type = body["type"] as? String else { return }

        switch type {
        case "ready":
            isReady = true
            totalFrames = Self.number(body["totalFrames"])
            let scripts = pendingScripts
            pendingScripts.removeAll()
            for script in scripts {
                webView.evaluateJavaScript(script)
            }
            let continuations = readyContinuations
            readyContinuations.removeAll()
            continuations.forEach { $0.resume() }
        case "frame":
            currentFrame = Self.number(body["frame"])
            currentProgress = totalFrames > 0 ? currentFrame / totalFrames : 0
        case "error":
            let error = LottieWebPlayerError.loadFailed(
                body["message"] as? String ?? "Unknown JavaScript error."
            )
            let continuations = readyContinuations
            readyContinuations.removeAll()
            continuations.forEach { $0.resume(throwing: error) }
        case "snapshot":
            guard let requestID = body["id"] as? String,
                  let continuation = snapshotContinuations.removeValue(
                    forKey: requestID
                  ) else { return }
            do {
                guard let encoded = body["data"] as? String,
                      let comma = encoded.firstIndex(of: ","),
                      let data = Data(
                        base64Encoded: String(encoded[encoded.index(after: comma)...])
                      ),
                      let image = UIImage(data: data)?.cgImage else {
                    throw LottieWebPlayerError.loadFailed(
                        "The browser returned an invalid PNG snapshot."
                    )
                }
                continuation.resume(returning: image)
            } catch {
                continuation.resume(throwing: error)
            }
        case "snapshotError":
            guard let requestID = body["id"] as? String,
                  let continuation = snapshotContinuations.removeValue(
                    forKey: requestID
                  ) else { return }
            continuation.resume(
                throwing: LottieWebPlayerError.loadFailed(
                    body["message"] as? String ?? "SVG rasterization failed."
                )
            )
        default:
            break
        }
    }

    private func runWhenReady(_ script: String) {
        if isReady {
            webView.evaluateJavaScript(script)
        } else {
            pendingScripts.append(script)
        }
    }

    private func waitUntilReady() async throws {
        if isReady { return }
        try await withCheckedThrowingContinuation { continuation in
            readyContinuations.append(continuation)
        }
    }

    private static func html(
        runtime: String,
        encodedAnimation: String
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
            try {
              const animationData = JSON.parse(atob('\(encodedAnimation)'));
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
                player.goToAndStop(frame, true);
                window.normalizeLottieBlurFilters();
                return frame;
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
                  image.onload = function() {
                    const canvas = document.createElement('canvas');
                    canvas.width = width;
                    canvas.height = height;
                    const context = canvas.getContext('2d');
                    context.clearRect(0, 0, width, height);
                    context.drawImage(image, 0, 0, width, height);
                    URL.revokeObjectURL(url);
                    window.webkit.messageHandlers.flippie.postMessage({
                      type: 'snapshot',
                      id: id,
                      data: canvas.toDataURL('image/png')
                    });
                  };
                  image.onerror = function(error) {
                    URL.revokeObjectURL(url);
                    window.webkit.messageHandlers.flippie.postMessage({
                      type: 'snapshotError',
                      id: id,
                      message: String(error)
                    });
                  };
                  image.src = url;
                } catch (error) {
                  window.webkit.messageHandlers.flippie.postMessage({
                    type: 'snapshotError',
                    id: id,
                    message: String(error)
                  });
                }
              };
              player.addEventListener('DOMLoaded', function() {
                player.goToAndStop(0, true);
                window.normalizeLottieBlurFilters();
                window.webkit.messageHandlers.flippie.postMessage({
                  type: 'ready',
                  totalFrames: player.totalFrames
                });
              });
              player.addEventListener('enterFrame', function(event) {
                window.normalizeLottieBlurFilters();
                window.webkit.messageHandlers.flippie.postMessage({
                  type: 'frame',
                  frame: event.currentTime
                });
              });
              player.addEventListener('data_failed', function() {
                window.webkit.messageHandlers.flippie.postMessage({
                  type: 'error',
                  message: 'Animation data failed to load.'
                });
              });
            } catch (error) {
              window.webkit.messageHandlers.flippie.postMessage({
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
