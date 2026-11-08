import HapiUI
import SwiftUI

/// One expandable home affordance: the unread lens, machine selection (two
/// or more machines) and Mark All as Read. Future filter dimensions belong in
/// this menu, not in a row of always-visible machine / status / agent chips.
struct SessionFilterMenu: View {
    @Environment(\.hapiTheme) private var theme
    let model: SessionListModel
    @State private var confirmMarkAllRead = false
    @State private var datesOpen = false

    var body: some View {
        Menu {
            Section {
                Toggle(isOn: Binding(get: { model.activeOnly }, set: { model.setActiveOnly($0) })) {
                    Label("Active Only", systemImage: "bolt.circle")
                }
                .accessibilityIdentifier("home.filters.active")
                Toggle(isOn: Binding(get: { model.showArchivedSessions }, set: { model.setShowArchivedSessions($0) })) {
                    Label("Show Archived Sessions", systemImage: "archivebox")
                }
                .accessibilityIdentifier("home.filters.archived")
                Toggle(isOn: Binding(get: { model.filters.unreadOnly }, set: { model.setUnreadOnly($0) })) {
                    Label("Unread Only", systemImage: "circle.inset.filled")
                }
                .accessibilityIdentifier("home.filters.unread")
                Toggle(isOn: Binding(get: { model.groupByTag }, set: { model.setGroupByTag($0) })) {
                    Label("Group by Tag", systemImage: "tag")
                }
                .accessibilityIdentifier("home.filters.group-by-tag")
            }
            Button("Date Range", systemImage: "calendar") { datesOpen = true }
            if model.filters.dateStart != nil {
                Button("Clear Date Range") { model.setDateRange(start: nil, end: nil) }
            }
            if model.showsTagFilter {
                tagSection
            }
            if model.showsMachineFilter {
                machineSection
            }
            Section {
                Button("Mark All as Read", systemImage: "checkmark.circle") {
                    confirmMarkAllRead = true
                }
                .disabled(model.unreadCount == 0)
                .accessibilityIdentifier("home.filters.mark-all-read")
            }
            if model.hasActiveFilters {
                Divider()
                Button("Clear Filters", systemImage: "line.3.horizontal.decrease.circle") {
                    model.clearFilters()
                }
            }
        } label: {
            // No .circle variant: the iOS 26 glass button is already the
            // circle. Active filters show through the accent tint.
            Label("Filters", systemImage: "line.3.horizontal.decrease")
                .frame(minWidth: 44, minHeight: 44)
        }
        .tint(model.hasActiveFilters ? theme.accent : .primary)
        .accessibilityValue(model.filterSummary ?? String(localized: "No filters"))
        .accessibilityIdentifier("home.filters")
        .sheet(isPresented: $datesOpen) { SessionDateRangeSheet(model: model) }
        .alert("Mark All as Read?", isPresented: $confirmMarkAllRead) {
            Button("Mark as Read") { model.markAllRead() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(String(
                format: String(localized: "Marks %lld unread sessions as read across your devices."),
                Int64(model.unreadCount)
            ))
        }
    }

    private var tagSection: some View {
        Section("Tag") {
            Button {
                model.selectTag(nil)
            } label: {
                Text("All Tags")
                if model.activeTagFilter == nil { Image(systemName: "checkmark") }
            }
            .accessibilityAddTraits(model.activeTagFilter == nil ? .isSelected : [])
            ForEach(model.tagFilters) { tag in
                Button {
                    model.selectTag(tag.id)
                } label: {
                    Text(verbatim: "#\(tag.label)")
                    Text("\(tag.sessionCount, specifier: "%lld") sessions")
                    if model.activeTagFilter == tag.id { Image(systemName: "checkmark") }
                }
                .accessibilityLabel(Text("#\(tag.label), \(tag.sessionCount, specifier: "%lld") sessions"))
                .accessibilityAddTraits(model.activeTagFilter == tag.id ? .isSelected : [])
            }
        }
    }

    private var machineSection: some View {
        Section("Machine") {
            Button {
                model.selectMachine(nil)
            } label: {
                Text("All Machines")
                if model.activeMachineFilter == nil { Image(systemName: "checkmark") }
            }
            .accessibilityAddTraits(model.activeMachineFilter == nil ? .isSelected : [])
            ForEach(model.machineFilters) { machine in
                Button {
                    model.selectMachine(machine.id)
                } label: {
                    // Native Menu buttons turn the second Text into a
                    // subtitle; Picker options silently discard it.
                    Text(machine.label)
                    Text("\(machine.sessionCount, specifier: "%lld") sessions")
                    if model.activeMachineFilter == machine.id { Image(systemName: "checkmark") }
                }
                .accessibilityLabel(Text("\(machine.label), \(machine.sessionCount, specifier: "%lld") sessions"))
                .accessibilityAddTraits(model.activeMachineFilter == machine.id ? .isSelected : [])
            }
        }
    }
}

/// Only applied conditions take space. No inventory counts or scrollable
/// catalogue here; names get two lines without displacing the session list.
struct SessionFilterSummary: View {
    let summary: String
    let onClear: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Text(summary)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .truncationMode(.middle)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("home.filter-summary")
            Spacer(minLength: 0)
            Button(action: onClear) {
                Image(systemName: "xmark")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Clear Filters")
            .accessibilityIdentifier("home.clear-filters")
        }
        .padding(.leading, 16)
        .padding(.trailing, 6)
        .background(.bar)
    }
}

private struct SessionDateRangeSheet: View {
    let model: SessionListModel
    @Environment(\.dismiss) private var dismiss
    @State private var start: Date
    @State private var end: Date
    init(model: SessionListModel) {
        self.model = model
        _start = State(initialValue: model.filters.dateStart ?? Date())
        _end = State(initialValue: model.filters.dateEnd ?? Date())
    }
    var body: some View {
        NavigationStack {
            Form {
                DatePicker("Start Date", selection: $start, displayedComponents: .date)
                DatePicker("End Date", selection: $end, displayedComponents: .date)
                Button("Clear Date Range") { model.setDateRange(start: nil, end: nil); dismiss() }
            }
            .navigationTitle("Date Range")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Apply") { model.setDateRange(start: start, end: end); dismiss() } }
            }
        }
    }
}
