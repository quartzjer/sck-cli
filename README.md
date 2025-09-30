# sck-cli

A lightweight macOS command-line tool for capturing screenshots and audio using the ScreenCaptureKit framework.

## Features

- Captures screenshots at configurable frame rates (default: 1 Hz)
- Supports timed capture (frame count or duration) or indefinite capture mode
- Optional audio recording (system audio + microphone on macOS 15.0+)
- High-quality output: PNG screenshots with sRGB color space, M4A audio with AAC codec
- Minimal dependencies - uses only system frameworks
- Written in Swift 6.1 with comprehensive error handling

## Requirements

- macOS 15.0 or later
- Swift 6.1 or later
- Xcode Command Line Tools

## Installation

### Using Make

```bash
# Build the executable
make build

# Run the tool with default settings
make run

# Run tests to verify functionality
make test

# Clean build artifacts
make clean

# Clean captured output files
make clean-output
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

### Basic Usage

Capture 10 screenshots at 1 Hz with audio (default behavior):

```bash
.build/debug/sck-cli
```

Or use the Makefile:

```bash
make run
```

Output files are saved in the current directory:
- `capture_0.png`, `capture_1.png`, ... `capture_9.png` - Screenshots
- `system_audio.m4a` - System audio recording
- `microphone.m4a` - Microphone recording (macOS 15.0+)

### Command-Line Options

```bash
# Show help and available options
.build/debug/sck-cli --help

# Capture 20 frames at 2 Hz without audio
.build/debug/sck-cli --frame-rate 2.0 --frames 20 --no-audio

# Capture for 30 seconds at 0.5 Hz with audio
.build/debug/sck-cli -r 0.5 -d 30

# Indefinite capture at 1 Hz (Ctrl-C to stop)
.build/debug/sck-cli --frames 0

# Capture 5 screenshots only (no audio)
.build/debug/sck-cli -n 5 --no-audio
```

### Available Options

- `-r, --frame-rate <rate>` - Screenshots per second (default: 1.0)
- `-n, --frames <count>` - Number of frames to capture (default: 10, 0 for indefinite)
- `-d, --duration <seconds>` - Capture duration (overrides frame count)
- `--audio` / `--no-audio` - Enable/disable audio capture (default: enabled)

## Build Output

The built executable will be located at:
- Debug: `.build/debug/sck-cli`
- Release: `.build/release/sck-cli`

## How It Works

The tool uses Apple's ScreenCaptureKit framework to:
1. Parse command-line arguments to determine capture settings
2. Discover available displays and select the primary display
3. Create a content filter for the display
4. Configure a stream for screen capture and optionally audio capture
5. Capture screenshots at the specified frame rate and interval
6. Optionally record system audio and microphone input to M4A files
7. Continue until the specified duration/frame count is reached or user interrupts
8. Clean up and exit gracefully

## Permissions

On first run, macOS may prompt you to grant screen recording and microphone permissions. You'll need to:
1. Go to System Settings > Privacy & Security > Screen & System Audio Recording
2. Enable permissions for Terminal (or your terminal application)
3. Go to System Settings > Privacy & Security > Microphone (if capturing microphone)
4. Enable permissions for Terminal (or your terminal application)
5. Restart your terminal if needed

## License

This project is provided as-is for educational and utility purposes.
