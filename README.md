# sck-cli

A macOS CLI for capturing screen video and audio using ScreenCaptureKit.

## Features

- Captures all connected displays simultaneously as HEVC video
- Records system audio and microphone to a single multi-track M4A file
- Configurable frame rate and duration

## Requirements

- macOS 15.0+
- Swift 6.1+

## Usage

```bash
# Build
make build

# Capture 10 seconds of video and audio
.build/debug/sck-cli myrecording -l 10

# Capture video only at 30 fps
.build/debug/sck-cli myrecording -l 10 -r 30 --no-audio
```

**Output files:**
- `myrecording_<displayID>.mov` - HEVC video per display
- `myrecording.m4a` - Audio (2 tracks: system + microphone)

**Options:**
- `-l, --length <seconds>` - Capture duration
- `-r, --frame-rate <Hz>` - Frame rate (default: 1.0)
- `--no-audio` - Disable audio capture
- `-v, --verbose` - Verbose logging

## Permissions

Grant access in System Settings > Privacy & Security:
- Screen & System Audio Recording
- Microphone
