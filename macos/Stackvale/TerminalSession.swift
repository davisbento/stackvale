import Foundation
import Combine
import Darwin

/// A small interactive shell session scoped to one service's working directory.
@MainActor
final class TerminalSession: ObservableObject {
    @Published private(set) var output = ""
    @Published private(set) var isRunning = false

    private let workingDirectory: URL
    private var process: Process?
    private var terminalHandle: FileHandle?
    private let maxOutputCharacters = 20_000

    init(workingDirectory: URL) {
        self.workingDirectory = workingDirectory
    }

    func start() {
        guard process == nil else { return }

        let shellPath = ProcessInfo.processInfo.environment["SHELL"]
            .flatMap { FileManager.default.isExecutableFile(atPath: $0) ? $0 : nil }
            ?? "/bin/zsh"
        guard FileManager.default.isExecutableFile(atPath: shellPath) else {
            append("[error] Could not find the user's shell.\n")
            return
        }

        var master: Int32 = -1
        var slave: Int32 = -1
        guard openpty(&master, &slave, nil, nil, nil) == 0 else {
            append("[error] Could not create a pseudo-terminal.\n")
            return
        }

        let terminalHandle = FileHandle(fileDescriptor: master, closeOnDealloc: true)
        let slaveHandle = FileHandle(fileDescriptor: slave, closeOnDealloc: true)
        let process = Process()
        var environment = UserShellEnvironment.resolved()
        // Keep the user's terminal and prompt configuration. In particular, TERM=dumb
        // disables prompt colors and can cause shell integrations (such as 1Password's
        // shell plugin) to skip their interactive setup.
        if environment["TERM"]?.isEmpty != false {
            environment["TERM"] = "xterm-256color"
        }

        // Connect all three streams to the slave side of a real PTY. This makes
        // zsh and interactive integrations (such as 1Password Shell Plugins)
        // see an actual terminal, rather than an ordinary pipe.
        process.executableURL = URL(fileURLWithPath: shellPath)
        process.arguments = ["-il"]
        process.currentDirectoryURL = workingDirectory
        process.environment = environment
        process.standardInput = slaveHandle
        process.standardOutput = slaveHandle
        process.standardError = slaveHandle

        self.process = process
        self.terminalHandle = terminalHandle
        attachOutputHandler(to: terminalHandle)

        process.terminationHandler = { [weak self] _ in
            Task { @MainActor in
                self?.finish()
            }
        }

        do {
            try process.run()
            slaveHandle.closeFile()
            isRunning = true
            append("[shell: \(shellPath.abbreviatingHomeDirectory())] \(workingDirectory.path.abbreviatingHomeDirectory())\n")
            // Some .zshrc files change directory while they initialize. Send
            // this after startup has settled so the selected service directory
            // is the final working directory visible to the user.
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled, let self, self.isRunning else { return }
                self.write("cd -- \(Self.shellQuote(self.workingDirectory.path))\n")
            }
        } catch {
            slaveHandle.closeFile()
            finish()
            append("[error] Could not start shell: \(error.localizedDescription)\n")
        }
    }

    func send(_ command: String) {
        guard isRunning, !command.isEmpty else { return }
        append("$ \(command)\n")
        write("\(command)\n")
    }

    private func write(_ text: String) {
        guard let data = text.data(using: .utf8) else { return }
        do {
            try terminalHandle?.write(contentsOf: data)
        } catch {
            append("[error] Could not send command: \(error.localizedDescription)\n")
        }
    }

    nonisolated private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    func terminate() {
        process?.terminate()
        finish()
    }

    private func attachOutputHandler(to handle: FileHandle) {
        handle.readabilityHandler = { [weak self] fileHandle in
            let data = fileHandle.availableData
            guard !data.isEmpty, let rawChunk = String(data: data, encoding: .utf8) else { return }
            let chunk = Self.removingANSISequences(from: rawChunk)
            guard !chunk.isEmpty else { return }
            Task { @MainActor in
                self?.append(chunk)
            }
        }
    }

    private func finish() {
        terminalHandle?.readabilityHandler = nil
        try? terminalHandle?.close()
        terminalHandle = nil
        process = nil
        isRunning = false
    }

    private func append(_ text: String) {
        output += text
        if output.count > maxOutputCharacters {
            output = "…" + String(output.suffix(maxOutputCharacters))
        }
    }

    nonisolated private static func removingANSISequences(from text: String) -> String {
        // The UI is a text view, not a terminal emulator. Keep the readable
        // prompt/output while avoiding raw escape sequences such as "[31m".
        let escape = "\u{001B}"
        let pattern = "\(escape)(?:\\[[0-?]*[ -/]*[@-~]|\\][^\u{0007}]*(?:\u{0007}|\(escape)\\\\))"
        return text.replacingOccurrences(
            of: pattern,
            with: "",
            options: .regularExpression
        )
    }
}
