import ExampleSupport
import SwiftUI
import OpenSSL

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
        Text("Hello, world!")
            .padding()
            .task {
                do {
                    try await verify()
                    Example.pass()
                } catch {
                    print("Test failed: \(error)")
                    exit(1)
                }
            }
    }
}

private func verify() async throws {
    let shaSize = EVP_MD_get_size(EVP_sha256()) * 8
    guard shaSize == 256 else {
        throw StringError("OpenSSL sanity check failed: it claims that SHA-256 is \(shaSize) bits (!= 256)")
    }
}
