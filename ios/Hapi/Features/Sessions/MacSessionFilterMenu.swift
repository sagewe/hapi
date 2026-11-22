#if targetEnvironment(macCatalyst)
import HapiUI
import SwiftUI
import UIKit

/// The sidebar menu is built when opened, from current filter state. Selecting
/// a chat must not convert the whole tag/machine catalogue into NSMenu again.
struct MacSessionFilterMenu: UIViewRepresentable {
    let model: SessionListModel
    let assistant: Bool
    let tint: UIColor
    let onDates: () -> Void
    let onMarkAllRead: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UIButton {
        let button = UIButton(type: .system)
        var configuration = UIButton.Configuration.plain()
        configuration.image = UIImage(systemName: "line.3.horizontal.decrease")
        button.configuration = configuration
        button.showsMenuAsPrimaryAction = true
        button.accessibilityLabel = String(localized: "Filters")
        button.accessibilityIdentifier = "home.filters"
        let coordinator = context.coordinator
        button.menu = UIMenu(children: [UIDeferredMenuElement.uncached { [weak coordinator] completion in
            completion(coordinator?.elements() ?? [])
        }])
        updateUIView(button, context: context)
        return button
    }

    func updateUIView(_ button: UIButton, context: Context) {
        context.coordinator.owner = self
        button.tintColor = tint
        button.accessibilityValue = model.filterSummary ?? String(localized: "No filters")
    }

    @MainActor final class Coordinator {
        var owner: MacSessionFilterMenu
        init(_ owner: MacSessionFilterMenu) { self.owner = owner }

        func elements() -> [UIMenuElement] {
            let model = owner.model
            func action(_ title: String, icon: String? = nil, selected: Bool = false,
                        disabled: Bool = false, subtitle: String? = nil, _ perform: @escaping () -> Void) -> UIAction {
                let item = UIAction(title: title, image: icon.flatMap(UIImage.init(systemName:)),
                                    attributes: disabled ? .disabled : [], state: selected ? .on : .off) { _ in perform() }
                item.subtitle = subtitle
                return item
            }
            var groups: [UIMenuElement] = []
            func group(_ items: [UIMenuElement], title: String = "") {
                groups.append(UIMenu(title: title, options: .displayInline, children: items))
            }
            group([
                action(String(localized: "Active Only"), icon: "bolt.circle", selected: model.activeOnly) { model.setActiveOnly(!model.activeOnly) },
                action(String(localized: "Show Archived Sessions"), icon: "archivebox", selected: model.showArchivedSessions) { model.setShowArchivedSessions(!model.showArchivedSessions) },
                action(String(localized: "Unread Only"), icon: "circle.inset.filled", selected: model.filters.unreadOnly) { model.setUnreadOnly(!model.filters.unreadOnly) },
                action(String(localized: "Group by Tag"), icon: "tag", selected: model.groupByTag) { model.setGroupByTag(!model.groupByTag) },
            ])
            var dates: [UIMenuElement] = [action(String(localized: "Date Range"), icon: "calendar") { [weak self] in self?.owner.onDates() }]
            if model.filters.dateStart != nil {
                dates.append(action(String(localized: "Clear Date Range")) { model.setDateRange(start: nil, end: nil) })
            }
            group(dates)
            if model.showsTagFilter {
                var tags: [UIMenuElement] = [action(String(localized: "All Tags"), selected: model.activeTagFilter == nil) { model.selectTag(nil) }]
                for tag in model.tagFilters {
                    tags.append(action("#\(tag.label)", selected: model.activeTagFilter == tag.id,
                        subtitle: String(format: String(localized: "%lld sessions"), Int64(tag.sessionCount))) { model.selectTag(tag.id) })
                }
                group(tags, title: String(localized: "Tag"))
            }
            if model.showsMachineFilter && !owner.assistant {
                var machines: [UIMenuElement] = [action(String(localized: "All Machines"), selected: model.activeMachineFilter == nil) { model.selectMachine(nil) }]
                for machine in model.machineFilters {
                    machines.append(action(machine.label, selected: model.activeMachineFilter == machine.id,
                        subtitle: String(format: String(localized: "%lld sessions"), Int64(machine.sessionCount))) { model.selectMachine(machine.id) })
                }
                group(machines, title: String(localized: "Machine"))
            }
            group([action(String(localized: "Mark All as Read"), icon: "checkmark.circle", disabled: model.unreadCount == 0) { [weak self] in self?.owner.onMarkAllRead() }])
            if model.hasActiveFilters {
                group([action(String(localized: "Clear Filters"), icon: "line.3.horizontal.decrease.circle") { model.clearFilters() }])
            }
            return groups
        }
    }
}
#endif
