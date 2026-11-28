import ExampleSupport
import Foundation
import SwiftUI

@main struct DemoApp: App {
    var body: some Scene {
        WindowGroup {
            Text("Hello from an Xcode project!")
                .padding()
                .task {
                    guard let url = Bundle.main.url(forResource: "message", withExtension: "txt") else {
                        fatalError("Missing bundled resource")
                    }
                    let message = try? String(contentsOf: url, encoding: .utf8)
                    precondition(message == "Hello from Xcode!\n")
                    Example.pass()
                }
        }
    }
}
