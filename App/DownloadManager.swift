import PodcastCore
import Foundation
import Combine
import UIKit

struct DownloadRecord: Codable, Identifiable, Equatable, Sendable {
    enum Status: String, Codable { case downloading, paused, downloaded, failed }
    var id: String
    var episode: Episode
    var status: Status
    var received: Int64 = 0
    var expected: Int64 = 0
    var error: String?
    var fileExtension: String?
    var progress: Double { expected > 0 ? min(1, Double(received) / Double(expected)) : 0 }
}

@MainActor enum BackgroundTransferEvents {
    static var completion: (() -> Void)?
    static func finish() { completion?(); completion = nil }
}
@MainActor final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String, completionHandler: @escaping () -> Void) {
        guard identifier == DownloadManager.sessionID else { completionHandler(); return }
        BackgroundTransferEvents.completion = completionHandler
    }
}

@MainActor final class DownloadManager: NSObject, ObservableObject, URLSessionDownloadDelegate {
    nonisolated static let sessionID = "org.quietcast.family.downloads.v1"
    nonisolated let directory: URL
    nonisolated let sessionIdentifier: String
    @Published private(set) var records: [String: DownloadRecord] = [:]
    @Published private(set) var diskUsage: Int64 = 0
    @Published private(set) var orderedIDs: [String] = []
    @Published private(set) var initializing = true
    private var initializationTask: Task<Void, Never>?
    private var validationTask: Task<Void, Never>?
    private var validatedAt: Date?
    private var transfersRestored = false
    private let writer: DownloadIndexWriter
    private var pendingWrite: Task<Void, Never>?
    private(set) var validationCount = 0
    private var indexRevision: UInt64 = 0
    private(set) var availableDownloadIDs: Set<String> = []
    var storageLimit: Int64 = 3_000_000_000
    var authorize: ((String) -> Bool)?
    var onError: ((String) -> Void)?
    private var tasks: [String: URLSessionDownloadTask] = [:]
    private lazy var session: URLSession = {
        let c = URLSessionConfiguration.background(withIdentifier: sessionIdentifier)
        c.sessionSendsLaunchEvents = true; c.isDiscretionary = false
        c.timeoutIntervalForRequest = 30; c.timeoutIntervalForResource = 86400
        c.httpMaximumConnectionsPerHost = 2
        let queue = OperationQueue(); queue.maxConcurrentOperationCount = 1
        return URLSession(configuration: c, delegate: self, delegateQueue: queue)
    }()
    init(directory: URL, sessionIdentifier: String = DownloadManager.sessionID) {
        self.directory = directory; self.sessionIdentifier = sessionIdentifier
        writer = DownloadIndexWriter(url: directory.appendingPathComponent("manifest.json"))
        super.init()
        let loader = Task.detached(priority: .userInitiated) { DownloadBootstrap.load(directory: directory) }
        initializationTask = Task { [weak self] in
            let value = await loader.value
            guard let self else { return }
            self.records = value.records; self.orderedIDs = value.orderedIDs; self.diskUsage = value.diskUsage
            self.availableDownloadIDs = Set(value.records.values.filter { $0.status == .downloaded }.map(\.id))
            self.validatedAt = Date(); self.initializing = false
            if value.changed { self.persist() }
            if let error = value.error { self.onError?(error) }
        }
    }
    func waitUntilReady() async { await initializationTask?.value }
    func flushPersistence() async { await waitUntilReady(); await pendingWrite?.value }
    /// AppStore installs the live access gate and loaded library before reconnecting background transfers.
    func restoreTransfers() {
        guard !transfersRestored else { return }; transfersRestored = true
        session.getAllTasks { [weak self] all in
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                var changed = false
                for task in all {
                    guard let id = task.taskDescription, let download = task as? URLSessionDownloadTask,
                          self.records[id] != nil, self.authorize?(id) == true else { task.cancel(); continue }
                    self.tasks[id] = download
                }
                for id in self.records.keys where self.records[id]?.status == .downloading && self.tasks[id] == nil { self.records[id]?.status = .paused; changed = true }
                if changed { self.persist() }
            }
        }
    }
    func fileURL(_ id: String) -> URL { OfflineFiles(directory: directory).fileURL(id, fileExtension: records[id]?.fileExtension ?? "audio") }
    private func resumeURL(_ id: String) -> URL { directory.appendingPathComponent(Identity.hash(id) + ".resume") }
    func localURL(_ id: String) -> URL? {
        guard records[id]?.status == .downloaded, FileManager.default.fileExists(atPath: fileURL(id).path) else { return nil }
        return fileURL(id)
    }
    func validateLocalFiles(force: Bool = false) async {
        await waitUntilReady()
        if let validationTask { await validationTask.value; return }
        guard force || Date().timeIntervalSince(validatedAt ?? .distantPast) >= 60 else { return }
        let revision = indexRevision
        let files = records.values.filter { $0.status == .downloaded }.map { ($0.id, fileURL($0.id)) }
        validationCount += 1
        validationTask = Task { [weak self] in
            let missing = await Task.detached(priority: .utility) {
                files.filter { !FileManager.default.fileExists(atPath: $0.1.path) }.map { $0.0 }
            }.value
            guard let self else { return }
            defer { self.validationTask = nil }
            guard revision == self.indexRevision else { return }
            self.validatedAt = Date()
            for id in missing { self.records[id]?.status = .failed; self.records[id]?.error = "下载文件已丢失，请重新下载" }
            if !missing.isEmpty { self.persist() }
        }
        await validationTask?.value
    }
    func start(_ episode: Episode) {
        guard !initializing, authorize?(episode.id) == true, tasks[episode.id] == nil, localURL(episode.id) == nil else { return }
        restoreTransfers()
        guard diskUsage < storageLimit else { onError?("下载空间达到上限，请清理或在设置中调整上限。"); return }
        let task: URLSessionDownloadTask
        if let resume = try? Data(contentsOf: resumeURL(episode.id)) { task = session.downloadTask(withResumeData: resume) }
        else { task = session.downloadTask(with: episode.audioURL) }
        task.taskDescription = episode.id; tasks[episode.id] = task
        records[episode.id] = DownloadRecord(id: episode.id, episode: episode, status: .downloading)
        persist(); task.resume()
    }
    func pause(_ id: String) {
        guard let task = tasks.removeValue(forKey: id) else { return }
        records[id]?.status = .paused; persist()
        task.cancel { [weak self] data in
            DispatchQueue.main.async { [weak self] in
                guard let self, self.records[id]?.status == .paused, let data else { return }
                do { try data.write(to: self.resumeURL(id), options: .atomic) } catch { self.onError?(error.localizedDescription) }
            }
        }
    }
    func cancel(_ id: String) {
        tasks.removeValue(forKey: id)?.cancel()
        records.removeValue(forKey: id)
        try? FileManager.default.removeItem(at: resumeURL(id)); persist()
    }
    func delete(_ id: String) {
        tasks.removeValue(forKey: id)?.cancel()
        do {
            for url in [fileURL(id), resumeURL(id)] where FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
            records.removeValue(forKey: id); recalculate(); persist()
        } catch { onError?("无法删除下载：\(error.localizedDescription)") }
    }
    func cleanup(completedIDs: Set<String>, currentID: String?) {
        for id in Array(records.keys) where completedIDs.contains(id) && id != currentID { delete(id) }
    }
    func revalidate() {
        for id in Array(tasks.keys) where authorize?(id) != true { pause(id) }
        objectWillChange.send()
    }
    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let id = downloadTask.taskDescription else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.tasks[id]?.taskIdentifier == downloadTask.taskIdentifier else { return }
            if totalBytesWritten > 1_000_000_000 || self.diskUsage + totalBytesWritten > self.storageLimit {
                self.pause(id); self.records[id]?.error = "已达到单集 1 GB 或总下载容量上限"; self.persist(); return
            }
            self.records[id]?.received = totalBytesWritten; self.records[id]?.expected = totalBytesExpectedToWrite
        }
    }
    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let id = downloadTask.taskDescription else { return }
        let staging = directory.appendingPathComponent("incoming-" + UUID().uuidString)
        do {
            try FileManager.default.moveItem(at: location, to: staging)
            let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
            let mimeType = downloadTask.response?.mimeType
            DispatchQueue.main.async { [weak self] in self?.finish(id, taskID: downloadTask.taskIdentifier, staging: staging, status: status, mimeType: mimeType) }
        } catch { DispatchQueue.main.async { [weak self] in self?.onError?("下载文件落盘失败：\(error.localizedDescription)") } }
    }
    private func finish(_ id: String, taskID: Int, staging: URL, status: Int, mimeType: String?) {
        defer { try? FileManager.default.removeItem(at: staging) }
        guard records[id]?.status == .downloading, tasks[id] == nil || tasks[id]?.taskIdentifier == taskID else { return }
        tasks.removeValue(forKey: id)
        guard authorize?(id) == true else { records[id]?.status = .paused; persist(); return }
        do {
            guard (200..<300).contains(status) else { throw PodcastError.http(status) }
            let size = Int64(try staging.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
            guard size > 0, size <= 1_000_000_000, diskUsage + size <= storageLimit else { throw PodcastError.oversized }
            let ext = try OfflineFiles.mediaExtension(at: staging, mimeType: mimeType, sourceURL: records[id]?.episode.audioURL)
            try OfflineFiles(directory: directory).install(staging, id: id, storageLimit: storageLimit, fileExtension: ext)
            records[id]?.fileExtension = ext
            records[id]?.status = .downloaded; records[id]?.received = size; records[id]?.expected = size; records[id]?.error = nil
            try? FileManager.default.removeItem(at: resumeURL(id)); recalculate(); persist()
        } catch { records[id]?.status = .failed; records[id]?.error = error.localizedDescription; persist(); onError?(error.localizedDescription) }
    }
    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error, let id = task.taskDescription else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.tasks[id]?.taskIdentifier == task.taskIdentifier else { return }
            self.tasks.removeValue(forKey: id)
            if let data = (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data { try? data.write(to: self.resumeURL(id), options: .atomic) }
            self.records[id]?.status = .failed; self.records[id]?.error = error.localizedDescription; self.persist()
        }
    }
    nonisolated func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        DispatchQueue.main.async { BackgroundTransferEvents.finish() }
    }
    private func recalculate() {
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        diskUsage = urls.filter { OfflineFiles.audioExtensions.contains($0.pathExtension) || $0.pathExtension == "resume" }.reduce(0) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }
    private func persist() {
        availableDownloadIDs = Set(records.values.filter { $0.status == .downloaded }.map(\.id))
        indexRevision &+= 1
        let revision = indexRevision, snapshot = records
        Task { [weak self] in
            let ids = await Task.detached(priority: .utility) {
                snapshot.values.sorted { $0.episode.title.localizedStandardCompare($1.episode.title) == .orderedAscending }.map(\.id)
            }.value
            guard let self, self.indexRevision == revision else { return }
            self.orderedIDs = ids
        }
        let writer = writer
        pendingWrite?.cancel()
        pendingWrite = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 100_000_000) } catch { return }
            do { try await writer.save(snapshot, revision: revision) }
            catch { self?.onError?("下载状态无法保存：\(error.localizedDescription)") }
        }
    }
}

