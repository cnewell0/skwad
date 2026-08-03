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

    /// True when XCUITest launched this process. The UI test build shares the app's
    /// bundle id, so the single-instance guard would otherwise quit it the moment a
    /// real Skwad is already running.
    static var isUITesting: Bool {
        isUITesting(
            arguments: ProcessInfo.processInfo.arguments,
            environment: ProcessInfo.processInfo.environment
        )
    }

    static func isUITesting(arguments: [String], environment: [String: String]) -> Bool {
        if environment["SKWAD_UI_TESTING"] == "1" { return true }
        guard let flagIndex = arguments.firstIndex(of: "-uiTesting") else { return false }
        let next = arguments.index(after: flagIndex)
        return next < arguments.endIndex ? arguments[next] == "YES" : true
    }

    static var isRunningForPreviews: Bool {
        ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1"
    }

    static var isToolingLaunch: Bool {
        isRunningTests || isRunningForPreviews
    }
}
