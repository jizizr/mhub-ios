import Foundation
import MHubKit
import Perception
import Security
import UIKit

/// The session token in the keychain (this device only, after first unlock).
final class KeychainSession: SessionStore, @unchecked Sendable {
    private let account = "mhub_session"
    private let lock = NSLock()

    var token: String? {
        get {
            lock.withLock {
                var item: CFTypeRef?
                let status = SecItemCopyMatching(query(returning: true) as CFDictionary, &item)
                guard status == errSecSuccess, let data = item as? Data else { return nil }
                return String(data: data, encoding: .utf8)
            }
        }
        set {
            lock.withLock {
                SecItemDelete(query(returning: false) as CFDictionary)
                guard let newValue, !newValue.isEmpty else { return }
                var attributes = query(returning: false)
                attributes[kSecValueData as String] = Data(newValue.utf8)
                attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
                SecItemAdd(attributes as CFDictionary, nil)
            }
        }
    }

    private func query(returning: Bool) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Bundle.main.bundleIdentifier ?? "MHub",
            kSecAttrAccount as String: account,
        ]
        if returning {
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
        }
        return query
    }
}

/// The signed-in account and its library sync (docs/design.md「账号与歌单同步」).
/// Local playlists stay the source of the UI; edits go to a persisted queue of
/// operations uploaded in batches, and every server snapshot replaces the local
/// library with the still-pending operations replayed on top.
@MainActor @Perceptible
final class AccountManager {
    enum Sync { case idle, syncing, synced, offline }

    private(set) var config = AuthConfig()
    private(set) var user: AccountUser?
    private(set) var sync: Sync = .idle
    private(set) var error: String?
    private(set) var pending: [LibraryOp] = []

    let session = KeychainSession()
    private let library: LibraryStore
    private let client: () -> MHubClient?
    private let defaults = UserDefaults.standard
    private let queueFile = URL.applicationSupportDirectory.appendingPathComponent("pending-ops.json")
    private var flushTask: Task<Void, Never>?
    private var running: Task<Void, Never>?

    init(library: LibraryStore, client: @escaping () -> MHubClient?) {
        self.library = library
        self.client = client
        if session.token != nil, let data = defaults.data(forKey: "account_user") {
            user = try? JSONDecoder().decode(AccountUser.self, from: data)
        }
        if let data = try? Data(contentsOf: queueFile) {
            pending = (try? JSONDecoder().decode([LibraryOp].self, from: data)) ?? []
        }
        library.recorder = { [weak self] ops in self?.enqueue(ops) }
    }

    var device: MHubClient.Device {
        let id = defaults.string(forKey: "device_id") ?? {
            let value = UUID().uuidString.lowercased()
            defaults.set(value, forKey: "device_id")
            return value
        }()
        return MHubClient.Device(id: id, name: "\(UIDevice.current.model) · MHub")
    }

    private var mergePending: Bool {
        get { defaults.bool(forKey: "merge_pending") }
        set { defaults.set(newValue, forKey: "merge_pending") }
    }

    private func setUser(_ value: AccountUser?) {
        user = value
        defaults.set(value.flatMap { try? JSONEncoder().encode($0) }, forKey: "account_user")
    }

    private func saveQueue(_ ops: [LibraryOp]) {
        pending = ops
        if let data = try? JSONEncoder().encode(ops) { try? data.write(to: queueFile, options: .atomic) }
    }

    /// Launch and foreground: learn whether the server has accounts, then sync.
    func refresh() async {
        guard let client = client() else { return }
        if let config = try? await client.authConfig() { self.config = config }
        if user != nil { await syncNow() }
    }

    private func enqueue(_ ops: [LibraryOp]) {
        guard user != nil, !ops.isEmpty else { return }
        saveQueue(pending + ops)
        // Coalesce a burst of edits (a drag, several removals) into one upload.
        flushTask?.cancel()
        flushTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled else { return }
            await self?.syncNow()
        }
    }

    func login(username: String, password: String) async throws {
        try await signIn { try await $0.login(username: username.trimmed, password: password, device: self.device) }
    }

    func recover(username: String, code: String) async throws {
        try await signIn { try await $0.recoveryLogin(username: username.trimmed, code: code.trimmed, device: self.device) }
    }

    /// Returns the recovery codes to show once.
    func register(username: String, password: String) async throws -> [String] {
        var codes: [String] = []
        try await signIn { client in
            let response = try await client.register(username: username.trimmed, password: password, device: self.device)
            codes = response.recoveryCodes
            return response
        }
        return codes
    }

    private func signIn(_ request: (MHubClient) async throws -> LoginResponse) async throws {
        guard let client = client() else { throw APIError.invalidServer }
        let response = try await request(client)
        // Until the local playlists have joined the account, no snapshot may
        // replace them: a failed merge is retried by the next sync instead.
        mergePending = true
        setUser((try? await client.me()) ?? response.user)
        saveQueue([])
        await syncNow()
    }

    /// Upload the queue, then take the server's library (one run at a time).
    func syncNow() async {
        if let running { await running.value }
        let task = Task { await performSync() }
        running = task
        await task.value
        running = nil
    }

    private func performSync() async {
        guard let client = client(), user != nil else { return }
        sync = .syncing
        error = nil
        do {
            if mergePending {
                // First sync after signing in: local playlists join the account like on the web.
                let cloud = try await client.librarySnapshot()
                let ops = LibrarySync.mergeOps(LibrarySync.planMerge(local: library.playlists, cloud: cloud.library))
                var result = cloud
                for start in stride(from: 0, to: ops.count, by: 500) {
                    result = try await client.libraryOps(Array(ops[start..<min(start + 500, ops.count)]))
                }
                library.replaceAll(result.library)
                mergePending = false
                sync = .synced
                return
            }
            var snapshot: LibrarySnapshot?
            while !pending.isEmpty {
                let batch = Array(pending.prefix(500))
                snapshot = try await client.libraryOps(batch)
                // Edits made during the upload stay queued after the batch.
                saveQueue(Array(pending.dropFirst(batch.count)))
            }
            let latest: LibrarySnapshot
            if let snapshot { latest = snapshot } else { latest = try await client.librarySnapshot() }
            library.replaceAll(LibrarySync.apply(latest.library, pending, now: .now))
            sync = pending.isEmpty ? .synced : .idle
        } catch APIError.http(status: 401, _) {
            expire()
        } catch is CancellationError {
            sync = .idle
        } catch {
            sync = .offline
            self.error = error.localizedDescription
        }
    }

    /// The session ended elsewhere (logged out, revoked): back to a local library.
    private func expire() {
        session.token = nil
        mergePending = false
        setUser(nil)
        saveQueue([])
        sync = .idle
        error = nil
    }

    /// Keeps the playlists on this phone as local ones; unsent edits are dropped.
    func logout() async {
        try? await client()?.logout()
        expire()
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
