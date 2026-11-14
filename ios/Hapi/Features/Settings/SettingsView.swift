import HapiClient
import HapiProtocol
import SwiftUI
import UIKit
import UserNotifications

/// Settings-home state (A-M4e): the owner gate for the usage/storage entries
/// and the About hub probe. Appearance/language live in their prefs stores;
/// this model only carries what needs async loading. Android reference:
/// `feature/settings/SettingsViewModel.kt`.
@MainActor @Observable
final class SettingsModel {
    enum HubInfoState {
        case loading
        case loaded(HubHealthResponse)
        case failed(String?)
    }

    /// True when the active hub's JWT namespace is `OwnerGate.ownerNamespace`.
    /// Starts false (fail closed) until the gate resolves.
    private(set) var isOwner = false
    private(set) var hubInfo: HubInfoState = .loading

    var hubUrl: String { session.hubUrl }

    private let session: HubSession
    private var started = false

    init(session: HubSession) {
        self.session = session
    }

    func start() {
        guard !started else { return }
        started = true
        Task { await self.loadOwnerGate() }
        Task { await self.loadHubInfo() }
    }

    func retryHubInfo() {
        hubInfo = .loading
        Task { await self.loadHubInfo() }
    }

    /// Reads the current JWT (loading the persisted one, refreshing when
    /// stale) and peeks its `ns` claim — the Android `currentJwt()` +
    /// `isOwnerNamespace` shape. Any failure leaves the gate closed.
    private func loadOwnerGate() async {
        let jwt = try? await session.authManager.validToken()
        isOwner = OwnerGate.isOwnerNamespace(jwt: jwt)
    }

    private func loadHubInfo() async {
        do {
            hubInfo = .loaded(try await session.api.health())
        } catch is CancellationError {
            // View dismissed mid-flight; nothing to show.
        } catch {
            hubInfo = .failed(error.localizedDescription)
        }
    }
}

/// Settings home (A-M4e), presented as a sheet off the home toolbar: Hubs
/// (switch / add / sign out), Appearance (theme mode), Language (persist-only
/// until M5), the owner-only Usage/Storage entries, and About (app/protocol
/// versions + hub health).
struct SettingsView: View {
    @State private var model: SettingsModel
    @State private var languagePrefs: LanguagePrefs
    @State private var confirmSignOut = false
    @State private var connectionMode: HubConnectionMode = .automatic
    @State private var usingPrivateConnection = false
    @Environment(AppModel.self) private var appModel
    @Environment(ThemePrefs.self) private var themePrefs
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    private let session: HubSession

    init(session: HubSession) {
        _model = State(initialValue: SettingsModel(session: session))
        _languagePrefs = State(initialValue: LanguagePrefs())
        self.session = session
    }

