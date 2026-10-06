import SwiftUI
import ComposableArchitecture

@main
struct DemoTCAApp: App {
    private let store = Store(initialState: CounterFeature.State()) {
        CounterFeature()
    }

    var body: some Scene {
        WindowGroup {
            ContentView(store: store)
        }
    }
}
