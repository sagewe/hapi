import HapiClient
import SwiftUI

/// A compact view of the actual global event connection, not merely the next
/// endpoint selected by policy. All timestamps and latency samples stay explicit.
struct ConnectionCapsuleLabel: View {
    let snapshot: HubConnectionDiagnostics?
    var referenceDate = Date()

    var routeTitle: String {
        snapshot?.activeRoute.map(connectionRouteTitle) ?? String(localized: "Disconnected")
    }
    var latencyTitle: String {
        guard snapshot?.activeEventIsPrivate != nil, let sample = snapshot?.currentMeasurement,
              sample.outcome == .reachable,
              (0...60).contains(referenceDate.timeIntervalSince(sample.checkedAt)) else { return "—" }
        return sample.milliseconds == 0 ? "<1 ms" : "\(sample.milliseconds) ms"
    }

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: snapshot?.activeRoute.map(connectionRouteIcon) ?? "network")
                .font(.caption)
                .frame(width: 16)
            Text(routeTitle).font(.caption.weight(.medium))
            Text(verbatim: latencyTitle)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(minWidth: 42, alignment: .trailing)
                .contentTransition(.numericText())
            Image(systemName: "chevron.down")
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 8)
        .background(Color.primary.opacity(0.055), in: Capsule())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Connection details")
        .accessibilityValue("\(routeTitle) \(latencyTitle)")
    }
}

struct ConnectionCapsule: View {
    let router: HubConnectionRouter
    @State private var snapshot: HubConnectionDiagnostics?
    @State private var expanded = false
    @Environment(\.scenePhase) private var phase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        Button { expanded = true } label: { ConnectionCapsuleLabel(snapshot: snapshot) }
            .buttonStyle(.plain)
            .accessibilityIdentifier("home.connection")
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: snapshot?.activeRoute)
            .popover(isPresented: $expanded) {
                NavigationStack {
                    ConnectionSelectionView(router: router)
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) { Button("Done") { expanded = false } }
                        }
                }
                .frame(idealWidth: 360, idealHeight: 540)
                .presentationDetents(dynamicTypeSize.isAccessibilitySize ? [.large] : [.height(560), .large])
                .presentationDragIndicator(.visible)
                .presentationCompactAdaptation(.sheet)
            }
            .task(id: phase) {
                guard phase == .active else { return }
                while !Task.isCancelled {
                    snapshot = await router.diagnostics()
                    do { try await Task.sleep(for: .seconds(2)) } catch { return }
                }
            }
            .task(id: phase) {
                guard phase == .active else { return }
                while !Task.isCancelled {
                    await router.refreshDiagnostics()
                    do { try await Task.sleep(for: .seconds(15)) } catch { return }
                }
            }
    }
}

func connectionRouteTitle(_ route: HubConnectionRoute) -> String {
    switch route {
    case .lan: String(localized: "Home network")
    case .relay: String(localized: "Public relay")
    case .tailscale: "Tailscale"
    }
}

func connectionRouteIcon(_ route: HubConnectionRoute) -> String {
    switch route { case .lan: "house"; case .relay: "cloud"; case .tailscale: "network" }
}

/// One shared destination from the home status capsule and Settings.
struct ConnectionSelectionView: View {
    let router: HubConnectionRouter
    @State private var snapshot: HubConnectionDiagnostics?
    @State private var changing = false
    @Environment(\.scenePhase) private var phase

    var body: some View {
        ConnectionSelectionContent(router: router, snapshot: snapshot, changing: changing) { mode in
            changing = true
            Task {
                await router.setMode(mode)
                snapshot = await router.diagnostics()
                changing = false
            }
        }
        .task(id: phase) {
            guard phase == .active else { return }
            while !Task.isCancelled {
                snapshot = await router.diagnostics()
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
            }
        }
    }

}

struct ConnectionSelectionContent: View {
    let router: HubConnectionRouter
    let snapshot: HubConnectionDiagnostics?
    var changing = false
    let select: (HubConnectionMode) -> Void

    var body: some View {
        List {
            Section {
                LabeledContent("Current connection", value: snapshot?.activeRoute.map(connectionRouteTitle) ?? String(localized: "Disconnected"))
                if let snapshot, snapshot.activeRoute != snapshot.selectedRoute {
                    LabeledContent("Next connection", value: connectionRouteTitle(snapshot.selectedRoute))
                        .foregroundStyle(.secondary)
                }
            }
            Section {
                option(.automatic, title: String(localized: "Automatic"), icon: "arrow.triangle.branch")
                option(.lanOnly, title: String(localized: "Home network"), icon: "house", available: snapshot?.hasLAN == true)
                option(.publicOnly, title: String(localized: "Public relay"), icon: "cloud")
                option(.privateOnly, title: "Tailscale", icon: "network", available: snapshot?.hasTailscale == true)
            } footer: {
                Text("Automatic uses your home network when available, public relay elsewhere, and Tailscale as a fallback. Manual selection stays on the chosen route.")
            }
            Section {
                NavigationLink("Connection details") { ConnectionDiagnosticsView(router: router) }
            }
        }
        .navigationTitle("Connection")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func option(_ mode: HubConnectionMode, title: String, icon: String, available: Bool = true) -> some View {
        Button {
            select(mode)
        } label: {
            HStack {
                Label(title, systemImage: icon)
                Spacer()
                if !available { Text("Not configured").font(.caption).foregroundStyle(.secondary) }
                if snapshot?.mode == mode { Image(systemName: "checkmark").foregroundStyle(.tint) }
            }
            .contentShape(Rectangle())
        }
        .foregroundStyle(.primary)
        .disabled(changing || !available || snapshot == nil)
        .accessibilityAddTraits(snapshot?.mode == mode ? .isSelected : [])
        .accessibilityIdentifier("connection.mode.\(mode.rawValue)")
    }
}

struct ConnectionDiagnosticsView: View {
    let router: HubConnectionRouter
    @State private var snapshot: HubConnectionDiagnostics?
    @State private var measuring = false
    @Environment(\.scenePhase) private var phase