    var body: some View {
        NavigationStack {
            List {
                hubsSection
                if session.api.connection != nil { connectionSection }
                appearanceSection
                #if targetEnvironment(macCatalyst)
                shortcutsSection
                #endif
                languageSection
                notificationsSection
                if model.isOwner {
                    insightsSection
                }
                aboutSection
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
            .task {
                model.start()
                PushCoordinator.shared.refreshStatus()
                while !Task.isCancelled {
                    if let connection = session.api.connection {
                        let status = await connection.status()
                        connectionMode = status.mode; usingPrivateConnection = status.isPrivate
                    }
                    do { try await Task.sleep(for: .seconds(2)) } catch { break }
                }
            }
        }
        // The sheet is its own presentation; re-apply the explicit override
        // so it does not fall back to the system scheme.
        .preferredColorScheme(themePrefs.mode.preferredColorScheme)
    }

    private var connectionSection: some View {
        Section("Connection") {
            Picker("Connection", selection: Binding(get: { connectionMode }, set: { value in
                connectionMode = value
                Task { await session.api.connection?.setMode(value) }
            })) {
                Text("Automatic").tag(HubConnectionMode.automatic)
                Text("Tailscale only").tag(HubConnectionMode.privateOnly)
                Text("Public relay only").tag(HubConnectionMode.publicOnly)
            }
            LabeledContent("Current connection", value: connectionMode == .privateOnly && !usingPrivateConnection
                           ? String(localized: "Unavailable")
                           : usingPrivateConnection ? "Tailscale" : String(localized: "Public relay"))
        }
    }

    // MARK: - Sections

    /// Every action here leaves Settings: switching or signing out replaces
    /// the home screen (it is keyed by hub), and pairing opens from home.
    private var hubsSection: some View {
        Section("Hubs") {
            ForEach(appModel.hubs, id: \.self) { hub in
                let isActive = hub == session.hubUrl
                Button {
                    guard !isActive else { return }
                    dismiss()
                    appModel.switchHub(to: hub)
                } label: {
                    HStack {
                        Text(HubDisplay.host(hub))
                            .foregroundStyle(Color.primary)
                        Spacer()
                        if isActive {
                            Image(systemName: "checkmark")
                                .fontWeight(.semibold)
                        }
                    }
                }
                .accessibilityAddTraits(isActive ? .isSelected : [])
            }
            Button("Add Hub…") {
                // Pairing opens from home, where an incoming bind link can
                // close it to make room for the root confirm sheet.
                dismiss()
                appModel.showAddHub = true
            }
            Button("Sign Out…", role: .destructive) {
                confirmSignOut = true
            }
            .confirmationDialog(
                "Sign out of \(HubDisplay.host(session.hubUrl))?",
                isPresented: $confirmSignOut,
                titleVisibility: .visible
            ) {
                Button("Sign Out", role: .destructive) {
                    dismiss()
                    appModel.signOut(hub: session.hubUrl)
                }
            } message: {
                Text("Removes the stored access token for this hub. Pair again to reconnect.")
            }
        }
    }

    private var appearanceSection: some View {
        Section("Appearance") {
            Picker("Theme", selection: themeBinding) {
                ForEach(ThemeMode.allCases, id: \.self) { mode in
                    Text(mode.label).tag(mode)
                }
            }
        }
    }

    private var shortcutsSection: some View {
        Section("Keyboard") {
            NavigationLink {
                KeyboardShortcutsSettingsView()
            } label: {
                Label("Keyboard Shortcuts", systemImage: "keyboard")
            }
        }
    }

    private var themeBinding: Binding<ThemeMode> {
        Binding(
            get: { themePrefs.mode },
            set: { themePrefs.setMode($0) }
        )
    }

    private var languageSection: some View {
        Section {
            Picker("App language", selection: languageBinding) {
                ForEach(AppLanguage.allCases, id: \.self) { language in
                    Text(Self.pickerLabel(for: language)).tag(language)
                }
            }
        } header: {
            Text("Language")
        } footer: {
            Text("Applies after the app is relaunched.")
        }
    }

    /// Explicit languages show their native names (package data); the
    /// follow-system row is UI copy localized here (the package stays
    /// language-free).
    private static func pickerLabel(for language: AppLanguage) -> String {
        language == .system ? String(localized: "Follow system") : language.displayName
    }

    /// SwiftUI has no supported in-place locale swap without replumbing every
    /// scene, so an explicit pick writes the standard `AppleLanguages`
    /// override (applied by the OS on next launch) and "Follow system"
    /// removes it — the footer says a relaunch is needed.
    private var languageBinding: Binding<AppLanguage> {
        Binding(
            get: { languagePrefs.language },
            set: { language in
                languagePrefs.setLanguage(language)
                switch language {
                case .system:
                    UserDefaults.standard.removeObject(forKey: "AppleLanguages")
                case .english:
                    UserDefaults.standard.set(["en"], forKey: "AppleLanguages")
                case .simplifiedChinese:
                    UserDefaults.standard.set(["zh-Hans"], forKey: "AppleLanguages")
                case .russian:
                    UserDefaults.standard.set(["ru"], forKey: "AppleLanguages")
                }
            }
        )
    }

    /// Push status (P3): permission state, how many paired hubs currently
    /// hold this install's device registration, and a manual re-register
    /// escape hatch (iOS has no background retry queue — the next app start
    /// or token rotation heals registrations too).
    private var notificationsSection: some View {
        let push = PushCoordinator.shared
        return Section {
            LabeledContent("Push notifications", value: permissionLabel(push.authorizationStatus))
            if push.authorizationStatus == .denied {
                Button {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        openURL(url)
                    }
                } label: {
                    Text("Enable in system settings…")
                        .font(.callout)
                }
            } else {
                LabeledContent(
                    "Registered hubs",
                    value: "\(push.registeredHubs.count) / \(push.pairedHubs.count)"
                )
                Button("Re-register push") {
                    PushCoordinator.shared.reregisterAll()
                }
            }
        } header: {
            Text("Notifications")
        } footer: {
            if let problem = push.lastRegistrationProblem {
                Text(problem)
            } else {
                Text("Pushes are end-to-end encrypted; only this device can read them.")
            }
        }
    }

