import PodcastModels
import ContentFiltering
import Foundation

/// Private Application Support files; callers must authorize content before retrieving a URL.
public struct OfflineFiles {
    public let directory: URL
    public init(directory: URL) { self.directory = directory }
    public static let audioExtensions: Set<String> = ["audio", "mp3", "m4a", "mp4", "aac", "wav", "aiff", "caf", "flac"]
    public func fileURL(_ id: String, fileExtension: String = "audio") -> URL {
        let ext = Self.audioExtensions.contains(fileExtension) ? fileExtension : "audio"
        return directory.appendingPathComponent(Identity.hash(id) + "." + ext)
    }
    /// AVPlayer needs a recognizable local container extension; generic .audio is not reliable.
    public static func mediaExtension(at url: URL, mimeType: String? = nil, sourceURL: URL? = nil) throws -> String {
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        let bytes = [UInt8](try handle.read(upToCount: 64) ?? Data())
        func text(_ start: Int, _ end: Int) -> String { String(bytes: bytes.dropFirst(start).prefix(end-start), encoding: .ascii) ?? "" }
        if text(0,4) == "RIFF", text(8,12) == "WAVE" { return "wav" }
        if text(4,8) == "ftyp" { return "m4a" }
        if text(0,3) == "ID3" { return "mp3" }
        if text(0,4) == "fLaC" { return "flac" }
        if text(0,4) == "caff" { return "caf" }
        if text(0,4) == "FORM" { return "aiff" }
        if bytes.count > 1, bytes[0] == 0xff, bytes[1] & 0xf6 == 0xf0 { return "aac" }
        if bytes.count > 1, bytes[0] == 0xff, bytes[1] & 0xe0 == 0xe0 { return "mp3" }
        let types = ["audio/mpeg":"mp3", "audio/mp3":"mp3", "audio/mp4":"m4a", "audio/x-m4a":"m4a", "audio/aac":"aac", "audio/wav":"wav", "audio/x-wav":"wav", "audio/flac":"flac", "audio/aiff":"aiff", "audio/x-caf":"caf"]
        if let mimeType, let ext = types[mimeType.lowercased()] { return ext }
        if let ext = sourceURL?.pathExtension.lowercased(), audioExtensions.contains(ext) { return ext }
        return "audio"
    }
    public var usage: Int64 {
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return urls.filter { Self.audioExtensions.contains($0.pathExtension) || $0.pathExtension == "resume" }.reduce(0) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }
    public func install(_ temporaryURL: URL, id: String, storageLimit: Int64, fileExtension: String = "audio") throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let bytes = Int64(try temporaryURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
        guard bytes > 0, bytes <= 1_000_000_000, usage + bytes <= storageLimit else { throw PodcastError.oversized }
        let destination = fileURL(id, fileExtension: fileExtension)
        if FileManager.default.fileExists(atPath: destination.path) { _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporaryURL) }
        else { try FileManager.default.moveItem(at: temporaryURL, to: destination) }
        #if os(iOS)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: destination.path)
        #endif
    }
    public func delete(_ id: String, fileExtension: String = "audio") throws {
        let url = fileURL(id, fileExtension: fileExtension)
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }
}
