import SwiftUI

@main
struct MonkeyWriteHomeApp: App {
    var body: some Scene {
        WindowGroup {
            HomeView()
                .preferredColorScheme(.dark)
                .tint(Theme.accent)
        }
    }
}