    var body: some View {
        List {
            if let snapshot {
                Section {
                    LabeledContent("Current connection", value: activeTitle(snapshot))
                    if snapshot.activeRoute != snapshot.selectedRoute {
                        LabeledContent("Next connection", value: connectionRouteTitle(snapshot.selectedRoute))
                    }
                    Text(reasonTitle(snapshot.reason)).font(.footnote).foregroundStyle(.secondary)
                    if let date = snapshot.reasonUpdatedAt {
                        HStack { Text("Updated"); Spacer(); Text(date, style: .relative) }
                            .font(.caption).foregroundStyle(.tertiary)
                    }
                }
                Section("Home network") { EndpointMeasurementRows(sample: snapshot.lanMeasurement) }
                Section("Tailscale") { EndpointMeasurementRows(sample: snapshot.privateMeasurement) }
                Section("Public relay") { EndpointMeasurementRows(sample: snapshot.publicMeasurement) }
            }
            Section {
                Button {
                    Task { await refresh(force: true) }
                } label: {
                    HStack { Text("Measure now"); Spacer(); if measuring { ProgressView().controlSize(.small) } }
                }
                .disabled(measuring)
            } footer: {
                Text("HTTP round-trip time may include DNS, TLS and Hub processing. It is not ping or upload speed. Measurements do not force a route switch.")
            }
        }
        .navigationTitle("Connection details")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: phase) {
            guard phase == .active else { return }
            snapshot = await router.diagnostics()
            await refresh(force: false)
            while !Task.isCancelled {
                snapshot = await router.diagnostics()
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
            }
        }
    }

    private func refresh(force: Bool) async {
        measuring = true
        await router.refreshDiagnostics(force: force)
        snapshot = await router.diagnostics()
        measuring = false
    }

    private func activeTitle(_ snapshot: HubConnectionDiagnostics) -> String {
        snapshot.activeRoute.map(connectionRouteTitle) ?? String(localized: "Disconnected")
    }
    private func reasonTitle(_ reason: HubConnectionDiagnostics.Reason) -> String {
        switch reason {
        case .lanVerified: String(localized: "Connected directly on your home network")
        case .forcedLAN: String(localized: "Home network selected manually")
        case .publicPreferred: String(localized: "Using public relay outside your home network")
        case .tailscaleFallback: String(localized: "Public relay unavailable; using Tailscale")
        case .starting: String(localized: "Checking connection")
        case .privateVerified: String(localized: "Private endpoint verified")
        case .privateUnavailable: String(localized: "Last private routing probe did not succeed")
        case .awaitingRecovery: String(localized: "Waiting for stable private connectivity")
        case .noPrivateEndpoint: String(localized: "No private endpoint discovered")
        case .forcedPublic: String(localized: "Public relay selected manually")
        case .forcedPrivate: String(localized: "Tailscale selected manually")
        case .privateNetworkFailure: String(localized: "Private request failed; falling back to public relay")
        case .publicNetworkFailure: String(localized: "Public request failed; checking private connectivity")
        case .privateSlowerThanPublic: String(localized: "Private route is much slower; using public relay")
        }
    }
}

struct EndpointMeasurementRows: View {
    let sample: HubEndpointMeasurement?
    var body: some View {
        if let sample {
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(outcomeTitle(sample.outcome))
                    Spacer()
                    if sample.outcome == .reachable {
                        Text(verbatim: sample.milliseconds == 0 ? "<1 ms" : "\(sample.milliseconds) ms")
                            .monospacedDigit().fontWeight(.medium)
                    }
                }
                HStack(alignment: .firstTextBaseline) {
                    Text("Last checked")
                    Text(sample.checkedAt, style: .relative)
                    Spacer(minLength: 4)
                    if let reused = sample.reusedConnection, sample.outcome == .reachable {
                        Text(reused ? String(localized: "Reused connection") : String(localized: "New connection"))
                    }
                }
                .font(.caption).foregroundStyle(.secondary)
                Text(sample.url.absoluteString).font(.caption2).foregroundStyle(.tertiary).textSelection(.enabled)
            }
        } else {
            Text("Not measured in this mode yet").foregroundStyle(.secondary)
        }
    }
    private func outcomeTitle(_ outcome: HubEndpointMeasurement.Outcome) -> String {
        switch outcome {
        case .reachable: String(localized: "Reachable")
        case .timeout: String(localized: "Timed out")
        case .unavailable: String(localized: "Unavailable")
        case .identityMismatch: String(localized: "Hub identity mismatch")
        case .httpError(let status): "HTTP \(status)"
        }
    }
}
