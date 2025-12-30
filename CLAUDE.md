# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

A lightweight macOS command-line tool that captures video and audio using Apple's ScreenCaptureKit framework. The tool captures all connected displays simultaneously, supports configurable frame rates, flexible capture durations (timed or indefinite), and optional audio recording of both system audio and microphone input. Video is encoded using hardware HEVC in .mov format with efficient NV12 pixel format.

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

# Clean captured output files (video and audio)
make clean-output
```

## Architecture

The application is a modular Swift CLI tool organized into separate concerns:

### Source Files (Sources/sck-cli/)

1. **SCKShot.swift** - CLI entry point (~320 lines)
   - Main struct using `@main` attribute with ArgumentParser
   - Parses CLI arguments: frame rate, duration, audio flags, verbose mode
   - Discovers all displays and creates one SCStream per display
   - Orchestrates multiple VideoStreamOutput instances and single AudioStreamOutput
   - Handles three completion modes: audio-driven, timer-driven, indefinite
   - Aborts all captures if any stream encounters an error

2. **AudioWriter.swift** - Audio capture logic (~190 lines)
   - Manages single AVAssetWriter with two AVAssetWriterInput instances for multi-track M4A
   - Writes system audio and microphone to separate tracks in a single file
   - Handles audio buffer timing and retiming to start from zero
   - Factory method `create()` for proper error handling
   - Thread-safe completion tracking using NSLock
   - Completion callback signals when both tracks finish

3. **VideoWriter.swift** - Video encoding logic (~150 lines)
   - AVAssetWriter-based HEVC hardware encoder for .mov output
   - Accepts NV12 CMSampleBuffers directly from ScreenCaptureKit
   - Configurable bitrate (default: 8 Mbps) and frame rate
   - Sparse keyframe intervals (30,000 frames / 3,600 seconds) for minimal file size
   - Thread-safe with NSLock for state management
   - Factory method `create()` for proper error handling

4. **StreamOutput.swift** - SCStream protocol implementations (~185 lines)
   - **VideoStreamOutput**: Handles video capture for a single display
     - Implements `SCStreamOutput` protocol for .screen type
     - One instance per display, routes frames to its VideoWriter
   - **AudioStreamOutput**: Handles audio capture (system + microphone)
     - Implements `SCStreamOutput` protocol for .audio and .microphone types
     - Single instance shared across all streams (attached to first display's stream)
     - Semaphore signaling when audio recording finishes

### Capture Flow

1. Parse CLI arguments for frame rate, duration, and audio settings
2. Discover all displays using `SCShareableContent`
3. Check for existing output files (abort if any exist)
4. Create single AudioStreamOutput for audio capture
5. For each display:
   - Create VideoStreamOutput with display-specific VideoWriter
   - Create SCContentFilter and SCStreamConfiguration
   - Create SCStream with StreamDelegate for error handling
   - Attach audio outputs only to first display's stream
6. Start all streams
7. Wait for completion (audio-driven, timer, or abort signal)
8. Stop all streams and finish all video writers
9. Exit

## Key Technical Details

- **Platform**: macOS 15.0+ required
- **Swift version**: 6.1
- **Video format**: HEVC in .mov container with NV12 pixel format, sRGB color space
- **Video encoding**: Hardware HEVC (8 Mbps default bitrate, sparse keyframes)
- **Audio format**: M4A with AAC codec (64 kbps per track, 48kHz, mono tracks)
- **Frameworks used**: ScreenCaptureKit, AVFoundation, CoreMedia, ArgumentParser
- **Multi-display**: Captures all connected displays simultaneously
- **Output files**:
  - `<base>_<displayID>.mov` - One HEVC video file per display
  - `<base>.m4a` - Multi-track audio file with 2 separate tracks (system audio + microphone)
- **CLI Options**:
  - `-r, --frame-rate` - Frame rate in Hz (default: 1.0)
  - `-l, --length` - Duration in seconds
  - `--audio/--no-audio` - Enable/disable audio (default: enabled)
  - `-v, --verbose` - Enable verbose logging

## Permissions Required

The tool requires macOS system permissions for:
- Screen & System Audio Recording
- Microphone (if capturing microphone input)

These must be granted in System Settings > Privacy & Security before the tool can function.

## Development Notes

- **Always run `make test` after code changes** to validate functionality and ensure tests pass
- **Modular architecture**: Separate files for CLI, audio, video encoding, and stream coordination
- Classes use `@unchecked Sendable` with proper NSLock synchronization for thread safety
- Audio output is optional - only created when audio flag is enabled
- Factory method pattern used for VideoWriter, AudioWriter, VideoStreamOutput, and AudioStreamOutput
- Thread-safe access to shared state using NSLock for finish flags
- NV12 pixel format minimizes conversion overhead before HEVC encoding
- Hardware HEVC encoding for efficient, small video files
- Sparse keyframe intervals (30,000 frames / 3,600 seconds) minimize file size
- Microphone capture is conditionally enabled for macOS 15.0+ using `#available` checks
- Supports three completion modes:
  - Audio-driven: waits for audio recording completion (with audio enabled)
  - Timer-driven: waits for specified duration (video-only mode)
  - Indefinite: runs until user interrupts with Ctrl-C
- Main file is named SCKShot.swift (not main.swift) to avoid Swift @main attribute conflicts
- Multi-display support: One SCStream per display, abort-on-error for any stream failure

## Testing

The `make test` target validates:
- Video capture at 1 Hz produces capture_<displayID>.mov file(s)
- Each video file is valid HEVC .mov format with correct duration (~5 seconds)
- capture.m4a file is valid M4A format with 2 tracks (system audio + microphone)
- Audio duration is within expected range (4-7 seconds)

## Dependencies

- **ffmpeg**: Used only for testing to verify video codec and audio track count
  - Install via Homebrew: `brew install ffmpeg`
  - Not required for runtime operation - AVFoundation handles all encoding natively