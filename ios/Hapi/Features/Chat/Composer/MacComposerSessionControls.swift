#if targetEnvironment(macCatalyst)
import HapiClient
import SwiftUI

/// One settings entry point, shared with the phone's configuration form.
/// Natural-width variants keep the send action reachable in narrow windows.
struct MacComposerSessionControls: View {
    let model: SessionConfigModel
    @Binding var isPresented: Bool
    var isBusy = false
    var notice: String?

    var body: some View {
        Button { isPresented.toggle() } label: {
            ViewThatFits(in: .horizontal) {
                summary(includingPermission: true)
                summary(includingPermission: false)
                symbols
                    .padding(.horizontal, 6)
                    .frame(height: 32)
            }
        }
        .buttonStyle(.plain)
        .disabled(isBusy)
        .accessibilityLabel("Session controls")
        .accessibilityValue(Text(verbatim: "\(model.modelSummaryValue) · \(model.permissionSummaryValue)"))
        .accessibilityIdentifier("chat.composer-controls")
        .help(model.modelSummaryHelp + "\n" + model.permissionSummaryHelp)
        .popover(isPresented: $isPresented, attachmentAnchor: .rect(.bounds), arrowEdge: .bottom) {
            SessionConfigView(model: model, notice: notice)
                .frame(idealWidth: 400, maxWidth: 400, idealHeight: 520, maxHeight: 520)
                .presentationCompactAdaptation(.popover)
        }
    }

    private func summary(includingPermission: Bool) -> some View {
        HStack(spacing: 6) {
            symbols
            Text(verbatim: model.modelSummaryValue)
                .foregroundStyle(.primary)
            if includingPermission, model.showsComposerPermissionMenu {
                Text(LocalizedStringKey(model.permissionSummaryValue))
                    .foregroundStyle(permissionColor)
            }
            Image(systemName: "chevron.down")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.tertiary)
        }
        .font(.caption)
        .fixedSize(horizontal: true, vertical: false)
        .padding(.horizontal, 6)
        .frame(height: 32)
        .contentShape(Rectangle())
    }

    private var symbols: some View {
        HStack(spacing: 6) {
            ComposerQuotaGaugeIcon(usedPercent: model.quotaPeakUsedPercent, accentColor: quotaColor)
            if model.permission.tone == .danger || model.permission.tone == .warning {
                Image(systemName: "exclamationmark.shield")
                    .foregroundStyle(permissionColor)
            } else if model.showsCollaborationMode, model.collaborationMode != .default {
                Image(systemName: "list.bullet.clipboard")
                    .foregroundStyle(.tint)
            }
        }
        .font(.system(size: 15))
        .fixedSize()
    }

    private var permissionColor: Color {
        switch model.permission.tone {
        case .danger: .red
        case .warning: .orange
        default: .secondary
        }
    }

    private var quotaColor: Color {
        switch model.quotaPeakUsedPercent {
        case let used? where used >= 90: .red
        case let used? where used >= 75: .orange
        default: .secondary
        }
    }
}
#endif