private actor DownloadIndexWriter {
    let url: URL
    var savedRevision: UInt64 = 0
    init(url: URL) { self.url = url }
    func save(_ records: [String: DownloadRecord], revision: UInt64) throws {
        guard revision > savedRevision else { return }
        try JSONEncoder().encode(records).write(to: url, options: .atomic); savedRevision = revision
    }
}

private struct DownloadBootstrap: Sendable {
    var records: [String: DownloadRecord] = [:]
    var orderedIDs: [String] = []
    var diskUsage: Int64 = 0
    var changed = false
    var error: String?
    static func load(directory: URL) -> Self {
        var value = Self()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var flags = URLResourceValues(); flags.isExcludedFromBackup = true
            var dir = directory; try dir.setResourceValues(flags)
            let manifest = directory.appendingPathComponent("manifest.json"), files = OfflineFiles(directory: directory)
            if FileManager.default.fileExists(atPath: manifest.path) { value.records = try JSONDecoder().decode([String: DownloadRecord].self, from: Data(contentsOf: manifest)) }
            for id in value.records.keys where value.records[id]?.status == .downloaded {
                if value.records[id]?.fileExtension == nil {
                    let legacy = files.fileURL(id)
                    if FileManager.default.fileExists(atPath: legacy.path), let ext = try? OfflineFiles.mediaExtension(at: legacy, sourceURL: value.records[id]?.episode.audioURL), ext != "audio" {
                        try FileManager.default.moveItem(at: legacy, to: files.fileURL(id, fileExtension: ext)); value.records[id]?.fileExtension = ext; value.changed = true
                    }
                }
                if !FileManager.default.fileExists(atPath: files.fileURL(id, fileExtension: value.records[id]?.fileExtension ?? "audio").path) {
                    value.records[id]?.status = .failed; value.records[id]?.error = "下载文件已丢失，请重新下载"; value.changed = true
                }
            }
            value.orderedIDs = value.records.values.sorted { $0.episode.title.localizedStandardCompare($1.episode.title) == .orderedAscending }.map(\.id)
            let urls = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])
            value.diskUsage = urls.filter { OfflineFiles.audioExtensions.contains($0.pathExtension) || $0.pathExtension == "resume" }.reduce(0) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        } catch { value.error = "下载索引读取失败：\(error.localizedDescription)" }
        return value
    }
}
