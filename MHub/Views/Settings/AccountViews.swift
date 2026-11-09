import MHubKit
import SwiftUI

enum AccountForm: String, Identifiable {
    case login, register, recover
    var id: String { rawValue }
    var title: String {
        switch self {
        case .login: Strings.signIn
        case .register: Strings.register
        case .recover: Strings.recoverySignIn
        }
    }
}

/// Settings「账号」: sign-in entries for guests, sync state and sign-out for members.
struct AccountSection: View {
    @Environment(AppModel.self) private var app
    @Environment(\.openURL) private var openURL
    @State private var form: AccountForm?
    @State private var confirmingLogout = false

    var body: some View {
        let account = app.account!
        if account.config.enabled || account.user != nil {
            Section {
                if let user = account.user {
                    LabeledContent {
                        Text(syncText(account))
                    } label: {
                        Label(user.username, systemImage: "person.crop.circle.fill")
                    }
                    Button(Strings.syncNow) { Task { await account.syncNow() } }
                        .disabled(account.sync == .syncing)
                    Button(Strings.signOut, role: .destructive) { confirmingLogout = true }
                } else {
                    Button(Strings.signIn, systemImage: "person.crop.circle") { form = .login }
                    Button(Strings.register, systemImage: "person.badge.plus") {
                        if account.config.registersOnWeb, let url = app.settings.serverURL { openURL(url) } else { form = .register }
                    }
                    Button(Strings.recoverySignIn, systemImage: "key") { form = .recover }
                }
            } header: {
                Text(Strings.account)
            } footer: {
                Text(account.error.map(Strings.syncFailed) ?? (account.user == nil ? Strings.accountFooter : Strings.accountLinkedFooter))
            }
            .sheet(item: $form) { AccountFormView(form: $0) }
            .alert(Strings.signOut, isPresented: $confirmingLogout) {
                Button(Strings.cancel, role: .cancel) {}
                Button(Strings.signOut, role: .destructive) { Task { await account.logout() } }
            } message: {
                Text(account.pending.isEmpty ? Strings.signOutMessage : Strings.signOutPending(account.pending.count))
            }
        }
    }

    private func syncText(_ account: AccountManager) -> String {
        if account.sync == .syncing { return Strings.syncing }
        if !account.pending.isEmpty { return Strings.syncPending(account.pending.count) }
        return account.sync == .offline ? Strings.syncOffline : Strings.synced
    }
}

/// Username and password (or recovery code); registering shows the recovery codes once.
struct AccountFormView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    var form: AccountForm
    @State private var username = ""
    @State private var secret = ""
    @State private var confirm = ""
    @State private var working = false
    @State private var error: String?
    @State private var codes: [String]?

    private var ready: Bool {
        !username.trimmingCharacters(in: .whitespaces).isEmpty && !secret.isEmpty && (form != .register || !confirm.isEmpty)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(Strings.username, text: $username)
                        .textContentType(.username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    if form == .recover {
                        TextField(Strings.recoveryCode, text: $secret)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    } else {
                        SecureField(Strings.password, text: $secret)
                            .textContentType(form == .register ? .newPassword : .password)
                    }
                    if form == .register {
                        SecureField(Strings.confirmPassword, text: $confirm).textContentType(.newPassword)
                    }
                } footer: {
                    if let error {
                        Text(error).foregroundStyle(.red)
                    } else {
                        Text(form == .register ? Strings.registerFooter : Strings.accountFooter)
                    }
                }
            }
            .navigationTitle(form.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(Strings.cancel, systemImage: "xmark") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if working {
                        ProgressView()
                    } else {
                        Button(form.title, systemImage: "checkmark") { Task { await submit() } }
                            .disabled(!ready)
                    }
                }
            }
            .alert(Strings.recoveryCodesTitle, isPresented: Binding(get: { codes != nil }, set: { if !$0 { codes = nil } })) {
                Button(Strings.copy) {
                    UIPasteboard.general.string = codes?.joined(separator: "\n")
                    dismiss()
                }
                Button(Strings.done, role: .cancel) { dismiss() }
            } message: {
                Text(Strings.recoveryCodesMessage + "\n\n" + (codes ?? []).joined(separator: "\n"))
            }
        }
    }

    private func submit() async {
        guard ready, !working else { return }
        if form == .register && secret != confirm {
            error = Strings.passwordMismatch
            return
        }
        working = true
        error = nil
        defer { working = false }
        do {
            switch form {
            case .login:
                try await app.account.login(username: username, password: secret)
                dismiss()
            case .recover:
                try await app.account.recover(username: username, code: secret)
                dismiss()
            case .register:
                codes = try await app.account.register(username: username, password: secret)
            }
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// Settings「歌词」, also shown from the player.
struct LyricsSettingsSection: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var settings = app.settings
        Section {
            Picker(Strings.lyricWordMode, selection: $settings.lyricWordMode) {
                ForEach(LyricWordMode.allCases) { Text($0.label).tag($0) }
            }
            Picker(Strings.lyricScript, selection: $settings.lyricScript) {
                ForEach(LyricScript.allCases) { Text($0.label).tag($0) }
            }
            Toggle(Strings.showTranslation, isOn: $settings.showTranslation)
            Toggle(Strings.showRoman, isOn: $settings.showRoman)
        } header: {
            Text(Strings.lyrics)
        } footer: {
            Text(Strings.lyricWordModeFooter)
        }
    }
}

/// Settings「外观」, also shown from the player.
struct AppearanceSection: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var settings = app.settings
        Section(Strings.appearance) {
            Picker(Strings.appearance, selection: $settings.appearance) {
                ForEach(Appearance.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
        }
    }
}

/// Full player「…」→「歌词与外观…」: the two groups without leaving the song.
struct DisplaySettingsView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                LyricsSettingsSection()
                AppearanceSection()
            }
            .navigationTitle(Strings.displaySettings)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(Strings.done, systemImage: "checkmark") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

/// The account button at the top right of every root page.
struct SettingsToolbarButton: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        Button(Strings.settings, systemImage: "person.crop.circle") { app.showsSettings = true }
    }
}

/// A newer GitHub release (docs/design.md「检查更新」).
struct UpdateAlert: ViewModifier {
    @Environment(AppModel.self) private var app
    @Environment(\.openURL) private var openURL

    func body(content: Content) -> some View {
        let updates = app.updates!
        content.alert(
            Strings.updateAvailable(updates.offer?.id ?? ""),
            isPresented: Binding(get: { updates.offer != nil }, set: { if !$0 { updates.offer = nil } }),
            presenting: updates.offer
        ) { update in
            Button(Strings.later, role: .cancel) { updates.later(update) }
            Button(Strings.download) {
                updates.offer = nil
                openURL(update.page)
            }
        } message: { update in
            Text(UpdateCheck.summary(update.notes))
        }
    }
}
