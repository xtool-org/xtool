# Contributing to xtool

## Bug reports and feature requests

We welcome all bug reports and feature requests! Please create a [new issue](https://github.com/xtool-org/xtool/issues/new/choose) via GitHub.

## Documentation

The xtool documentation at <https://xtool.sh> is built with [swift-docc](https://github.com/swiftlang/swift-docc) and resides at [Documentation/xtool.docc](/Documentation/xtool.docc). It's hosted on Netlify, the configuration for which is in [netlify.toml](/netlify.toml).

When editing the DocC bundle, you can preview it with `make docs-preview`.

Once you make a pull request with your changes, we'll also generate a [Netlify Deploy Preview](https://docs.netlify.com/site-deploys/deploy-previews/) under your pull request. You can open this preview to see how the changes will look in production.

## Code

When making code changes, please make sure to test them on both macOS and Linux if possible. If you can also test on Windows with WSL, that is ideal.

To build xtool for debugging, run `make` in the project directory. There are a few considerations depending on your host OS:

### macOS

On macOS, you'll firstly need to have Xcode set up.

The first time you run `make`, we'll try to detect your codesigning identity. If you have multiple, you'll see an interactive prompt to select the team you want to use. The team ID is saved to `./macOS/Support/Private-Team.xcconfig`. You can run `make team` to update it (or do so by hand).

After building, a symlink to the product will be created at `./macOS/Build/xtool`.

### Linux

You need to have a few dependencies on Linux; see [Dockerfile](/Dockerfile) for specifics. It's often easiest to develop within Docker itself: see [Linux/README.md](/Linux/README.md) for details.
