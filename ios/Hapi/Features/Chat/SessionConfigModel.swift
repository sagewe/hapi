import HapiClient
import HapiProtocol
import Observation

/// App-only selection state. The interactor remains the source of
/// truth, including optimistic updates, capability gates and server reloads.
@MainActor @Observable
final class SessionConfigModel {
    enum QuotaLoadState: Equatable {
        case idle
        case disabled
        case loading
        case loaded(UsageQueryResult)
        case failed(String)
    }

    let interactor: ChatInteractor
    let api: APIClient?
    var machineId: String?
    private(set) var quotaState: QuotaLoadState = .idle

    init(interactor: ChatInteractor, api: APIClient? = nil, machineId: String? = nil) {
        self.interactor = interactor
        self.api = api
        self.machineId = machineId
    }

    var config: SessionConfigState { interactor.config }
    var isApplying: Bool { interactor.configOpPending }
    var modelLoadFailed: Bool { config.modelLoadFailed }
    var showsModel: Bool { config.modelOptions != nil || config.modelOptionsLoading }
    var showsEffort: Bool { config.effortOptions?.isEmpty == false }
    var showsCollaborationMode: Bool { config.flavor == "codex" }
    var quotaAgent: UsageQueryAgent? { UsageQueryAgent.from(flavor: config.flavor) }
    var showsQuota: Bool { api != nil && machineId != nil && quotaAgent != nil }
    var hasSettings: Bool { !config.permissionModes.isEmpty || showsModel || showsEffort || showsCollaborationMode }

    var canDiscoverModels: Bool {
        guard config.active, let raw = config.flavor else { return false }
        let agent = AgentFlavor(rawValue: raw)
        guard AgentModelCatalog.scope(for: agent) != nil else { return false }
        if agent == .agy && machineId == nil { return false }
        if config.controlledByUser && (agent == .grok || agent == .copilot) { return false }
        return true
    }

    var showsComposerModelMenu: Bool {
        showsModel || showsEffort || canDiscoverModels
    }

    var showsComposerPermissionMenu: Bool {
        !config.permissionModes.isEmpty || showsCollaborationMode
    }

    var currentEffortLabel: String {
        effortOptions.first { $0.value == currentEffort }?.label ?? "Default"
    }

    var modelSummaryValue: String {
        if showsEffort {
            return "\(modelLabel) · \(currentEffortLabel)"
        }
        return modelLabel
    }

    var modelSummaryHelp: String {
        if showsEffort {
            return String(localized: "Model: \(modelLabel) · Effort: \(currentEffortLabel)")
        }
        return String(localized: "Model: \(modelLabel)")
    }

    var permissionSummaryValue: String {
        if showsCollaborationMode, collaborationMode != .default {
            return "\(permission.label) · \(collaborationMode.label)"
        }
        return permission.label
    }

    var permissionSummaryHelp: String {
        if showsCollaborationMode {
            return String(localized: "Permission: \(permission.label) · Collaboration: \(collaborationMode.label)")
        }
        return String(localized: "Permission: \(permission.label)")
    }

    var quotaPeakUsedPercent: Int? {
        guard case .loaded(let result) = quotaState else { return nil }
        var values: [Int] = []
        if let five = result.fiveHour?.usedPercentInt { values.append(five) }
        if let seven = result.sevenDay?.usedPercentInt { values.append(seven) }
        for group in result.groups ?? [] {
            if let five = group.fiveHour?.usedPercentInt { values.append(five) }
            if let seven = group.sevenDay?.usedPercentInt { values.append(seven) }
        }
        return values.max()
    }

    var permission: PermissionMode { config.permissionMode ?? .default }
    var collaborationMode: CodexCollaborationMode { config.collaborationMode ?? .default }

    var currentModel: String? {
        if config.flavor == "claude" {
            return ModelCatalog.normalizeClaudeModel(config.model)
        }
        if config.flavor == "codex", config.model == nil,
           case .loaded(let models) = interactor.codexModels {
            return models.first(where: \.isDefault)?.id
        }
        return config.model
    }

    var modelLabel: String {
        config.modelOptions?.first { $0.value == currentModel }?.label
            ?? currentModel ?? "Default"
    }

    /// Give the menu a read-only matching tag, even when Codex has neither an
    /// explicit selection nor a catalog default. Never imply its first model.
    var unlistedModelOption: CatalogOption? {
        guard config.modelOptions?.contains(where: { $0.value == currentModel }) != true else { return nil }
        return CatalogOption(value: currentModel, label: modelLabel)
    }

    var currentEffort: String? {
        config.flavor == "claude" ? ModelCatalog.normalizeClaudeEffort(config.effort) : config.effort
    }

    /// An obsolete effort can arrive via SSE or remain after a model switch.
    /// Give Picker a matching, read-only tag without offering unsupported edits.
    var effortOptions: [CatalogOption] {
        guard var options = config.effortOptions, !options.isEmpty else { return [] }
        if !options.contains(where: { $0.value == currentEffort }) {
            options.insert(CatalogOption(value: currentEffort, label: currentEffort ?? "Default"), at: 0)
        }
        return options
    }

    func canSelectEffort(_ value: String?) -> Bool {
        config.effortOptions?.contains(where: { $0.value == value }) == true
    }

    func selectPermission(_ mode: PermissionMode) {
        guard !isApplying, config.permissionModes.contains(where: { $0.mode == mode }) else { return }
        if mode != permission { interactor.setPermissionMode(mode) }
    }

    func selectModel(_ value: String?) {
        guard !isApplying, config.modelOptions?.contains(where: { $0.value == value }) == true else { return }
        if value != currentModel { interactor.setModel(value) }
    }

    func selectCollaborationMode(_ mode: CodexCollaborationMode) {
        guard !isApplying, config.canChangeCollaborationMode, mode != collaborationMode else { return }
        interactor.setCollaborationMode(mode)
    }

    func selectEffort(_ value: String?) {
        guard !isApplying, value != currentEffort, canSelectEffort(value) else { return }
        interactor.setEffort(value)
    }

    func loadModels() {
        interactor.loadModelOptions()
    }

    func loadQuota(force: Bool = false) {
        guard let api, let machineId, let agent = quotaAgent else { return }
        if case .loading = quotaState { return }
        if !force, case .loaded = quotaState { return }
        quotaState = .loading
        Task {
            do {
                if !force {
                    let settings = try await api.machineUsageQuerySettings(machineId: machineId, agent: agent)
                    if !settings.enabled {
                        quotaState = .disabled
                        return
                    }
                }
                let result = try await api.queryMachineUsage(machineId: machineId, agent: agent, force: force)
                quotaState = .loaded(result)
            } catch is CancellationError {
                // Dismissed mid-flight
            } catch {
                quotaState = .failed(error.localizedDescription)
            }
        }
    }
}
