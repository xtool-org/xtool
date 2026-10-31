import ExampleSupport
import SwiftUI

@main struct DemoApp: App {
    public var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

private struct ContentView: View {
    @State var counter = 0

    var body: some View {
        VStack {
            Button("Counter = \(counter)") {
                counter += 1
            }
        }
        .padding()
        .task {
            Example.pass()
        }
    }
}
