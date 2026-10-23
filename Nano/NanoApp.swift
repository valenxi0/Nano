import SwiftUI

@main
struct NanoApp: App {
    @NSApplicationDelegateAdaptor(NanoAppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            NanoSettingsView(
                settings: appDelegate.settings,
                viewModel: appDelegate.viewModel
            )
            .frame(width: 920, height: 680)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        // The scene is only here because an App needs one. The real Settings
        // window belongs to the app delegate, so Command-comma goes there
        // instead of opening this scene as a second, different window.
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") {
                    NotificationCenter.default.post(name: .nanoOpenSettings, object: nil)
                }
                .keyboardShortcut(",", modifiers: .command)
            }
        }
    }
}

