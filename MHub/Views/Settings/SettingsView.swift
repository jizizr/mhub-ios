import MHubKit
import Perception
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var app
    @Environment(PlayerController.self) private var player
    @Environment(\.dismiss) private var dismiss
    @State private var address = ""
    @State private var checking = false
    @State private var serverError: String?
    @State private var cacheSize: Int64 = 0

    private static let cacheLimits: [Int64] = [1 << 30, 2 << 30, 5 << 30, 10 << 30]

    var body: some View {
        WithPerceptionTracking {
            @Perception.Bindable var settings = app.settings
            NavigationStack {
                Form {
                    AccountSection()
                    Section {
                        TextField(Strings.serverPlaceholder, text: $address)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                            .submitLabel(.done)
                            .onSubmit { Task { await saveServer() } }
                        if address != settings.serverAddress {
                            Button(checking ? Strings.connecting : Strings.connect) { Task { await saveServer() } }
                                .disabled(checking)
                        }
                    } header: {
                        Text(Strings.server)
                    } footer: {
                        Text(serverError ?? Strings.serverFooter).foregroundStyle(serverError == nil ? Color.secondary : Color.red)
                    }

                    Section {
                        Picker(Strings.quality, selection: $settings.quality.tracked) {
                            ForEach(Quality.allCases) { Text($0.label).tag($0) }
                        }
                        Toggle(Strings.autoplay, isOn: Binding(get: { player.queue.autoplay }, set: { player.setAutoplay($0) }).tracked)
                    } header: {
                        Text(Strings.playback)
                    } footer: {
                        Text(Strings.qualityFooter)
                    }

                    Section(Strings.search) {
                        Picker(Strings.searchPlatform, selection: $settings.searchPlatform.tracked) {
                            ForEach(app.platforms) { Text($0.label).tag($0.id) }
                        }
                    }

                    LyricsSettingsSection()
                    AppearanceSection()

                    Section(Strings.storage) {
                        LabeledContent(Strings.cacheUsage, value: cacheSize.byteText)
                        Picker(Strings.cacheLimit, selection: $settings.cacheLimit.tracked) {
                            ForEach(Self.cacheLimits, id: \.self) { Text($0.byteText).tag($0) }
                        }
                    }

                    Section(Strings.about) {
                        LabeledContent(Strings.version, value: UpdateManager.currentVersion)
                        Toggle(Strings.autoUpdate, isOn: $settings.autoUpdate.tracked)
                        Button(app.updates.checking ? Strings.checkingUpdate : Strings.checkUpdate) {
                            Task { if let message = await app.updates.checkNow() { app.show(message) } }
                        }
                        .disabled(app.updates.checking)
                        Link(Strings.sourceCode, destination: URL(string: "https://github.com/jizizr/mhub")!)
                        Text(Strings.licenseText).font(.footnote).foregroundStyle(.secondary)
                    }
                }
                .navigationTitle(Strings.settings)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    WithPerceptionTracking {
                        ToolbarItem(placement: .confirmationAction) {
                            Button(Strings.done, systemImage: "checkmark") { dismiss() }
                        }
                    }
                }
                .task {
                    address = app.settings.serverAddress
                    cacheSize = await AudioCache.shared.totalSize()
                }
            }
        }
    }

    private func saveServer() async {
        guard let url = MHubClient.serverURL(from: address) else {
            serverError = APIError.invalidServer.localizedDescription
            return
        }
        checking = true
        defer { checking = false }
        do {
            try await MHubClient(server: url).health()
            app.settings.serverAddress = url.absoluteString
            address = url.absoluteString
            serverError = nil
        } catch {
            serverError = "\(Strings.connectFailed)：\(error.localizedDescription)"
        }
    }
}

/// First launch: connect to a server.
struct ServerSetupView: View {
    @Environment(AppModel.self) private var app
    @State private var address = ""
    @State private var checking = false
    @State private var error: String?

    var body: some View {
        WithPerceptionTracking {
            ZStack {
                LinearGradient(colors: [.pink.opacity(0.55), .purple.opacity(0.45), .blue.opacity(0.4)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                    .ignoresSafeArea()
                VStack(spacing: 22) {
                    Image(systemName: "music.note")
                        .font(.system(size: 44, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 92, height: 92)
                        .glass(.tinted(.pink.opacity(0.4)), in: .rect(cornerRadius: 22))
                    Text(Strings.welcome).font(.largeTitle.bold())
                    Text(Strings.welcomeHint).multilineTextAlignment(.center).foregroundStyle(.secondary)
                    VStack(spacing: 12) {
                        TextField(Strings.serverPlaceholder, text: $address)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                            .submitLabel(.go)
                            .onSubmit { Task { await connect() } }
                            .padding(.horizontal, 18)
                            .frame(height: 52)
                            .background { Capsule().fill(.clear).glass(.regular, in: .capsule) }
                        Button {
                            Task { await connect() }
                        } label: {
                            WithPerceptionTracking {
                                Text(checking ? Strings.connecting : Strings.connect)
                                    .font(.headline)
                                    .frame(maxWidth: .infinity, minHeight: 36)
                            }
                        }
                        .glassButton(prominent: true)
                        .controlSize(.large)
                        .disabled(checking || address.isEmpty)
                        if let error {
                            Text(error).font(.footnote).foregroundStyle(.red).multilineTextAlignment(.center)
                        }
                    }
                    Text(Strings.serverFooter).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                .padding(28)
                .frame(maxWidth: 460)
            }
        }
    }

    private func connect() async {
        guard let url = MHubClient.serverURL(from: address) else {
            error = APIError.invalidServer.localizedDescription
            return
        }
        checking = true
        defer { checking = false }
        do {
            try await MHubClient(server: url).health()
            app.settings.serverAddress = url.absoluteString
        } catch {
            self.error = "\(Strings.connectFailed)：\(error.localizedDescription)"
        }
    }
}
