# CintaBar

A tiny macOS menu bar app for controlling a FitShow-compatible Bluetooth treadmill: start, pause,
stop and change speed without reaching for your phone. *Cinta* is Spanish for treadmill.

> [!WARNING]
> **Early days.** CintaBar has met one treadmill so far, a Noga FT-200, which it drives over
> FTMS: finding it, connecting, live telemetry and stopping the belt are confirmed there. The
> FitShow proprietary path is unit tested but hasn't been tried on real hardware. If you use it
> on any treadmill, please [report how it went](CONTRIBUTING.md#reporting-a-treadmill).

## Features

- Start, pause, resume and stop the belt.
- Start straight at a chosen speed, and change it in 0.1 or 0.5 km/h steps.
- Incline control on treadmills with a motorized incline.
- Live speed, elapsed time and distance, in the menu and, if you like, next to the icon.
- Remembers your treadmill and reconnects when it powers on, without scanning.
- Speaks both the standard Fitness Machine Service (FTMS) and FitShow's proprietary protocol.
- Sandboxed, with Bluetooth as its only entitlement. No network access, no analytics.
- Small: a binary under 500 KB, about 25 MB of memory, and no dependencies.

## Requirements

- macOS 14 or later.
- To build: Swift 6.2 or later, from Xcode 26 or the Command Line Tools.

## Install

There are no prebuilt releases yet. Clone the repository and build it:

```bash
Scripts/build.sh --install
```

This builds `build/CintaBar.app`, copies it to `/Applications` and launches it. Leave out
`--install` to only build.

The app is signed ad hoc, so macOS asks for Bluetooth permission again after every rebuild. To
avoid that, sign with a certificate of your own:

```bash
CODESIGN_IDENTITY="Apple Development: Your Name (TEAMID)" Scripts/build.sh --install
```

## Usage

1. Turn the treadmill on and launch CintaBar. Allow Bluetooth when macOS asks.
2. Click the treadmill icon in the menu bar and choose **Connect to …** for your treadmill.
   FitShow modules are usually named `FS-` followed by a few characters. If yours isn't listed,
   look under **Other Devices**.
3. Use **Start**, or **Start At** to go straight to a speed once the countdown ends.

**Show in Menu Bar** picks what appears next to the icon while you walk: speed, time, distance,
any combination, or nothing.

CintaBar only ever connects to a treadmill you picked, and it remembers that choice. From then on
it reconnects by itself whenever the treadmill powers on. **Forget …** drops the choice.

Make sure the vendor's phone app isn't connected at the same time: most treadmills accept a single
Bluetooth connection.

## Safety

This software moves a motorized belt that someone may be standing on.

- Keep the safety key attached, and keep the treadmill's own stop button within reach.
- CintaBar never starts the belt or changes its speed on its own; every command comes from a
  click.
- If the Bluetooth link drops, the treadmill keeps doing what it was doing. Stop it from its
  console.

CintaBar is not affiliated with FitShow, Noga or any treadmill manufacturer. It comes with no
warranty; see the [license](LICENSE).

## How it works

The code is split in two:

- [`TreadmillKit`](Sources/TreadmillKit) holds the two wire protocols and the `Treadmill` model
  the menu is built on. It has no Bluetooth or UI code, so all of it is unit tested.
- [`CintaBar`](Sources/CintaBar) is the app: a Core Bluetooth link that feeds the model, a
  simulated link for development, and an AppKit status item whose menu updates in place while
  it's open.

On connecting, CintaBar looks for these GATT services and uses the first one it finds:

| Protocol | Service | How it behaves |
| --- | --- | --- |
| [FTMS](https://www.bluetooth.com/specifications/specs/fitness-machine-service-1-0/) | `1826` | The Bluetooth SIG standard. The treadmill pushes telemetry; commands go to a control point. |
| FitShow | `FFF0` or `FFE0` | Proprietary. The treadmill only answers when asked, so its status is polled. |

A FitShow frame is `02 | command | parameters… | checksum | 03`, where the checksum is the XOR of
the command and parameter bytes:

| Frame | Meaning |
| --- | --- |
| `02 51 51 03` | Query status |
| `02 53 01 00 00 00 00 00 00 00 00 52 03` | Start, or resume |
| `02 53 02 23 00 72 03` | Go to 3.5 km/h (`0x23` tenths) at incline 0 |
| `02 53 06 55 03` | Pause |
| `02 53 03 50 03` | Stop |

When a treadmill offers both protocols, the menu shows a **Protocol** picker to switch.

## Troubleshooting

CintaBar logs to the unified logging system. To watch what it sees and every frame it exchanges
with the treadmill:

```bash
log stream --level debug --predicate 'subsystem == "io.github.cintabar.CintaBar"'
```

- **The treadmill doesn't show up.** Check that it's on and that no phone is connected to it,
  then choose **Search Again**. The log lists every named device the search saw.
- **"Allow Bluetooth for CintaBar…"** Turn it on in System Settings › Privacy & Security ›
  Bluetooth.
- **It connects but commands do nothing.** If the menu offers a **Protocol** picker, try the
  other one, and please [report it](CONTRIBUTING.md#reporting-a-treadmill) with the log.

## Development

```bash
swift build          # Build
Scripts/test.sh      # Run the unit tests
swift format lint --strict --recursive Package.swift Sources Tests
```

To work on the app without a treadmill, launch it with a simulated one:

```bash
Scripts/build.sh && open build/CintaBar.app --args --simulate
```

See [CONTRIBUTING.md](CONTRIBUTING.md) for more.

## Acknowledgments

The FitShow protocol is undocumented. What CintaBar knows about it was learned from
[qdomyos-zwift](https://github.com/cagnulein/qdomyos-zwift), which supports a great many fitness
machines. CintaBar is an independent implementation and shares no code with it.

## License

[MIT](LICENSE)
