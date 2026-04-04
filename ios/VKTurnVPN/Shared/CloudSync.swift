import Foundation

/// Simple iCloud sync via NSUbiquitousKeyValueStore.
/// Syncs the entire AppConfig as JSON.
class CloudSync {
    static let shared = CloudSync()
    private let store = NSUbiquitousKeyValueStore.default
    private let key = "swinter_config"

    /// Push current config to iCloud.
    func push(_ config: AppConfig) {
        guard let data = try? JSONEncoder().encode(config),
              let json = String(data: data, encoding: .utf8) else { return }
        store.set(json, forKey: key)
        store.synchronize()
        print("[CloudSync] Pushed config (\(data.count) bytes)")
    }

    /// Pull config from iCloud. Returns nil if no cloud data.
    func pull() -> AppConfig? {
        guard let json = store.string(forKey: key),
              let data = json.data(using: .utf8),
              let config = try? JSONDecoder().decode(AppConfig.self, from: data) else { return nil }
        print("[CloudSync] Pulled config with \(config.servers.count) servers")
        return config
    }

    /// Start observing iCloud changes.
    func startObserving(onChange: @escaping (AppConfig) -> Void) {
        NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: store,
            queue: .main
        ) { [weak self] _ in
            if let config = self?.pull() {
                onChange(config)
            }
        }
        store.synchronize()
    }

    /// Sync: merge cloud config with local (cloud wins for servers, local wins for settings).
    func sync(local: AppConfig) -> AppConfig {
        guard let cloud = pull() else {
            push(local)
            return local
        }

        // Simple strategy: if cloud has more servers, use cloud
        if cloud.servers.count > local.servers.count {
            print("[CloudSync] Cloud has more servers, using cloud config")
            var merged = cloud
            merged.settings = local.settings // keep local settings
            return merged
        }

        // Otherwise push local to cloud
        push(local)
        return local
    }
}
