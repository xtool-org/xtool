# Build Your First iOS App on Linux

Use Supersign to build and deploy an iOS app from your Linux machine.

## Prerequisites

First, make sure you've set up Supersign. Follow the steps in <doc:Installation-Linux> or <doc:Installation-macOS>.

## Overview

Once you've set up Supersign, you can use it to build, package, and install iOS apps from either Linux or macOS. 

When building an iOS app on Linux, Supersign instructs SwiftPM to use the [Swift SDK for Cross Compilation](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0387-cross-compilation-destinations.md) that we built during the setup process; specifically, `arm64-apple-ios` from `darwin.artifactbundle`. This SDK contains the necessary modules for building iOS apps, such as UIKit and SwiftUI, as well as tools for building and manipulating iOS binaries. Swift SDKs are quite powerful, and you may want to check out the documentation to better understand how they work. 

## Steps

### 1. Create an iOS-capable Swift Package

Supersign comes with a template for iOS-capable Swift Packages. To create a new package, run

```bash
supersign dev new Hello
# Creating package: Hello
# Creating Package.swift
# Creating supersign.yml
# Creating .gitignore
# Creating .sourcekit-lsp/config.json
# Creating Sources/Hello/HelloApp.swift
# Creating Sources/Hello/ContentView.swift
# 
# Finished generating project Hello.

cd Hello
```

At this point, feel free to poke around. The package is structured just like a regular SwiftPM library, with the addition of two files:

- `supersign.yml`: This file describes how to bundle the Swift library into an iOS app. At minimum, you need to provide a Bundle ID. This defaults to `com.example.<PackageName>`, in this case `com.example.Hello`.
- `.sourcekit-lsp/config.json`: This file tells SourceKit to use the `arm64-apple-ios` Swift SDK. This allows IDEs like Visual Studio Code to understand how the package is built, and provide contextual IntelliSense/autocomplete suggestions related to iOS.

## 2. Build and install the app

From inside the package directory, run

```bash
supersign dev
# Planning...
# Building for debugging...
# [8/8] Linking Hello-App
# Build of product 'Hello-App' complete! (4.94s)
```

The first time you run this, SwiftPM might take a few minutes to build the app. This is because it needs to build the Swift Modules for the iOS SDK. Subsequent runs should be a lot faster since SwiftPM caches these modules globally.

After the build is complete, Supersign will attempt to install it on your device. You should see a line like

```bash
# Waiting for device to be connected...
```

At this point, connect your iOS device to your computer via USB. If you installed `libimobiledevice-utils` during setup, you can verify that your device is connected by running `ideviceinfo`. Supersign will continue after automatically detecting that your device is connected.

> Pairing:
>
> The first time you run `supersign dev`, you may see a "Trust" dialog on your iOS device to proceed with pairing. Tap **Trust** and enter your passcode on iOS. Supersign may throw an error after this: if so, just run `supersign dev` again.

Supersign will now connect to Apple Developer Services, register your device with your Apple ID, generate a Certificate + App ID + Provisioning Profile, sign the app, and then install it.

```bash
# Installing to device: Kabir's iPhone (udid: *****)
# 
# [Unpacking app] 100%
# [Logging in] 100%
# [Preparing device] 100%
# [Provisioning] 100%
# [Signing] 100%
# [Packaging] 100%
# [Connecting] 100%
# [Installing] 100%
# [Verifying]  100%
```

> Enable Development Mode:
>
> At this point, you may run into an error asking you to enable **Development Mode** on your iOS device. Follow [these instructions](https://developer.apple.com/documentation/xcode/enabling-developer-mode-on-a-device) and then run `supersign dev` again.

## 3. Run the app

You should now see the app on your iOS device's home screen / App Library. Tap it to launch the app. You should see a "Hello World" message!

> Trust Your Certificate:
>
> The first time you launch the app, you might get an "Untrusted Developer" alert. To trust your developer identity, go to **Settings** > **General** > **VPN & Device Management** > _[your email]_ > **Trust**. You should now be able to launch the app.

@Row(numberOfColumns: 2) {
    @Column {
        ![Hello world app](HelloWorld)
    }
}

## 4. Edit the app

Open the project folder in your favorite IDE. As long as it supports Swift [via SourceKit-LSP](https://github.com/swiftlang/sourcekit-lsp/blob/242609dcad55824d9eb23269c0aeead187fd0faa/Documentation/Editor%20Integration.md), it should be able to understand your iOS project thanks to the `.sourcekit-lsp/config.json` file in the template.

For example, if you're using Visual Studio Code, this means you need to install the [Swift extension](https://marketplace.visualstudio.com/items?itemName=swiftlang.swift-vscode).

In `Sources/Hello/ContentView.swift`, let's update the "Hello, world!" text to be bold and purple:

```diff
 import SwiftUI

 struct ContentView: View {
     var body: some View {
         VStack {
             Image(systemName: "globe")
                 .imageScale(.large)
                 .foregroundStyle(.tint)
             Text("Hello, world!")
+                .bold()
+                .foregroundStyle(.purple)
         }
         .padding()
     }
 }
```

While you do this, if you've correctly configured your editor with Swift support you should receive intelligent autocomplete suggestions.

![Autocomplete](Autocomplete)

## 5. Re-install the app

Run `supersign dev` again to re-build and re-install. This should go a lot faster than the first time.

Launch the app again to see the updated text!

@Row(numberOfColumns: 2) {
    @Column {
        ![Modified hello world app](HelloWorld-Purple)
    }
}
