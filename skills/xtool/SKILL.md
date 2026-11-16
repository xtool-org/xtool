---
name: xtool
description: Build and run Apple apps faster with xtool
---
# About

[xtool](https://xtool.sh) is a cross-platform Xcode replacement. It supports building and run apps for iOS and macOS.

Run `xtool --help` to view the full command line interface.

# Supported projects

An xtool project should declare an `xtool.yml` at the top level. At minimum, it should have contents `version: 1`.

Build commands will automatically discover Xcode/SwiftPM projects located at the same level as the `xtool.yml`, otherwise you can manually specify the project with `project: path/to/{Package.swift,YourProject.xcodeproj,YourWorkspace.xcworkspace}`

## Xcode

If the project/workspace has a single scheme, xtool will automatically discover and use it. Otherwise, disambiguate with `scheme: NameOfScheme` in `xtool.yml`

## SwiftPM

xtool can also build SwiftPM packages into apps. The package must contain a _library_ product with an `@main` entrypoint. You must also declare `orgID: com.yourdomain` or `bundleID: com.yourdomain.app` in `xtool.yml`.

# Building and running

Use `xtool dev build [--configuration debug|release] [--triple ...]` to build (see `--help` for full options)

Use `xtool dev run [--configuration debug|release] [--simulator]` to build and then run on an iOS device/simulator (triple is inferred).

When running on the simulator, the command attaches stdout/stderr.

## Hot reloading SwiftUI

Use `xtool dev run -w` to build and run on the iOS Simulator with support for hot reloading SwiftUI code.

While hot reloading is active, xtool will automatically pick up edits to source files and inject the changes into the running app. You'll see output like this (lines with `#` indicate your actions):

```
[XLoad] Watching for changes...
# <FactView.swift is edited>
[Reload #1] Updating FactView.swift
[Reload #1] Built in 352ms
🔥 ✅ Hot reload complete - Rebound 19 symbols, classes []
```

Hot reloading works by interposing symbols at runtime. It works best when editing function/view bodies: SwiftUI views automatically re-render on reload. Adding types works, but changing a type's layout will crash. This is expected: just re-run the app if you change type layout.

Use hot reloading judiciously when iterating on UI. It's a strictly faster flow than not hot-reloading.
