import Foundation
import MHubKit

/// Fully downloaded audio files, keyed by `platform:id:quality`. A cached song
/// plays without the network. Least recently played files are evicted first
/// once the size limit is exceeded. Audio cache, playlists and playback state
/// are independent: clearing one never touches the others.
actor AudioCache {
    struct Entry: Codable, Sendable, Identifiable {
        var key: String
        var file: String
        var size: Int64
        var lastUsed: Date
        var track: Track
        var quality: Quality
        var id: String { key }
    }

    static let shared = AudioCache()

    private let folder: URL
    private let indexFile: URL
    private var index: [String: Entry]
    private var limit: Int64 = 2 << 30

    init() {
        let folder = URL.cachesDirectory.appendingPathComponent("Audio", isDirectory: true)
        let indexFile = folder.appendingPathComponent("index.json")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var loaded: [String: Entry] = [:]
        if let data = try? Data(contentsOf: indexFile),
           let saved = try? JSONDecoder().decode([String: Entry].self, from: data) {
            // The system may purge Caches; drop entries whose file is gone.
            loaded = saved.filter { FileManager.default.fileExists(atPath: folder.appendingPathComponent($0.value.file).path) }
        }
        self.folder = folder
        self.indexFile = indexFile
        index = loaded
    }

    func setLimit(_ bytes: Int64) {
        limit = max(bytes, 256 << 20)
        evict()
    }

    func file(for key: String) -> URL? {
        guard var entry = index[key] else { return nil }
        let url = folder.appendingPathComponent(entry.file)
        guard FileManager.default.fileExists(atPath: url.path) else {
            index[key] = nil
            save()
            return nil
        }
        entry.lastUsed = .now
        index[key] = entry
        save()
        return url
    }

    func contains(_ key: String) -> Bool { index[key] != nil }

    /// Moves a completed download into the cache.
    func commit(_ temporary: URL, key: String, fileExtension: String, track: Track, quality: Quality) {
        let name = key.map { $0.isLetter || $0.isNumber ? $0 : "_" }.reduce(into: "") { $0.append($1) }
            + "." + (fileExtension.isEmpty ? "audio" : fileExtension)
        let target = folder.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: target)
        do {
            try FileManager.default.moveItem(at: temporary, to: target)
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            return
        }
        let size = (try? target.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        index[key] = Entry(key: key, file: name, size: size, lastUsed: .now, track: track.chosen, quality: quality)
        evict(keeping: key)
        save()
    }

    func entries() -> [Entry] { index.values.sorted { $0.lastUsed > $1.lastUsed } }

    func totalSize() -> Int64 { index.values.reduce(0) { $0 + $1.size } }

    func remove(_ key: String) {
        guard let entry = index.removeValue(forKey: key) else { return }
        try? FileManager.default.removeItem(at: folder.appendingPathComponent(entry.file))
        save()
    }

    func clear() {
        for entry in index.values { try? FileManager.default.removeItem(at: folder.appendingPathComponent(entry.file)) }
        index = [:]
        save()
    }

    private func evict(keeping keep: String? = nil) {
        var total = totalSize()
        guard total > limit else { return }
        for entry in index.values.sorted(by: { $0.lastUsed < $1.lastUsed }) where entry.key != keep {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(entry.file))
            index[entry.key] = nil
            total -= entry.size
            if total <= limit { break }
        }
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(index) { try? data.write(to: indexFile, options: .atomic) }
    }
}
