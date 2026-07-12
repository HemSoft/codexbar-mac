import SwiftUI

@main
struct CodexBarMacApp: App {
    var body: some Scene {
        MenuBarExtra("CodexBar", systemImage: "chart.bar.fill") {
            PopoverView()
        }
        .menuBarExtraStyle(.window)
    }
}
