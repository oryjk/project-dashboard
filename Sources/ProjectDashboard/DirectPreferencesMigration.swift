import Foundation

/// Turning off App Sandbox changes the preferences location. Keep the user's directory
/// bookmarks, sections and GLM region without overwriting settings in the direct build.
enum DirectPreferencesMigration {
    static func migrateIfNeeded() {
        guard Bundle.main.object(forInfoDictionaryKey: "LocalAccountUsageEnabled") as? Bool == true,
              let identifier = Bundle.main.bundleIdentifier else { return }
        let file = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Containers/\(identifier)/Data/Library/Preferences/\(identifier).plist")
        guard let data = try? Data(contentsOf: file),
              let source = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return }
        migrate(from: source, into: .standard)
    }

    static func migrate(from source: [String: Any], into defaults: UserDefaults) {
        for key in ["scanRootBookmarks", "pinnedRepoPaths", "archivedRepoPaths", "sectionOrders", UsageSettings.glmInternationalKey] {
            if defaults.object(forKey: key) == nil, let value = source[key] {
                defaults.set(value, forKey: key)
            }
        }
    }
}
