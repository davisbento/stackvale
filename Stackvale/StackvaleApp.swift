import SwiftUI

// MARK: - App

@main
struct StackvaleApp: App {
    @StateObject private var projectStore = ProjectStore()
    @StateObject private var serviceManager = ServiceManager()

    var body: some Scene {
        MenuBarExtra {
            StackvaleRootView()
                .environmentObject(projectStore)
                .environmentObject(serviceManager)
                .frame(width: 430)
                .frame(minHeight: 360)
        } label: {
            Image("StackvaleLogo")
                .resizable()
                .renderingMode(.original)
                .scaledToFit()
        }
        .menuBarExtraStyle(.window)
    }
}
