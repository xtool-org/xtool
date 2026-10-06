import ExampleDynamicLibrary
import ExampleSupport
import SwiftUI

@main struct DemoApp: ExampleApp {
    init() {
        let message = exampleDynamicLibraryFunction()
        guard message == "Hello from the dynamic library\n" else {
            fatalError("Unexpected message from dynamic library: \(message)")
        }
    }
}
