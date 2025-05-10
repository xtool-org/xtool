import SwiftUI

struct XToolMacUI: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .disableWindowResizingIfPossible()
    }
}

private struct ContentView: View {
    private static let command = """
    sudo ln -fs /Applications/xtool.app/Contents/Resources/bin/xtool /usr/local/bin/xtool
    """

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            StepView(1) {
                Text("Move this app into your `/Applications` folder.")
            }

            StepView(2) {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Symlink xtool into a location on your `PATH`.")

                    Text(Self.command)
                        .font(.body.monospaced())
                        .textSelection(.enabled)

                    Button("Copy Command") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(Self.command, forType: .string)
                    }
                }
            }
        }
        .padding()
        .padding(.vertical)
        .frame(width: 500)
        .fixedSize()
        .navigationTitle("xtool")
    }
}

private struct StepView<Content: View>: View {
    let number: Int
    let content: Content

    init(_ number: Int, @ViewBuilder content: () -> Content) {
        self.number = number
        self.content = content()
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("\(number)")
                .foregroundStyle(.background)
                .padding(8)
                .background(.secondary, in: .circle)

            content
        }
    }
}

extension Scene {
    fileprivate func disableWindowResizingIfPossible() -> some Scene {
        if #available(macOS 13, *) {
            return self.windowResizability(.contentSize)
        } else {
            return self
        }
    }
}

#Preview {
    ContentView()
}