    private func permissionLabel(_ status: UNAuthorizationStatus) -> String {
        switch status {
        case .authorized, .provisional, .ephemeral:
            String(localized: "Enabled")
        case .denied:
            String(localized: "Denied")
        default:
            String(localized: "Not requested")
        }
    }

    /// Owner-only dashboards — hidden unless the JWT namespace is `default`
    /// (the endpoints 403 for everyone else anyway; this just avoids
    /// dead-end rows).
    private var insightsSection: some View {
        Section("Insights") {
            NavigationLink {
                UsageView(api: session.api)
            } label: {
                detailRow(title: "Usage", detail: "Token usage across agents and models")
            }
            NavigationLink {
                UsageQuerySettingsView(api: session.api)
            } label: {
                detailRow(title: "Quota Queries", detail: "5-hour and 7-day subscription quota templates")
            }
            NavigationLink {
                StorageView(api: session.api)
            } label: {
                detailRow(title: "Storage", detail: "Hub database size on disk")
            }
        }
    }

    private var aboutSection: some View {
        Section("About") {
            LabeledContent("App version", value: appVersion)
            if let revision = Bundle.main.object(forInfoDictionaryKey: "HAPISourceRevision") as? String,
               !revision.isEmpty {
                LabeledContent("Source revision", value: revision)
                    .textSelection(.enabled)
            }
            LabeledContent("Protocol version", value: String(ProtocolVersion.supported))
            hubRow
            PrivacyPolicyLink()
        }
    }

