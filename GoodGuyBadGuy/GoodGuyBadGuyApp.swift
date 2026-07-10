import SwiftUI

@main
struct GoodGuyBadGuyApp: App {
    @State private var store = ChatStore()

    var body: some Scene {
        WindowGroup {
            ChatView(store: store)
        }
    }
}
