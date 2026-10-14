import Foundation
import AppKit

// MARK: - Utilities

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
    let panel = NSOpenPanel()
    panel.title = title
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.allowsMultipleSelection = false
    panel.canCreateDirectories = false
    return panel.runModal() == .OK ? panel.url : nil
}

func chooseFile(title: String) -> URL? {
    let panel = NSOpenPanel()
    panel.title = title
    panel.canChooseDirectories = false
    panel.canChooseFiles = true
    panel.allowsMultipleSelection = false
    return panel.runModal() == .OK ? panel.url : nil
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
