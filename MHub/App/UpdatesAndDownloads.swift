import Foundation
import MHubKit
import Observation

/// GitHub release check (docs/design.md「检查更新」).
@MainActor @Observable
final class UpdateManager {
    static let repository = "jizizr/mhub-ios"

    /// A newer release to offer; the alert clears it.
    var offer: AvailableUpdate?
    private(set) var checking = false
    private let settings: Settings
    private let defaults = UserDefaults.standard

    init(settings: Settings) { self.settings = settings }

    /// The full tag version from the release build (`MHubVersion`), else the marketing version.
    static var currentVersion: String {
        let info = Bundle.main.infoDictionary
        let full = (info?["MHubVersion"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
        return full.isEmpty ? info?["CFBundleShortVersionString"] as? String ?? "0" : full
    }

    /// At launch: at most once a day, silent on failure, skipped versions stay quiet.
    func checkAutomatically() async {
        guard settings.autoUpdate else { return }
        let last = defaults.double(forKey: "update_checked_at")
        guard Date.now.timeIntervalSince1970 - last > 24 * 3600 else { return }
        guard let update = try? await find(), update.id != defaults.string(forKey: "update_skipped") else { return }
        offer = update
    }

    /// From settings: always asks GitHub; returns a message unless the offer alert shows.
    func checkNow() async -> String? {
        checking = true
        defer { checking = false }
        do {
            guard let update = try await find() else { return Strings.upToDate }
            offer = update
            return nil
        } catch {
            return Strings.updateCheckFailed
        }
    }

    private func find() async throws -> AvailableUpdate? {
        let releases = try await UpdateCheck.fetch(repository: Self.repository)
        defaults.set(Date.now.timeIntervalSince1970, forKey: "update_checked_at")
        return UpdateCheck.newer(releases, current: Self.currentVersion, assetSuffix: ".ipa")
    }

    func later(_ update: AvailableUpdate) {
        defaults.set(update.id, forKey: "update_skipped")
        offer = nil
    }
}

/// Saves songs to the app's Documents folder, which the Files app shows under
/// 「我的 iPhone › MHub」 (docs/design.md「下载」).
@MainActor
final class SongDownloads {
    private var active = Set<String>()
    private unowned let app: AppModel

    init(app: AppModel) { self.app = app }

    func download(_ track: Track) {
        let song = track.chosen
        guard active.insert(song.id).inserted else {
            app.show(Strings.downloadInProgress(song.title))
            return
        }
        app.show(Strings.downloading(song.title))
        Task {
            defer { active.remove(song.id) }
            do {
                guard let client = app.client else { throw APIError.invalidServer }
                let app = self.app
                let policy = RateLimitPolicy.playback { ms in
                    Task { @MainActor in app.show(Strings.serverBusyWait(RateLimit.seconds(ms))) }
                }
                let task = try await client.completedPlayback(song, quality: app.settings.quality, rateLimit: policy)
                guard let request = client.audioRequest(for: task) else { throw APIError.playbackFailed("") }
                let (temporary, response) = try await URLSession.shared.download(for: request)
                let http = response as? HTTPURLResponse
                guard let http, (200..<300).contains(http.statusCode) else {
                    throw APIError.http(status: http?.statusCode ?? 0, detail: "")
                }
                let ext = Self.fileExtension(disposition: http.value(forHTTPHeaderField: "Content-Disposition"),
                                             contentType: http.value(forHTTPHeaderField: "Content-Type") ?? "")
                let target = Self.uniqueURL(Self.fileName(song, ext: ext))
                try FileManager.default.moveItem(at: temporary, to: target)
                app.show(Strings.downloadSaved(song.title))
            } catch is CancellationError {
            } catch {
                app.show(Strings.downloadFailed(error.localizedDescription))
            }
        }
    }

    /// `歌手 - 歌名.ext` without characters file systems reject.
    static func fileName(_ track: Track, ext: String) -> String {
        let base = [track.artist, track.title].filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.joined(separator: " - ")
        let cleaned = (base.isEmpty ? track.sourceID : base)
            .replacingOccurrences(of: #"[\\/:*?"<>|\p{Cc}]"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        return String(cleaned.prefix(150)) + "." + ext
    }

    /// From the server's file name, else the content type.
    static func fileExtension(disposition: String?, contentType: String) -> String {
        if let disposition {
            let name = disposition.firstMatch(of: /filename\*=UTF-8''([^;]+)/.ignoresCase()).map { String($0.1).removingPercentEncoding ?? String($0.1) }
                ?? disposition.firstMatch(of: /filename="?([^";]+)"?/.ignoresCase()).map { String($0.1) }
            if let ext = name.map({ ($0 as NSString).pathExtension.lowercased() }),
               (2...5).contains(ext.count), ext.allSatisfy({ $0.isLetter || $0.isNumber }) {
                return ext
            }
        }
        let type = contentType.split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces).lowercased() } ?? ""
        if type.contains("flac") { return "flac" }
        if type == "audio/mpeg" || type == "audio/mp3" { return "mp3" }
        if type.contains("ogg") { return "ogg" }
        if type.contains("wav") { return "wav" }
        return "m4a"
    }

    private static func uniqueURL(_ name: String) -> URL {
        let folder = URL.documentsDirectory
        var url = folder.appendingPathComponent(name)
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var index = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("\(base) (\(index)).\(ext)")
            index += 1
        }
        return url
    }
}
