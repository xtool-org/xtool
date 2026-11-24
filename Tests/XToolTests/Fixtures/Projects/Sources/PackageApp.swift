import UIKit
import Library

@main
final class PackageApp: UIResponder, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        print((try? libraryMessage()) ?? "Unable to load package resource")
        return true
    }
}
