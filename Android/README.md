# Android development

Build xtool for aarch64 Android (API 28) from the repository root:

```sh
docker compose run --build --rm xtool-android \
  swift build --product xtool --swift-sdk aarch64-unknown-linux-android28
```

Run `docker compose run --build --rm xtool-android` to open a development
shell.
