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

The application is a modular Swift CLI tool organized into separate concerns:

### Source Files (Sources/sck-cli/)

1. **SCKShot.swift** - CLI entry point (151 lines)
   - Main struct using `@main` attribute with ArgumentParser
   - Parses CLI arguments: frame rate, frame count, duration, audio flags
   - Discovers displays and creates SCStream configuration
   - Orchestrates ScreenCapture, AudioWriter, and StreamOutput components
   - Handles three completion modes: audio-driven, timer-driven, indefinite

2. **AudioWriter.swift** - Audio capture logic (154 lines)
   - Manages AVAssetWriter and AVAssetWriterInput for M4A files
   - Handles audio buffer timing and retiming to start from zero
   - Factory method `create()` for proper error handling
   - Completion callbacks to signal when recording finishes
   - Separate instances for system audio and microphone

3. **ScreenCapture.swift** - Screenshot logic (64 lines)
   - Manages screenshot timing based on frame rate
   - Reusable CIContext for efficient PNG rendering
   - Tracks frame count and duration limits
   - Writes numbered PNG files (capture_0.png, capture_1.png, etc.)

4. **StreamOutput.swift** - SCStream protocol coordination (134 lines)
   - Implements `SCStreamOutput` protocol
   - Routes callbacks to ScreenCapture and AudioWriter instances
   - Thread-safe completion tracking using NSLock
   - Semaphore signaling when both audio streams finish

### Capture Flow

1. Parse CLI arguments for frame rate, duration, and audio settings
2. Discover the primary display using `SCShareableContent`
3. Create `SCContentFilter` for the display
4. Configure `SCStreamConfiguration` conditionally based on audio flag
5. Initialize StreamOutput with ScreenCapture and AudioWriter instances
6. Start capture and wait for completion (audio-driven, timer, or indefinite)
7. Stop capture and exit

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
- **Modular architecture**: Separate files for CLI, audio, screen capture, and stream coordination
- Classes use `@unchecked Sendable` with proper NSLock synchronization for thread safety
- Audio writers are optional - only created when audio flag is enabled
- Factory method pattern used for AudioWriter and StreamOutput initialization
- Thread-safe access to shared state using NSLock for finish flags
- Reusable CIContext in ScreenCapture for efficient screenshot rendering
- Microphone capture is conditionally enabled for macOS 15.0+ using `#available` checks
- Supports three completion modes:
  - Audio-driven: waits for audio recording completion (with audio enabled)
  - Timer-driven: waits for specified duration (video-only mode)
  - Indefinite: runs until user interrupts with Ctrl-C (frames = 0)
- Main file is named SCKShot.swift (not main.swift) to avoid Swift @main attribute conflicts

## Testing

The `make test` target validates:
- Screenshot capture at 1 Hz produces 10 PNG files
- PNG files are valid with correct dimensions
- Audio files (if enabled) are valid M4A format
- Audio durations are within expected range (8-12 seconds)