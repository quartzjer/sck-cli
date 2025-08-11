# sck-cli

A lightweight macOS command-line tool for capturing screenshots and audio using the ScreenCaptureKit framework.

## Features

- Captures the primary display to a PNG file (`capture.png`)
- Records system audio and microphone to an M4A file (`audio.m4a`)
- Minimal dependencies - uses only system frameworks
- Fast and efficient single-frame capture with audio sample
- Written in Swift 6.1

## Requirements

- macOS 15.0 or later
- Swift 6.1 or later
- Xcode Command Line Tools

## Installation

### Using Make

```bash
# Build the executable
make build

# Run the tool
make run

# Clean build artifacts
make clean
```

### Using Swift Package Manager directly

```bash
# Build in debug mode
swift build

# Build in release mode (optimized)
swift build -c release

# Run directly
swift run sck-cli
```

## Usage

After building, run the executable to capture a screenshot:

```bash
./sck-cli
```

Or use the Makefile:

```bash
make run
```

The screenshot will be saved as `capture.png` and audio as `audio.m4a` in the current directory.

## Build Output

The built executable will be located at:
- Debug: `.build/debug/sck-cli`
- Release: `.build/release/sck-cli`

## How It Works

The tool uses Apple's ScreenCaptureKit framework to:
1. Discover available displays
2. Create a content filter for the primary display
3. Configure a stream for screen and audio capture
4. Capture one frame and save it as a PNG file
5. Capture an audio sample and save it as an M4A file
6. Exit immediately after both captures complete

## Permissions

On first run, macOS may prompt you to grant screen recording and microphone permissions. You'll need to:
1. Go to System Settings > Privacy & Security > Screen & System Audio Recording
2. Enable permissions for Terminal (or your terminal application)
3. Go to System Settings > Privacy & Security > Microphone (if capturing microphone)
4. Enable permissions for Terminal (or your terminal application)
5. Restart your terminal if needed

## License

This project is provided as-is for educational and utility purposes.
