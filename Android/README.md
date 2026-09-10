# Android development

Run `make android-dev` to open a development
shell with the Android Swift SDK + dependencies configured.

Build xtool for aarch64 Android (API 28) from the repository root:

```sh
make android [RELEASE=1]
```

Run the Android runtime smoke checks with an existing ARM64 AVD:

```sh
Android/smoke-test.sh Pixel_9a
```
