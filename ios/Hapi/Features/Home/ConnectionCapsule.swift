import HapiClient
import SwiftUI

/// A compact view of the actual global event connection, not merely the next
/// endpoint selected by policy. All timestamps and latency samples stay explicit.
struct ConnectionCapsuleLabel: View {
    let snapshot: HubConnectionDiagnostics?
    var referenceDate = Date()

    var routeTitle: String {
        guard let active = snapshot?.activeEventIsPrivate else { return String(localized: "Disconnected") }
        return active ? String(localized: "Private route") : String(localized: "Public route")
    }
    var latencyTitle: String {
        guard snapshot?.activeEventIsPrivate != nil, let sample = snapshot?.currentMeasurement,
              sample.outcome == .reachable,
              (0...60).contains(referenceDate.timeIntervalSince(sample.checkedAt)) else { return "—" }
        return sample.milliseconds == 0 ? "<1 ms" : "\(sample.milliseconds) ms"
    }

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: snapshot?.activeEventIsPrivate.map { $0 ? "house" : "cloud" } ?? "network")
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

    var body: some View {
        Button { expanded = true } label: { ConnectionCapsuleLabel(snapshot: snapshot) }
            .buttonStyle(.plain)
            .accessibilityIdentifier("home.connection")
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: snapshot?.activeEventIsPrivate)
            .popover(isPresented: $expanded) {
                NavigationStack {
                    ConnectionDiagnosticsView(router: router)
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) { Button("Done") { expanded = false } }
                        }
                }
                .frame(idealWidth: 340, idealHeight: 510)
                .presentationCompactAdaptation(.popover)
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
                    let nextIsPrivate = snapshot.isPrivate || snapshot.mode == .privateOnly
                    if snapshot.activeEventIsPrivate != nextIsPrivate {
                        LabeledContent("Next connection", value: nextIsPrivate ? "Tailscale" : String(localized: "Public relay"))
                    }
                    Text(reasonTitle(snapshot.reason)).font(.footnote).foregroundStyle(.secondary)
                    if let date = snapshot.reasonUpdatedAt {
                        HStack { Text("Updated"); Spacer(); Text(date, style: .relative) }
                            .font(.caption).foregroundStyle(.tertiary)
                    }
                }
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
        guard let active = snapshot.activeEventIsPrivate else { return String(localized: "Disconnected") }
        return active ? "Tailscale" : String(localized: "Public relay")
    }
    private func reasonTitle(_ reason: HubConnectionDiagnostics.Reason) -> String {
        switch reason {
        case .starting: String(localized: "Checking connection")
        case .privateVerified: String(localized: "Private endpoint verified")
        case .privateUnavailable: String(localized: "Last private routing probe did not succeed")
        case .awaitingRecovery: String(localized: "Waiting for stable private connectivity")
        case .noPrivateEndpoint: String(localized: "No private endpoint discovered")
        case .forcedPublic: String(localized: "Public relay selected manually")
        case .forcedPrivate: String(localized: "Tailscale selected manually")
        case .privateNetworkFailure: String(localized: "Private request failed; falling back to public relay")
        case .publicNetworkFailure: String(localized: "Public request failed; checking private connectivity")
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
