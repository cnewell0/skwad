import Foundation

/// Centralizes launch-context checks so test hosts never start live app services.
enum AppRuntime {
    static var isRunningTests: Bool {
        if isRunningTests(environment: ProcessInfo.processInfo.environment) {
            return true
        }
        if NSClassFromString("XCTestCase") != nil {
            return true
        }
        let pluginNames = (try? FileManager.default.contentsOfDirectory(
            at: Bundle.main.builtInPlugInsURL ?? URL(fileURLWithPath: "/dev/null"),
            includingPropertiesForKeys: nil
        ).map(\.lastPathComponent)) ?? []
        return hasTestBundle(pluginNames: pluginNames)
    }

    static func isRunningTests(environment: [String: String]) -> Bool {
        if environment["SKWAD_TESTING"] == "1" {
            return true
        }
        guard let configurationPath = environment["XCTestConfigurationFilePath"] else {
            return false
        }
        return !configurationPath.isEmpty
    }

    static func hasTestBundle(pluginNames: [String]) -> Bool {
        pluginNames.contains { $0.hasSuffix(".xctest") }
    }

    static var isRunningForPreviews: Bool {
        ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1"
    }

    static var isToolingLaunch: Bool {
        isRunningTests || isRunningForPreviews
    }
}
