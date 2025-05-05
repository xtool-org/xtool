# Control your app's structure

Add resources, modify your `Info.plist`, and more. 

## Overview

When building your app, Supersign provides many knobs to add resources and modify files in its `.app` bundle. This article explains how to perform some common tasks along these lines.

Many of the tasks here involve modifying the `supersign.yml` file. The default `supersign dev new` template should generate this file for you. If you don't have it, make sure you create one first.

```bash
cat > supersign.yml << EOF
version: 1
bundleID: com.example.Hello
EOF
```

## Change your Bundle ID

You can update your app's bundle ID by editing the `bundleID` field in `supersign.yml`.

> Note:
>
> Supersign adds a prefix to your bundle ID when signing and installing the app on a real device. For example, it may update the above bundle id to `SC-1234.com.example.Hello`. This is because, at least with free accounts (those not enrolled in the Apple Developer Program), two accounts cannot use the same bundle ID. Prefixing ensures that if you share your app with someone else, they won't run into a bundle ID conflict when installing it.
>
> With additional engineering effort, this limitation could be lifted for paid Developer Program users by leveraging wildcard provisioning profiles. If you have a concrete use case for this and/or wish to contribute, please [file an issue](https://github.com/SuperchargeApp/Supersign/issues/new).

## Customize Info.plist

Supersign automatically generates a bare-bones `Info.plist` file for you. However, you may need to add new `Info.plist` keys or edit existing ones.

To do this, create an `Info.plist` file in your project containing just the keys you want to add/update, and tell Supersign about it by adding the `infoPath` key:

```yaml
infoPath: path/to/Info.plist
```

> Tip:
>
> After running `supersign dev [build]`, you can inspect the built app bundle at `./supersign/YourApp.app` to view its `Info.plist` and other resources. 

For example, you might create an `Info.plist` file that looks something like

```plist
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>UISupportedInterfaceOrientations</key>
    <array>
        <string>UIInterfaceOrientationLandscapeLeft</string>
        <string>UIInterfaceOrientationLandscapeRight</string>
    </array>
    <key>CFBundleDisplayName</key>
    <string>My App</string>
</dict>
</plist>
```

- The default `Info.plist` has a `UISupportedInterfaceOrientations` value of portrait. This will replace it with landscape-only.
- We don't include a `CFBundleDisplayName` by default, so this will add the key and specify a display name of "My App".

## Copy Resources (SwiftPM)

If you need to include non-code resource files, like images, the easiest way to do so is to use [SwiftPM Resources](https://developer.apple.com/documentation/xcode/bundling-resources-with-a-swift-package). These "just work" with Supersign.

For example, if you have `Sources/Hello/Blob.png`, you can include it in your app by updating the `targets` in your `Package.swift` to

```swift
targets: [
    .target(
        name: "Hello",
        resources: [.copy("Blob.png")]
    ),
]
```

Then, to draw it on screen, you can use

```swift
Image("Blob", bundle: Bundle.module)
```

## Copy Resources (Top Level)

SwiftPM resources are copied into `.bundle` directories nested inside your `.app`. Sometimes, you need to place a file in a specific location in the app directory instead.

To achieve this, you can include a `resources` array in your `supersign.yml` containing a list of files that should be directly included at the root level of the app bundle.

For example, if you use Firebase, you usually need to include a [`GoogleServices-Info.plist`](https://firebase.google.com/docs/ios/setup#add-config-file) file in your root bundle. If you saved this file in your project directory at `./Resources/GoogleServices-Info.plist`, you can update your `supersign.yml` with

```yaml
resources:
- Resources/GoogleServices-Info.plist
```

The file will be copied to `Hello.app/GoogleServices-Info.plist`.

## Add an App Icon

Say your app icon is saved at `Resources/AppIcon.png`. You can make this your app icon by setting the `iconPath` key in `supersign.yml`:

```yaml
iconPath: Resources/AppIcon.png
```

> Tip:
>
> Your app icon must be a png, and it should ideally have a resolution of 1024x1024px.
