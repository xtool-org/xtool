# Examples

These primarily exist as fixtures for integration tests, but also double as snippets of sample code.

Each demo is designed to make some assertions shortly after launching, and then exit. On success, stdout will include the message "xtool test succeeded".

## Testing

```
./Examples/test.sh [--build | --run] [DemoName]
```

- Omit `--build`/`--run` to build _and_ run
- Omit the demo name to loop through all demos

## Experimental React Native build on Linux

[ReactNativeLinux](ReactNativeLinux/README.md) is a separate experiment for
[issue #364](https://github.com/xtool-org/xtool/issues/364): a CocoaPods source
graph compiled with Linux Clang/LLD, then signed and installed with xtool.
It uses React Native 0.77.3, JavaScriptCore, and the legacy renderer. It is
not a SwiftPM fixture and is not included in `test.sh`.
