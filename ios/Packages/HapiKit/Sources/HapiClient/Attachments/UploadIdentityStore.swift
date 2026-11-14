import Foundation

/// Only unfinished-upload ids and content fingerprints are persisted. File
/// bytes, filenames, origins and credentials are never written to defaults.
/// A reselected identical prepared file can adopt an unfinished id after an
/// app restart. Concurrent copies get separate ids; success retires the id.
actor UploadIdentityStore {
    static let shared = UploadIdentityStore(persistent: true)
    private struct Receipt: Codable {
        let key: String
        let id: String
        var updatedAt: Date
    }
    private let defaults: UserDefaults?
    private let storageKey = "run.hapi.pendingUploadIdentities"
    private var receipts: [Receipt]
    private var active: Set<String> = []

    init(defaultsSuiteName: String? = nil, persistent: Bool = false) {
        let defaults = defaultsSuiteName.flatMap { UserDefaults(suiteName: $0) } ?? (persistent ? .standard : nil)
        self.defaults = defaults
        receipts = defaults?.data(forKey: storageKey)
            .flatMap { try? JSONDecoder().decode([Receipt].self, from: $0) } ?? []
    }

    func acquire(key: String) -> String {
        let now = Date()
        receipts.removeAll { !active.contains($0.id) && now.timeIntervalSince($0.updatedAt) > 86_400 }
        let id: String
        if let index = receipts.firstIndex(where: { $0.key == key && !active.contains($0.id) }) {
            id = receipts[index].id
            receipts[index].updatedAt = now
        } else {
            // Two UUIDs yield a path-safe 64-character random identifier.
            id = (UUID().uuidString + UUID().uuidString).replacingOccurrences(of: "-", with: "").lowercased()
            receipts.append(Receipt(key: key, id: id, updatedAt: now))
        }
        active.insert(id)
        if receipts.count > 256 {
            let excess = receipts.count - 256
            let evicted = Set(receipts.filter { !active.contains($0.id) }.prefix(excess).map(\.id))
            receipts.removeAll { evicted.contains($0.id) }
        }
        save()
        return id
    }

    func release(id: String, completed: Bool) {
        active.remove(id)
        if completed { receipts.removeAll { $0.id == id } }
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(receipts) { defaults?.set(data, forKey: storageKey) }
    }
}
