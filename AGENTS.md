# About

xtool is a cross-platform replacement for Xcode (including build system, provisioning, deployment).

The `xtool` CLI supports macOS, Linux, WSL. The lower-level XKit (provisioning and device interaction) library additionally supports iOS.

## Development

- The majority of the code is in the Swift Package. You can use `swift build` / `swift test` / etc for iteration.
- Caveat: on macOS, xtool is distributed as an app bundle (allows entitlements like Keychain). To build the Mac app, use `make mac`. You can then invoke the CLI at `./macOS/Build/xtool`.
- Make sure to run `make lint` (swiftlint) when you're done

## Conventions

- Use modern Swift 6. Strict concurrency is enabled.
- Use swift-dependencies (`@Dependency(\.foo)` / `d.foo`) for Dependency Injection. Passing dependencies around as arguments is an anti-pattern.
- Commits should be in the format `subsystem: imperative description` e.g. `auth: support reading password from stdin`.
- Don't use `Task.detached { ... }`. If you need to escape isolation, you want `Task { @concurrent in ... }` instead.
- Uphold API stability guarantees for consumers who use xtool via the command line interface (e.g. don't remove subcommands or config fields). However, the Swift interface (including `public` types) when consuming xtool itself as a Swift Package is _NOT_ API stable; it's okay to break Swift API.
