import ExampleSupport
import SwiftUI

@main struct DemoApp: App {
    var body: some Scene {
        WindowGroup {
            Text("Hello, world!")
                .task {
                    guard let bundled = #bundle.url(forResource: "bundled", withExtension: "txt")
                          else { fatalError("Missing bundled.txt resource") }
                    assertContents(of: bundled, equal: "Bundled resource\n")

                    guard let top = Bundle.main.url(forResource: "top", withExtension: "txt")
                          else { fatalError("Missing top.txt resource") }
                    assertContents(of: top, equal: "Top level resource\n")

                    Example.pass()
                }
        }
    }
}

private func assertContents(of url: URL, equal value: String) {
    let name = url.lastPathComponent
    let contents: String
    do {
        contents = try String(contentsOf: url, encoding: .utf8)
    } catch {
        fatalError("Failed to read \(name): \(error)")
    }
    guard contents == value else {
        fatalError("\(name) had unexpected contents: \(contents)")
    }
}
