import SwiftUI
import ComposableArchitecture
import ExampleSupport

struct ContentView: View {
    let store: StoreOf<CounterFeature>

    var body: some View {
        VStack {
            Image(systemName: "globe")
                .imageScale(.large)
                .foregroundStyle(.tint)
            Text("Count: \(store.count)")
        }
        .padding()
        .onAppear {
            store.send(.appear)
        }
        .onChange(of: store.count) { _, count in
            guard count == 1 else { return }
            Example.pass()
        }
    }
}
