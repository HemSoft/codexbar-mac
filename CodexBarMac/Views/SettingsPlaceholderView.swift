import SwiftUI

struct SettingsPlaceholderView: View {
    var body: some View {
        Form {
            Section {
                Text("Provider settings are coming in a follow-up release.")
                    .foregroundStyle(.secondary)
            } header: {
                Text("CodexBar")
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 420, minHeight: 280)
    }
}
