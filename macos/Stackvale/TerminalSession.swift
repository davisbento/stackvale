import Foundation
import Combine

/// A small interactive shell session scoped to one service's working directory.
@MainActor
final class TerminalSession: ObservableObject {
    @Published private(set) var output = ""
    @Published private(set) var isRunning = false

    private let workingDirectory: URL
    private var process: Process?
    private var inputPipe: Pipe?
    private var outputHandles: [FileHandle] = []
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

        let process = Process()
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        var environment = UserShellEnvironment.resolved()
        environment["TERM"] = "dumb"
        environment["PS1"] = ""
        environment["RPS1"] = ""
        environment["PROMPT_EOL_MARK"] = ""

        process.executableURL = URL(fileURLWithPath: shellPath)
        process.arguments = ["-il"]
        process.currentDirectoryURL = workingDirectory
        process.environment = environment
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        self.process = process
        self.inputPipe = inputPipe
        outputHandles = [outputPipe.fileHandleForReading, errorPipe.fileHandleForReading]
        outputHandles.forEach { attachOutputHandler(to: $0) }

        process.terminationHandler = { [weak self] _ in
            Task { @MainActor in
                self?.finish()
            }
        }

        do {
            try process.run()
            isRunning = true
            append("[shell: \(shellPath.abbreviatingHomeDirectory())] \(workingDirectory.path.abbreviatingHomeDirectory())\n")
        } catch {
            finish()
            append("[error] Could not start shell: \(error.localizedDescription)\n")
        }
    }

    func send(_ command: String) {
        guard isRunning, !command.isEmpty else { return }
        append("$ \(command)\n")
        guard let data = "\(command)\n".data(using: .utf8) else { return }
        do {
            try inputPipe?.fileHandleForWriting.write(contentsOf: data)
        } catch {
            append("[error] Could not send command: \(error.localizedDescription)\n")
        }
    }

    func terminate() {
        process?.terminate()
        finish()
    }

    private func attachOutputHandler(to handle: FileHandle) {
        handle.readabilityHandler = { [weak self] fileHandle in
            let data = fileHandle.availableData
            guard !data.isEmpty, let chunk = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor in
                self?.append(chunk)
            }
        }
    }

    private func finish() {
        outputHandles.forEach { $0.readabilityHandler = nil }
        outputHandles.removeAll()
        inputPipe = nil
        process = nil
        isRunning = false
    }

    private func append(_ text: String) {
        output += text
        if output.count > maxOutputCharacters {
            output = "…" + String(output.suffix(maxOutputCharacters))
        }
    }
}
