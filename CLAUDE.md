# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

A lightweight macOS command-line tool that captures screenshots and audio using Apple's ScreenCaptureKit framework. The tool supports configurable frame rates, flexible capture durations (timed or indefinite), and optional audio recording of both system audio and microphone input.

## Build Commands

```bash
# Build debug version (default)
make build
# or
swift build

# Build optimized release version
make release
# or
swift build -c release

# Run the tool with default settings (builds if needed)
make run
# or
swift run sck-cli

# Run comprehensive tests
make test

# Clean build artifacts
make clean

# Clean captured output files (screenshots and audio)
make clean-output
```

## Architecture

The application is a single-file Swift CLI tool (`Sources/main.swift`) that:

1. **Main struct `SCKShot`**: Entry point using `@main` attribute with ArgumentParser for CLI options
   - Supports frame rate, frame count, duration, and audio enable/disable flags
   - Calculates capture duration from frame rate and count
   - Handles indefinite capture mode (frames = 0)

2. **Class `Output`**: Implements `SCStreamOutput` protocol to handle captured frames and audio buffers
   - Factory method `create()` for proper error handling during initialization
   - Optional audio writers (AVAssetWriter) based on CLI flags
   - Thread-safe finish flag management using NSLock
   - Reusable CIContext for efficient screenshot processing

3. **Capture flow**:
   - Parses CLI arguments for frame rate, duration, and audio settings
   - Discovers the primary display using `SCShareableContent`
   - Creates `SCContentFilter` for the display
   - Configures `SCStreamConfiguration` conditionally based on audio flag
   - Captures screenshots at specified intervals (default 1 Hz)
   - Optionally records system audio and microphone to separate M4A files
   - Uses semaphore synchronization for audio completion (or timer for video-only)
   - Continues until duration/frame limit reached or user interrupts (Ctrl-C)

## Key Technical Details

- **Platform**: macOS 15.0+ required
- **Swift version**: 6.1
- **Audio format**: M4A with AAC codec (128 kbps, 48kHz, stereo)
- **Image format**: PNG with sRGB color space
- **Frameworks used**: ScreenCaptureKit, AVFoundation, CoreImage, CoreMedia, ArgumentParser
- **Output files**:
  - `capture_N.png` - Numbered screenshots (N = 0, 1, 2, ...)
  - `system_audio.m4a` - System audio recording (if audio enabled)
  - `microphone.m4a` - Microphone recording (if audio enabled, macOS 15.0+)
- **CLI Options**:
  - `-r, --frame-rate` - Frame rate in Hz (default: 1.0)
  - `-n, --frames` - Number of frames (default: 10, 0 = indefinite)
  - `-d, --duration` - Duration in seconds (overrides frame count)
  - `--audio/--no-audio` - Enable/disable audio (default: enabled)

## Permissions Required

The tool requires macOS system permissions for:
- Screen & System Audio Recording
- Microphone (if capturing microphone input)

These must be granted in System Settings > Privacy & Security before the tool can function.

## Development Notes

- **Always run `make test` after code changes** to validate functionality and ensure tests pass
- The tool uses `@unchecked Sendable` for the Output class with proper NSLock synchronization
- Audio writers are optional - only created when audio flag is enabled
- Factory method pattern used for Output initialization to handle errors gracefully
- Thread-safe access to shared state using NSLock for finish flags
- Reusable CIContext for efficient screenshot rendering
- Microphone capture is conditionally enabled for macOS 15.0+ using `#available` checks
- Supports three completion modes:
  - Audio-driven: waits for audio recording completion (with audio enabled)
  - Timer-driven: waits for specified duration (video-only mode)
  - Indefinite: runs until user interrupts with Ctrl-C (frames = 0)

## Testing

The `make test` target validates:
- Screenshot capture at 1 Hz produces 10 PNG files
- PNG files are valid with correct dimensions
- Audio files (if enabled) are valid M4A format
- Audio durations are within expected range (8-12 seconds)