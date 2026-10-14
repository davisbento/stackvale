import SwiftUI
import AppKit

// MARK: - Manage projects

struct ManageProjectsView: View {
    @EnvironmentObject private var store: ProjectStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Manage Projects")
                    .font(.title2.weight(.semibold))
                Spacer()
                Button("Done") { dismiss() }
            }

            List {
                ForEach(store.projects) { project in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            TextField("Name", text: Binding(
                                get: { project.name },
                                set: { store.renameProject(project.id, name: $0) }
                            ))
                            Button("Remove", role: .destructive) {
                                removeProject(project)
                            }
                        }
                        Text(project.rootPath.abbreviatingHomeDirectory())
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .padding(20)
        .frame(width: 520, height: 420)
    }

    private func removeProject(_ project: Project) {
        let alert = NSAlert()
        alert.messageText = "Remove \(project.name)?"
        alert.informativeText = "Project removal only deletes Stackvale definitions. It does not stop running services."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            store.removeProject(project.id)
        }
    }
}
