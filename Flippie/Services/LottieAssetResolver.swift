import Foundation
import ImageIO

/// Shared by import diagnostics, all native runtimes and the export frame renderer.
enum LottieAssetResolver {
    static let maximumFileSize = 50 * 1024 * 1024
    static let maximumImagePixels = 16_777_216

    struct Resolution {
        let assetID: String?
        let path: String
        let status: LottieImportAssetReport.Status
        let url: URL?
        let candidatePaths: [String]
        let image: CGImage?
    }

    static func resolve(name: String, directory: String, baseURL: URL,
                        assetID: String? = nil) -> Resolution {
        let path = directory.isEmpty ? name : directory + (directory.hasSuffix("/") ? "" : "/") + name
        if name.hasPrefix("data:") {
            let image = embeddedImage(name)
            return Resolution(assetID: assetID, path: "Embedded image data",
                              status: image == nil ? .missing : .embedded,
                              url: nil, candidatePaths: [], image: image)
        }
        if URL(string: name)?.scheme != nil || URL(string: directory)?.scheme != nil {
            return Resolution(assetID: assetID, path: path, status: .remoteUnsupported,
                              url: nil, candidatePaths: [], image: nil)
        }
        let candidates = candidatePaths(name: name, directory: directory)
        for candidate in candidates {
            guard let url = fileURL(candidate, in: baseURL), let image = image(at: url) else { continue }
            return Resolution(assetID: assetID, path: path, status: .resolved,
                              url: url, candidatePaths: candidates, image: image)
        }
        return Resolution(assetID: assetID, path: path, status: .missing,
                          url: nil, candidatePaths: candidates, image: nil)
    }

    static func image(name: String, directory: String, baseURL: URL) -> CGImage? {
        resolve(name: name, directory: directory, baseURL: baseURL).image
    }

    static func image(at url: URL) -> CGImage? {
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
              size.isRegularFile == true, let bytes = size.fileSize, bytes <= maximumFileSize,
              let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return decode(source)
    }

    static func candidatePaths(name: String, directory: String) -> [String] {
        guard safeRelativePath(name) != nil,
              directory.isEmpty || safeRelativePath(directory) != nil else { return [] }
        let paths = [directory.isEmpty ? name : directory + "/" + name,
                     name, "images/" + name, "i/" + name, "assets/" + name]
        var seen = Set<String>()
        return paths.compactMap { path in
            guard let safe = safeRelativePath(path), seen.insert(safe).inserted else { return nil }
            return safe
        }
    }

    static func safeRelativePath(_ path: String) -> String? {
        let path = path.replacingOccurrences(of: "\\", with: "/")
        guard !path.isEmpty, !path.hasPrefix("/"), !path.hasPrefix("~"),
              !path.contains("\0"), URL(string: path)?.scheme == nil else { return nil }
        let components = path.split(separator: "/").map(String.init)
        guard !components.isEmpty, components.allSatisfy({ $0 != "." && $0 != ".." }) else { return nil }
        return components.joined(separator: "/")
    }

    /// Also checks symlink containment; a readable file is not necessarily an owned resource.
    static func fileURL(_ path: String, in baseURL: URL) -> URL? {
        guard let path = safeRelativePath(path) else { return nil }
        let url = baseURL.appendingPathComponent(path)
        let root = baseURL.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        guard url.resolvingSymlinksInPath().standardizedFileURL.path.hasPrefix(root) else { return nil }
        return url
    }

    private static func embeddedImage(_ string: String) -> CGImage? {
        guard let comma = string.firstIndex(of: ",") else { return nil }
        let payload = String(string[string.index(after: comma)...])
        guard payload.utf8.count <= maximumFileSize * 2 else { return nil }
        let data = string[..<comma].contains(";base64")
            ? Data(base64Encoded: payload)
            : payload.removingPercentEncoding?.data(using: .utf8)
        guard let data, data.count <= maximumFileSize,
              let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return decode(source)
    }

    private static func decode(_ source: CGImageSource) -> CGImage? {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.int64Value,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.int64Value,
              width > 0, height > 0, width <= 16384, height <= 16384,
              width * height <= maximumImagePixels else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCache: false] as CFDictionary)
    }
}
