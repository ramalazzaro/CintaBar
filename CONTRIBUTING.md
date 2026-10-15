# Contributing

Thanks for helping out. Bug reports, treadmill reports and pull requests are all welcome.

## Reporting a treadmill

Whether CintaBar works with a treadmill can only be learned by trying it, so reports are the most
useful contribution there is, including "it just works".

Open an issue with:

- The treadmill's brand and model, and the name it advertises over Bluetooth (for example
  `FS-A1B2C3`).
- What worked and what didn't: connecting, start, pause, stop, speed, incline, time and distance.
- A log of the session, captured by running this before reproducing the problem:

  ```bash
  log stream --level debug --predicate 'subsystem == "io.github.cintabar.CintaBar"'
  ```

  Lines starting with `→` are frames sent to the treadmill and lines starting with `←` are frames
  it sent back. The log contains the names of nearby Bluetooth devices; remove any you'd rather
  not share.

## Building and testing

You need Swift 6.2 or later, from Xcode 26 or the Command Line Tools.

```bash
swift build          # Build
Scripts/test.sh      # Run the unit tests
Scripts/build.sh     # Assemble build/CintaBar.app
```

`Scripts/test.sh` is `swift test` plus the flags Swift Testing needs when only the Command Line
Tools are installed.

You don't need a treadmill to work on the menu. `--simulate` replaces Bluetooth with a pretend
one that counts down, ramps its speed and reports every second:

```bash
Scripts/build.sh && open build/CintaBar.app --args --simulate
```

Add `--miles`, `--runaway` or `--ignores-pause` after `--simulate` to have it misbehave the way
some treadmills do, and try what guards against that. The top of
[`SimulatedLink.swift`](Sources/CintaBar/SimulatedLink.swift) says what each one does.

## App icon

The icon lives in two forms. `Support/CintaBar.icon` is the Icon Composer package: open it in Icon
Composer (it ships with Xcode 26) to adjust the layers, the gradient or the Liquid Glass settings.
`Support/AppIcon.icns` is what the app bundle ships, since SwiftPM can't compile the package;
regenerate it from the package's layers with:

```bash
swift Scripts/make-icns.swift
```

## Pull requests

- Keep protocol logic and the `Treadmill` model in `TreadmillKit` and cover them with tests. The
  app target should only hold Bluetooth plumbing, the simulator and UI.
- Format before committing, and make sure the linter passes:

  ```bash
  swift format --in-place --recursive Package.swift Sources Tests
  swift format lint --strict --recursive Package.swift Sources Tests
  ```

- Follow Apple's guidance where it exists: the
  [Human Interface Guidelines](https://developer.apple.com/design/human-interface-guidelines/the-menu-bar)
  for the menu, and the
  [Core Bluetooth best practices](https://developer.apple.com/library/archive/documentation/NetworkingInternetWeb/Conceptual/CoreBluetooth_concepts/BestPracticesForInteractingWithARemotePeripheralDevice/BestPracticesForInteractingWithARemotePeripheralDevice.html)
  for the radio.
- Anything that moves the belt must come from an explicit user action. Don't add behavior that
  starts the belt or changes its speed on its own.

## License

By contributing, you agree that your contributions are licensed under the [MIT License](LICENSE).
