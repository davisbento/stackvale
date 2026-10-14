import Foundation
import AppKit

// MARK: - Utilities

extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}

extension ServiceDraft {
    static func manualDefault(workingDirectory: String) -> ServiceDraft {
        ServiceDraft(
            selected: true,
            name: "New Service",
            kind: .localCommand,
            workingDirectory: workingDirectory,
            source: .manual,
            commandExecutable: "/bin/zsh",
            commandArguments: ["-lc", ""],
            commandDisplay: "",
            composeFile: nil,
            composeService: nil,
            displayPort: nil,
            iconCategory: .generic,
            origin: "Manual"
        )
    }
}

func chooseDirectory(title: String) -> URL? {
    let panel = directoryOpenPanel(title: title)
    bringOpenPanelToFront(panel)
    return panel.runModal() == .OK ? panel.url : nil
}

@MainActor
func chooseDirectory(title: String, presentingWindow: NSWindow?) async -> URL? {
    let panel = directoryOpenPanel(title: title)
    bringOpenPanelToFront(panel)
    return await withCheckedContinuation { continuation in
        panel.begin { response in
            continuation.resume(returning: response == .OK ? panel.url : nil)
        }
    }
}

func chooseFile(title: String) -> URL? {
    let panel = NSOpenPanel()
    panel.title = title
    panel.canChooseDirectories = false
    panel.canChooseFiles = true
    panel.allowsMultipleSelection = false
    bringOpenPanelToFront(panel)
    return panel.runModal() == .OK ? panel.url : nil
}

private func bringOpenPanelToFront(_ panel: NSOpenPanel) {
    NSApplication.shared.activate(ignoringOtherApps: true)
    panel.level = .floating
    panel.hidesOnDeactivate = false
    panel.orderFrontRegardless()
}

private func directoryOpenPanel(title: String) -> NSOpenPanel {
    let panel = NSOpenPanel()
    panel.title = title
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.allowsMultipleSelection = false
    panel.canCreateDirectories = false
    return panel
}

enum UserShellEnvironment {
    private static let lock = NSLock()
    private static var cachedEnvironment: [String: String]?

    static func resolved() -> [String: String] {
        lock.lock()
        if let cachedEnvironment {
            lock.unlock()
            return cachedEnvironment
        }
        lock.unlock()

        var environment = ProcessInfo.processInfo.environment
        if let shellEnvironment = loadLoginInteractiveShellEnvironment() {
            environment.merge(shellEnvironment) { _, shellValue in shellValue }
        }

        environment["PATH"] = augmentedPath(environment["PATH"])

        lock.lock()
        cachedEnvironment = environment
        lock.unlock()

        return environment
    }

    private static func loadLoginInteractiveShellEnvironment() -> [String: String]? {
        let baseEnvironment = ProcessInfo.processInfo.environment
        let shellPath = baseEnvironment["SHELL"].flatMap { FileManager.default.fileExists(atPath: $0) ? $0 : nil } ?? "/bin/zsh"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shellPath)
        process.arguments = ["-lic", "env"]
        process.environment = baseEnvironment

        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = outputPipe

        do {
            try process.run()
            guard process.waitUntilExit(timeout: 3) else {
                process.terminate()
                return nil
            }
        } catch {
            return nil
        }

        guard process.terminationStatus == 0 else { return nil }
        let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8) else { return nil }

        var environment: [String: String] = [:]
        for line in output.split(whereSeparator: \.isNewline).map(String.init) {
            guard let separator = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<separator])
            guard isEnvironmentKey(key) else { continue }
            environment[key] = String(line[line.index(after: separator)...])
        }

        return environment.isEmpty ? nil : environment
    }

    private static func augmentedPath(_ path: String?) -> String {
        let home = NSHomeDirectory()
        var paths = path?
            .split(separator: ":")
            .map(String.init) ?? []

        for candidate in fallbackExecutableSearchPaths(home: home) where !paths.contains(candidate) {
            paths.append(candidate)
        }

        return paths.joined(separator: ":")
    }

    private static func fallbackExecutableSearchPaths(home: String) -> [String] {
        var paths = [
            "/opt/homebrew/bin",
            "/opt/homebrew/sbin",
            "/usr/local/bin",
            "/usr/local/sbin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin",
            "\(home)/.asdf/shims",
            "\(home)/.volta/bin",
            "\(home)/.yarn/bin",
            "\(home)/.config/yarn/global/node_modules/.bin",
            "\(home)/.npm-global/bin",
            "\(home)/.bun/bin"
        ]

        paths.append(contentsOf: nvmNodeBinaryPaths(home: home))
        return paths
    }

    private static func nvmNodeBinaryPaths(home: String) -> [String] {
        let versionsURL = URL(fileURLWithPath: home)
            .appendingPathComponent(".nvm")
            .appendingPathComponent("versions")
            .appendingPathComponent("node")

        guard let versions = try? FileManager.default.contentsOfDirectory(at: versionsURL, includingPropertiesForKeys: nil) else {
            return []
        }

        return versions
            .map { $0.appendingPathComponent("bin").path }
            .filter { FileManager.default.fileExists(atPath: $0) }
            .sorted(by: >)
    }

    private static func isEnvironmentKey(_ key: String) -> Bool {
        guard let first = key.first, first == "_" || first.isLetter else { return false }
        return key.allSatisfy { $0 == "_" || $0.isLetter || $0.isNumber }
    }
}

private extension Process {
    func waitUntilExit(timeout seconds: TimeInterval) -> Bool {
        let semaphore = DispatchSemaphore(value: 0)
        terminationHandler = { _ in semaphore.signal() }

        if !isRunning { return true }
        return semaphore.wait(timeout: .now() + seconds) == .success
    }
}

extension String {
    func abbreviatingHomeDirectory() -> String {
        let home = NSHomeDirectory()
        if hasPrefix(home) {
            return replacingOccurrences(of: home, with: "~", options: [.anchored])
        }
        return self
    }
}
