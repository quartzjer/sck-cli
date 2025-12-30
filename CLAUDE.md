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

- **SCKShot.swift** - CLI entry point with ArgumentParser, display discovery, stream orchestration
- **AudioWriter.swift** - Multi-track M4A writing with AVAssetWriter (system audio + microphone)
- **VideoWriter.swift** - HEVC hardware encoding to .mov with AVAssetWriter
- **StreamOutput.swift** - SCStreamOutput protocol implementations for video and audio capture

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
- **Output**: JSONL to stdout (one line per display, one for audio); all logging to stderr

## Permissions Required

The tool requires macOS system permissions for:
- Screen & System Audio Recording
- Microphone (if capturing microphone input)

These must be granted in System Settings > Privacy & Security before the tool can function.

## Development Notes

- **Always run `make test` after code changes** to validate functionality
- Classes use `@unchecked Sendable` with NSLock for thread safety
- Factory method pattern for writer and output classes
- One SCStream per display; audio attached to first display's stream only
- Three completion modes: audio-driven, timer-driven, or indefinite (Ctrl-C)

## Dependencies

- **ffmpeg**: Used only for testing (not required at runtime)
  - Install via Homebrew: `brew install ffmpeg`