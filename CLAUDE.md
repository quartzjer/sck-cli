# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

A lightweight macOS command-line tool that captures screenshots and audio using Apple's ScreenCaptureKit framework. The tool captures a single PNG screenshot and records 10 seconds of system audio and microphone input to an M4A file.

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

# Run the tool (builds if needed)
make run
# or
swift run sck-cli

# Clean build artifacts
make clean
```

## Architecture

The application is a single-file Swift CLI tool (`Sources/main.swift`) that:

1. **Main struct `SCKShot`**: Entry point using `@main` attribute with async main function
2. **Nested class `Output`**: Implements `SCStreamOutput` protocol to handle captured frames and audio buffers
3. **Capture flow**:
   - Discovers the primary display using `SCShareableContent`
   - Creates `SCContentFilter` for the display
   - Configures `SCStreamConfiguration` with audio capture enabled (system audio + microphone on macOS 15.0+)
   - Uses `AVAssetWriter` with AAC codec for M4A audio output
   - Captures first screen frame to PNG, then records audio for 10 seconds
   - Uses semaphore synchronization to coordinate async capture completion

## Key Technical Details

- **Platform**: macOS 15.0+ required
- **Swift version**: 6.1
- **Audio format**: M4A with AAC codec (128 kbps, 48kHz, stereo)
- **Image format**: PNG with sRGB color space
- **Frameworks used**: ScreenCaptureKit, AVFoundation, CoreImage, CoreMedia
- **Output files**: `capture.png` (screenshot), `audio.m4a` (10-second audio recording)

## Permissions Required

The tool requires macOS system permissions for:
- Screen & System Audio Recording
- Microphone (if capturing microphone input)

These must be granted in System Settings > Privacy & Security before the tool can function.

## Development Notes

- **Always run `make` after code changes** to validate the build and ensure changes compile correctly
- The tool uses `@unchecked Sendable` for the Output class to handle concurrent access
- Audio recording duration is hardcoded to 10 seconds in `audioDuration` constant
- Microphone capture is conditionally enabled for macOS 15.0+ using `#available` checks
- The tool exits immediately after capturing completes (single-shot operation)