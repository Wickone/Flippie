import Foundation

extension FileManager {
    static func documentsDirectory() -> URL {
        let paths = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
        return paths[0]
    }
    
    static func createDirectory(at url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: nil)
    }
    
    static func saveData(_ data: Data, to fileName: String) throws -> URL {
        let url = documentsDirectory().appendingPathComponent(fileName)
        try data.write(to: url)
        return url
    }
    
    static func loadData(from fileName: String) throws -> Data {
        let url = documentsDirectory().appendingPathComponent(fileName)
        return try Data(contentsOf: url)
    }
    
    static func deleteFile(at url: URL) throws {
        try FileManager.default.removeItem(at: url)
    }
    
    static func fileExists(at url: URL) -> Bool {
        return FileManager.default.fileExists(atPath: url.path)
    }
}