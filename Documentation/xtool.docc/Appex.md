# Create App Extensions

Add app extensions to your iOS app.

## Overview

iOS includes several [App Extension Points](https://developer.apple.com/documentation/technologyoverviews/app-extensions) to deeply integrate with system functionality: such as Widgets, Share Extensions, and Safari Extensions. With a little setup, you can create App Extensions with xtool.

This guide will show you how to add a **Widget Extension** to your app. The steps are similar for other extensions as well.

> Note: This guide assumes you already have an xtool-based application up and running. If you don't, create one first with <doc:First-app>.

## Step 1: Add a new product

Start by adding a new product declaration to your `Package.swift`.

```diff
  // swift-tools-version: 6.0
  
  import PackageDescription
  
  let package = Package(
      name: "Hello",
      platforms: [.iOS(.v17)],
      products: [
          .library(
              name: "Hello",
              targets: ["Hello"]
          ),
+         .library(
+             name: "HelloWidget",
+             targets: ["HelloWidget"]
+         ),
      ],
      targets: [
          .target(name: "Hello"),
+         .target(name: "HelloWidget"),
      ]
  )
```

Also create a new empty file at `Sources/HelloWidget/Widget.swift`.

```bash
mkdir Sources/HelloWidget
touch Sources/HelloWidget/Widget.swift
```

## Step 2: Update xtool.yml

Now that we have two products, we'll need to tell xtool which one corresponds to the _application_ and which one corresponds to the _extension_.

You should already have a bare-bones `xtool.yml` file that describes metadata about your package (the bundle ID, at the bare minimum.) We'll add the new information to this file.

```diff
  version: 1
  bundleID: com.example.Hello
+ product: Hello
+ extensions:
+   - product: HelloWidget
+     infoPath: HelloWidget-Info.plist
```

## Step 3: Add an Info.plist

App extensions require an `Info.plist` file that tells the system what kind of extension they are, amongst other things. In the previous step, we promised xtool that this file will be located at `./HelloWidget-Info.plist` in your project. We'll now create this file.

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>NSExtension</key>
    <dict>
        <key>NSExtensionPointIdentifier</key>
        <string>com.apple.widgetkit-extension</string>
    </dict>
</dict>
</plist>
```

> Note:
>
> The value `com.apple.widgetkit-extension` tells the system that this is a Widget Extension. If you're creating a different type of Extension, your `Info.plist` might look different.
>
> For a list of possible `NSExtensionPointIdentifier` values, see [Apple's documentation](https://developer.apple.com/documentation/bundleresources/information-property-list/nsextension/nsextensionpointidentifier) on the subject. You may also need other keys like `NSExtensionPrincipalClass`: refer to Apple's ~better~ legacy [documentation library](https://developer.apple.com/library/archive/documentation/General/Reference/InfoPlistKeyReference/Articles/AppExtensionKeys.html) for details.
>
> Finally, note that the above refers to the old paradigm of **Foundation Extensions**. Apple has started moving towards a newer framework called **ExtensionKit** for recent extension types. The main difference for extension consumers is that you replace `NSExtension -> EXAppExtensionAttributes`, and `NSExtensionPointIdentifier -> EXExtensionPointIdentifier`. xtool doesn't support ExtensionKit yet, but it's [planned](https://github.com/xtool-org/xtool/issues/138).

## Step 4: Code your widget 

We can finally write the code for the widget! Let's open `Sources/HelloWidget/Widget.swift` and create a simple widget that displays the current date.

```swift
import WidgetKit
import SwiftUI

@main struct Bundle: WidgetBundle {
    var body: some Widget {
        HelloWidget()
    }
}

struct HelloWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(
            kind: "HelloWidget",
            provider: Provider()
        ) { entry in
            VStack {
                Text(entry.date, style: .date)
            }
            .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("HelloWidget")
        .description("This is an example widget.")
    }

    struct Entry: TimelineEntry {
        var date = Date()
    }

    struct Provider: TimelineProvider {
        func placeholder(in context: Context) -> Entry {
            Entry()
        }

        func getSnapshot(
            in context: Context,
            completion: @escaping (Entry) -> Void
        ) {
            completion(Entry())
        }

        func getTimeline(
            in context: Context,
            completion: @escaping (Timeline<Entry>) -> Void
        ) {
            completion(Timeline(
                entries: [Entry()],
                policy: .after(.now + 3600)
            ))
        }
    }
}
```

> Note: Blindly refreshing once an hour isn't a great strategy in practice but it makes for a short snippet. I never said this was a tutorial on writing _good_ WidgetKit code: there's plenty of other resources online if that's your goal!

Finally, build and run with `xtool dev`. You should be able to find the widget in your widget library. 
