# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

A lightweight macOS command-line tool that captures video and audio using Apple's ScreenCaptureKit framework. The tool supports configurable frame rates, flexible capture durations (timed or indefinite), and optional audio recording of both system audio and microphone input. Video is encoded using hardware H.264 in .mov format with efficient NV12 pixel format.

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

1. **SCKShot.swift** - CLI entry point (~170 lines)
   - Main struct using `@main` attribute with ArgumentParser
   - Parses CLI arguments: frame rate, frame count, duration, audio flags
   - Discovers displays and creates SCStream configuration with NV12 pixel format
   - Orchestrates VideoWriter, AudioWriter, and StreamOutput components
   - Handles three completion modes: audio-driven, timer-driven, indefinite

2. **AudioWriter.swift** - Audio capture logic (~190 lines)
   - Manages single AVAssetWriter with two AVAssetWriterInput instances for multi-track M4A
   - Writes system audio and microphone to separate tracks in a single file
   - Handles audio buffer timing and retiming to start from zero
   - Factory method `create()` for proper error handling
   - Thread-safe completion tracking using NSLock
   - Completion callback signals when both tracks finish

3. **VideoWriter.swift** - Video encoding logic (~130 lines)
   - AVAssetWriter-based H.264 hardware encoder for .mov output
   - Accepts NV12 CMSampleBuffers directly from ScreenCaptureKit
   - Configurable bitrate (default: 2 Mbps) and frame rate
   - Sparse keyframe intervals (30,000 frames / 3,600 seconds) for minimal file size
   - Thread-safe with NSLock for state management
   - Factory method `create()` for proper error handling

4. **StreamOutput.swift** - SCStream protocol coordination (~100 lines)
   - Implements `SCStreamOutput` protocol
   - Routes callbacks to VideoWriter and AudioWriter instances
   - Single AudioWriter instance handles both audio tracks natively
   - Semaphore signaling when audio recording finishes
   - Completion method for finishing video writing

### Capture Flow

1. Parse CLI arguments for frame rate, duration, and audio settings
2. Discover the primary display using `SCShareableContent`
3. Create `SCContentFilter` for the display
4. Configure `SCStreamConfiguration` with NV12 pixel format and minimumFrameInterval
5. Initialize StreamOutput with VideoWriter and AudioWriter instances
6. Start capture and wait for completion (audio-driven, timer, or indefinite)
7. Stop capture and finish video writing to capture.mov
8. AudioWriter writes both tracks to single audio.m4a file natively
9. Exit

## Key Technical Details

- **Platform**: macOS 15.0+ required
- **Swift version**: 6.1
- **Video format**: H.264 in .mov container with NV12 pixel format, sRGB color space
- **Video encoding**: Hardware H.264 (2 Mbps default bitrate, sparse keyframes)
- **Audio format**: M4A with AAC codec (64 kbps per track, 48kHz, mono tracks)
- **Frameworks used**: ScreenCaptureKit, AVFoundation, CoreMedia, ArgumentParser
- **Output files**:
  - `capture.mov` - H.264 video file
  - `audio.m4a` - Multi-track audio file with 2 separate tracks (system audio + microphone)
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
- **Modular architecture**: Separate files for CLI, audio, video encoding, and stream coordination
- Classes use `@unchecked Sendable` with proper NSLock synchronization for thread safety
- Audio writers are optional - only created when audio flag is enabled
- Factory method pattern used for VideoWriter, AudioWriter, and StreamOutput initialization
- Thread-safe access to shared state using NSLock for finish flags
- NV12 pixel format minimizes conversion overhead before H.264 encoding
- Hardware H.264 encoding for efficient, small video files
- Sparse keyframe intervals (30,000 frames / 3,600 seconds) minimize file size
- Microphone capture is conditionally enabled for macOS 15.0+ using `#available` checks
- Supports three completion modes:
  - Audio-driven: waits for audio recording completion (with audio enabled)
  - Timer-driven: waits for specified duration (video-only mode)
  - Indefinite: runs until user interrupts with Ctrl-C (frames = 0)
- Main file is named SCKShot.swift (not main.swift) to avoid Swift @main attribute conflicts

## Testing

The `make test` target validates:
- Video capture at 1 Hz produces capture.mov file
- Video file is valid H.264 .mov format with correct duration
- audio.m4a file is valid M4A format with 2 tracks (system audio + microphone)
- Audio duration is within expected range (8-12 seconds)

## Dependencies

- **ffmpeg**: Used only for testing to verify audio track count
  - Install via Homebrew: `brew install ffmpeg`
  - Not required for runtime operation - AVFoundation handles all audio writing natively