import Foundation

public enum Example {}
extension Example {
    public static func pass() {
        Task {
            try? await Task.sleep(for: .seconds(1))
            print("xtool test succeeded")
            exit(0)
        }
    }
}
