# About

xtool is a cross-platform replacement for Xcode (including build system, provisioning, deployment).

The `xtool` CLI supports macOS, Linux, WSL. The lower-level XKit (provisioning and device interaction) library additionally supports iOS.

## Development

- The majority of the code is in the Swift Package. You can use `swift build` / `swift test` / etc for iteration.
- Caveat: on macOS, xtool is distributed as an app bundle (allows entitlements like Keychain). To build the Mac app, use `make mac`. You can then invoke the CLI at `./macOS/Build/xtool`.
- Make sure to run `make lint` (swiftlint) when you're done

## Conventions

- Use modern Swift 6. Strict concurrency is enabled.
- Use swift-dependencies for Dependency Injection. Passing dependencies around as arguments is an anti-pattern.
