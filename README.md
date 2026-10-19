# Stackvale

Stackvale is a native macOS app for organizing local development projects and
managing the services that run with them.

## Download

Download the latest macOS release from the
[GitHub Releases page](https://github.com/davisbento/stackvale/releases/latest).

The release workflow builds and publishes `Stackvale.dmg` whenever a `v*` tag
is pushed.

## Build locally

Stackvale requires macOS and Xcode. Build the app from the repository root:

```bash
make build
```

Create a release DMG locally with:

```bash
make dmg
```

The DMG is written to `dist/Stackvale.dmg`.

## Contributing

This repository is public and welcomes contributions. You can modify the
source code, build and run Stackvale on your own computer, open issues, and
submit pull requests. Contributions are welcome, but they are not guaranteed
to be accepted or included in a release.

## License

Stackvale is available under the MIT License. See [LICENSE](LICENSE) for the
full text.

The MIT License allows you to use, copy, modify, merge, publish, distribute,
sublicense, and sell copies of the software, subject to the license terms.
