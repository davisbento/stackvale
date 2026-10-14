import Foundation

@main
struct NodeCommandEnvironmentTests {
    static func main() throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: root) }
        let project = root.appendingPathComponent("project with 'quotes'")
        let nvm = root.appendingPathComponent("nvm")
        try manager.createDirectory(at: project, withIntermediateDirectories: true)
        try manager.createDirectory(at: project.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try manager.createDirectory(at: nvm, withIntermediateDirectories: true)
        try """
        nvm() {
            [ "$1" = use ] || return 1
            [ "$2" = --no-colors ] || return 1
            stackvale_test_version="${3#v}"
            case "$stackvale_test_version" in
                22) stackvale_test_version=22.10.0 ;;
                24|lts/*) stackvale_test_version=24.3.0 ;;
            esac
            [ -x "$NVM_DIR/versions/node/v$stackvale_test_version/bin/node" ] || return 1
            export PATH="$NVM_DIR/versions/node/v$stackvale_test_version/bin:/usr/bin:/bin"
        }
        """.write(to: nvm.appendingPathComponent("nvm.sh"), atomically: true, encoding: .utf8)
        for version in ["22.9.0", "22.10.0", "24.2.0", "24.3.0"] {
            let bin = nvm.appendingPathComponent("versions/node/v\(version)/bin")
            try manager.createDirectory(at: bin, withIntermediateDirectories: true)
            for command in ["node", "npm", "yarn", "pnpm"] {
                let file = bin.appendingPathComponent(command)
                try "#!/bin/sh\nprintf '%s\\n' '\(version)' \"$@\"\n".write(to: file, atomically: true, encoding: .utf8)
                try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
            }
        }
        var environment = ProcessInfo.processInfo.environment
        environment["NVM_DIR"] = nvm.path
        environment["PATH"] = nvm.appendingPathComponent("versions/node/v22.10.0/bin").path + ":/usr/bin:/bin"
        func launch(_ executable: String = "/usr/bin/env", _ arguments: [String] = ["npm", "run", "dev"], directory: URL? = nil) throws -> NodeCommandEnvironment.LaunchCommand {
            try NodeCommandEnvironment.launchCommand(executable: executable, arguments: arguments, workingDirectory: directory ?? project, environment: environment)
        }
        func run(_ command: NodeCommandEnvironment.LaunchCommand) throws -> (Int32, String) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: command.executable)
            process.arguments = command.arguments
            process.environment = environment
            process.currentDirectoryURL = project
            let output = Pipe()
            process.standardOutput = output
            process.standardError = output
            try process.run()
            let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            process.waitUntilExit()
            return (process.terminationStatus, text)
        }
        func require(_ condition: Bool, _ message: String) {
            guard condition else { fatalError(message) }
        }
        func write(_ name: String, _ content: String) throws {
            try content.write(to: project.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        func requireError(_ operation: () throws -> Void) {
            do { try operation(); fatalError("Expected preparation failure") }
            catch { }
        }

        require(try launch().executable == "/usr/bin/env", "No version declaration must keep the original command")
        try write(".nvmrc", "24\n")
        var result = try run(launch())
        require(result.0 == 0 && result.1.contains("24.3.0\nrun\ndev"), "Node 22 must switch to Node 24")
        result = try run(launch("/bin/zsh", ["-lc", "yarn dev && node 'argument with spaces' \"a'b\" '$HOME' '$(touch sentinel)' "]))
        require(result.0 == 0 && result.1.contains("24.3.0\ndev") && result.1.contains("argument with spaces\na'b\n$HOME\n$(touch sentinel)"), "Saved shell syntax and literal arguments must survive preparation")
        require(!manager.fileExists(atPath: project.appendingPathComponent("sentinel").path), "Arguments must not execute as shell code")
        require(try launch("/usr/bin/env", ["docker", "compose", "up"]).executable == "/usr/bin/env", "Non-Node commands must stay unchanged")
        try write(".nvmrc", "22\n")
        environment["PATH"] = nvm.appendingPathComponent("versions/node/v24.3.0/bin").path + ":/usr/bin:/bin"
        result = try run(launch())
        require(result.0 == 0 && result.1.contains("22.10.0\nrun\ndev"), "Node 24 must switch to Node 22")
        try write(".nvmrc", "99\n")
        result = try run(launch())
        require(result.0 != 0 && !result.1.contains("\nrun\ndev"), "Missing version must stop before running the service")
        try write(".nvmrc", "$(touch sentinel)\n")
        requireError { _ = try launch() }
        try write(".nvmrc", "lts/* # comment\n")
        require(try run(launch()).0 == 0, "nvm aliases and comments must work")
        let child = project.appendingPathComponent("packages/web")
        try manager.createDirectory(at: child, withIntermediateDirectories: true)
        require(try launch(directory: child).executable == "/bin/zsh", "Subdirectories must inherit repository requirements")
        try write(".node-version", "22\n")
        require(try run(launch()).1.contains("24.3.0"), ".nvmrc must precede .node-version")
        try manager.removeItem(at: project.appendingPathComponent(".nvmrc"))
        require(try run(launch()).1.contains("22.10.0"), ".node-version must be respected")
        try manager.removeItem(at: project.appendingPathComponent(".node-version"))
        try "24\n".write(to: root.appendingPathComponent(".nvmrc"), atomically: true, encoding: .utf8)
        require(try launch().executable == "/usr/bin/env", "Do not inherit configuration outside the repository")

        let ranges: [(String, String)] = [
            (">=24 <25", "24.3.0"), ("^22.9.0", "22.10.0"), ("~24.2.0", "24.2.0"),
            ("22.x", "22.10.0"), ("22 || 24", "24.3.0"), ("22.9 - 22.10", "22.10.0"),
            ("<=22", "22.10.0"), (">22", "24.3.0"), ("24.2.0", "24.2.0"),
            (">= 22.10.0 < 24.3.0", "24.2.0"), ("*", "24.3.0")
        ]
        for (range, expected) in ranges {
            let data = try JSONSerialization.data(withJSONObject: ["engines": ["node": range]])
            try data.write(to: project.appendingPathComponent("package.json"))
            result = try run(launch())
            require(result.0 == 0 && result.1.contains("\(expected)\nrun\ndev"), "Wrong selection for range \(range): \(result.1)")
        }
        for range in [">=99", "^24.0.0-beta.1", "banana"] {
            try write("package.json", "{\"engines\":{\"node\":\"\(range)\"}}")
            requireError { _ = try launch() }
        }
        try write(".nvmrc", "24\n")
        environment["NVM_DIR"] = root.appendingPathComponent("missing-nvm").path
        // A Homebrew installation may still load nvm, but selection must fail with no installed version.
        result = try run(launch())
        require(result.0 != 0 && !result.1.contains("\nrun\ndev"), "An unavailable runtime must not execute the saved command")
        print("Node command environment checks passed")
    }
}