    private var hubRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            LabeledContent("Hub", value: HubDisplay.host(model.hubUrl))
            Text(model.hubUrl)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            switch model.hubInfo {
            case .loading:
                Text("Checking hub…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .loaded(let health):
                Text("Status: \(health.status) · protocol v\(health.protocolVersion, specifier: "%lld")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .failed:
                Button {
                    model.retryHubInfo()
                } label: {
                    Text("Hub unreachable — tap to retry.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func detailRow(title: LocalizedStringKey, detail: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var appVersion: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        return "\(short ?? "—") (\(build ?? "—"))"
    }
}

// MARK: - Shared dashboard states

/// Shared owner-gate/error body for both dashboards (usage + storage).
/// 403 means the hub rejected a non-owner namespace — explain, don't retry.
struct DashboardErrorView: View {
    let isForbidden: Bool
    let message: String?
    let onRetry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(isForbidden
                ? String(localized: "This dashboard is only available to the hub owner (default namespace).")
                : String(localized: "Could not load this dashboard."))
                .font(.subheadline)
            if !isForbidden, let message, !message.isEmpty {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if !isForbidden {
                Button("Retry", action: onRetry)
                    .buttonStyle(.borderedProminent)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
    }
}

/// Rounded card container shared by the dashboard screens.
struct DashboardCard<Content: View>: View {
    let title: LocalizedStringKey?
    let content: Content

    init(title: LocalizedStringKey? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let title {
                Text(title)
                    .font(.subheadline.weight(.semibold))
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
    }
}

/// Machine-scoped subscription quota query settings and live template tester.
struct UsageQuerySettingsView: View {
    let api: APIClient

    @State private var machines: [Machine] = []
    @State private var selectedMachineId: String = ""
    @State private var selectedAgent: UsageQueryAgent = .codex
    @State private var isLoading = false
    @State private var isSaving = false
    @State private var isTesting = false
    @State private var enabled = false
    @State private var templateId: String = UsageQueryPresetTemplate.all[0].id
    @State private var template: JSONValue = UsageQueryPresetTemplate.all[0].template
    @State private var credentials: UsageQueryCredentials?
    @State private var testResult: UsageQueryResult?
    @State private var statusMessage: String?
    @State private var errorMessage: String?

    private var onlineMachines: [Machine] {
        machines.filter(\.active)
    }

    var body: some View {
        Form {
            Section("Target") {
                if onlineMachines.isEmpty {
                    Text(isLoading ? "Loading machines…" : "No online machines available.")
                        .foregroundStyle(.secondary)
                } else {
                    Picker("Machine", selection: $selectedMachineId) {
                        ForEach(onlineMachines, id: \.id) { machine in
                            Text(verbatim: machine.metadata?.displayName ?? machine.metadata?.host ?? machine.id)
                                .tag(machine.id)
                        }
                    }
                }
                Picker("Agent", selection: $selectedAgent) {
                    ForEach(UsageQueryAgent.allCases, id: \.self) { agent in
                        Text(verbatim: agent.displayName).tag(agent)
                    }
                }
            }

            if !selectedMachineId.isEmpty {
                Section("Configuration") {
                    Toggle("Enable quota query", isOn: $enabled)
                    if let cred = credentials?.apiKey {
                        LabeledContent(
                            "Credentials",
                            value: cred.configured ? "Configured (\(cred.source))" : "Missing"
                        )
                    }
                    Menu {
                        ForEach(UsageQueryPresetTemplate.all) { preset in
                            Button(preset.name) {
                                templateId = preset.id
                                template = preset.template
                            }
                        }
                    } label: {
                        LabeledContent("Preset Template", value: templateId)
                    }
                }

                Section {
                    Button {
                        Task { await saveSettings() }
                    } label: {
                        if isSaving {
                            ProgressView("Saving…")
                        } else {
                            Label("Save Settings", systemImage: "checkmark.circle")
                        }
                    }
                    .disabled(isSaving || isLoading)

                    Button {
                        Task { await runTest() }
                    } label: {
                        if isTesting {
                            ProgressView("Testing…")
                        } else {
                            Label("Test Quota Query", systemImage: "bolt.horizontal.circle")
                        }
                    }
                    .disabled(isTesting || isLoading)
                }

                if let statusMessage {
                    Section {
                        Text(verbatim: statusMessage)
                            .font(.footnote)
                            .foregroundStyle(.green)
                    }
                }

                if let errorMessage {
                    Section {
                        Text(verbatim: errorMessage)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }

                if let result = testResult {
                    Section("Query Result") {
                        LabeledContent("Status", value: result.status.uppercased())
                        if let plan = result.planType {
                            LabeledContent("Plan", value: plan.uppercased())
                        }
                        if let err = result.error {
                            Text(verbatim: err)
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                        if let groups = result.groups, !groups.isEmpty {
                            ForEach(groups) { group in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(verbatim: group.name)
                                        .font(.caption.weight(.semibold))
                                    windowSummary(label: "5H", window: group.fiveHour)
                                    if group.sevenDay != nil {
                                        windowSummary(label: "7D", window: group.sevenDay)
                                    }
                                }
                            }
                        } else {
                            windowSummary(label: "5H", window: result.fiveHour)
                            windowSummary(label: "7D", window: result.sevenDay)
                        }
                    }
                }
            }
        }
        .navigationTitle("Quota Queries")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await loadMachines()
        }
        .onChange(of: selectedMachineId) {
            Task { await loadSettings() }
        }
        .onChange(of: selectedAgent) {
            Task { await loadSettings() }
        }
    }

    private func windowSummary(label: String, window: UsageQueryWindow?) -> some View {
        HStack {
            Text(verbatim: label)
                .font(.caption.monospaced().weight(.semibold))
            Spacer()
            if let window {
                Text(verbatim: "\(window.usedPercentInt)% used · \(window.remainingPercentInt)% left")
                    .font(.caption.monospacedDigit())
                if window.resetsAt != nil {
                    Text(verbatim: "· ↻ \(window.formatResetCountdown())")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("—")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func loadMachines() async {
        isLoading = true
        defer { isLoading = false }
        do {
            machines = try await api.listMachines()
            if selectedMachineId.isEmpty, let first = onlineMachines.first {
                selectedMachineId = first.id
            } else if !selectedMachineId.isEmpty {
                await loadSettings()
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func loadSettings() async {
        guard !selectedMachineId.isEmpty else { return }
        isLoading = true
        errorMessage = nil
        statusMessage = nil
        testResult = nil
        defer { isLoading = false }
        do {
            let response = try await api.machineUsageQuerySettings(
                machineId: selectedMachineId,
                agent: selectedAgent
            )
            enabled = response.enabled
            templateId = response.templateId
            template = response.template
            credentials = response.credentials
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func saveSettings() async {
        guard !selectedMachineId.isEmpty else { return }
        isSaving = true
        errorMessage = nil
        statusMessage = nil
        defer { isSaving = false }
        do {
            let response = try await api.saveMachineUsageQuerySettings(
                machineId: selectedMachineId,
                agent: selectedAgent,
                enabled: enabled,
                templateId: templateId,
                template: template
            )
            enabled = response.enabled
            templateId = response.templateId
            template = response.template
            credentials = response.credentials
            statusMessage = "Quota settings saved."
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func runTest() async {
        guard !selectedMachineId.isEmpty else { return }
        isTesting = true
        errorMessage = nil
        statusMessage = nil
        defer { isTesting = false }
        do {
            testResult = try await api.testMachineUsageQuery(
                machineId: selectedMachineId,
                agent: selectedAgent,
                template: template
            )
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
