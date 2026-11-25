#if targetEnvironment(macCatalyst)
import HapiClient
import HapiProtocol
import SwiftUI

struct MacComposerSessionControls: View {
    let model: SessionConfigModel
    @Binding var isPresented: Bool
    var isBusy = false
    var notice: String?

    var body: some View {
        HStack(spacing: 4) {
            if model.showsComposerModelMenu || model.showsQuota {
                Button { isPresented = true } label: {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 4) {
                            Text(verbatim: modelLabel)
                            Image(systemName: "chevron.down").imageScale(.small)
                        }.fixedSize()
                        // Keep the model recognizable when its full name and effort do not fit.
                        Text(verbatim: model.modelLabel)
                            .lineLimit(1).truncationMode(.middle)
                            .frame(minWidth: 64, maxWidth: 96, alignment: .leading)
                        Image(systemName: "cpu")
                    }
                }
                .accessibilityLabel("Model")
                .accessibilityValue(Text(verbatim: model.modelSummaryValue))
                .accessibilityIdentifier("chat.composer-controls")
                .help(model.modelSummaryHelp)
                .popover(isPresented: $isPresented, attachmentAnchor: .rect(.bounds), arrowEdge: .bottom) {
                    SessionConfigView(model: model, notice: notice, showsPermissions: false)
                        .frame(idealWidth: 400, maxWidth: 400, idealHeight: 460, maxHeight: 520)
                        .presentationCompactAdaptation(.popover)
                }
            }
            if model.showsComposerPermissionMenu {
                Menu {
                    if !model.config.permissionModes.isEmpty {
                        Picker("Permission mode", selection: Binding(get: { model.permission }, set: model.selectPermission)) {
                            ForEach(model.config.permissionModes, id: \.mode) { option in
                                Text(LocalizedStringKey(option.label)).tag(option.mode)
                            }
                        }
                        .pickerStyle(.inline)
                    }
                    if model.showsCollaborationMode {
                        Picker("Collaboration Mode", selection: Binding(get: { model.collaborationMode }, set: model.selectCollaborationMode)) {
                            ForEach(CodexCollaborationMode.allCases, id: \.self) { mode in
                                Text(LocalizedStringKey(mode.label)).tag(mode)
                            }
                        }
                        .disabled(!model.config.canChangeCollaborationMode)
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: permissionSymbol).foregroundStyle(permissionColor)
                        ViewThatFits(in: .horizontal) {
                            Text(LocalizedStringKey(model.permission.label)).fixedSize()
                            Color.clear.frame(width: 0, height: 1)
                        }
                    }
                }
                .menuStyle(.button)
                .layoutPriority(1)
                .disabled(model.isApplying)
                .accessibilityLabel("Permission mode")
                .accessibilityValue(Text(LocalizedStringKey(model.permission.label)))
                .accessibilityIdentifier("chat.composer-permission")
                .help(model.permissionSummaryHelp)
            }
        }
        .font(.caption)
        .buttonStyle(.plain)
        .frame(height: 32)
        .disabled(isBusy)
    }

    private var modelLabel: String {
        model.showsEffort ? "\(model.modelLabel) · \(model.currentEffortLabel)" : model.modelLabel
    }

    private var permissionSymbol: String {
        switch model.permission.tone {
        case .danger: "exclamationmark.shield.fill"
        case .warning: "exclamationmark.shield"
        default: "shield"
        }
    }

    private var permissionColor: Color {
        switch model.permission.tone {
        case .danger: .red
        case .warning: .orange
        default: .secondary
        }
    }
}
#endif
