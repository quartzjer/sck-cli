# sck-cli

> A utility developed for [solstone](https://github.com/solpbc/solstone).

A macOS CLI for capturing screen video and audio using ScreenCaptureKit.

## Features

- Captures all connected displays simultaneously as HEVC video
- Records system audio and microphone to a multi-track M4A file
- Confidential window masking (black out specified apps)
- Timed or indefinite capture with graceful shutdown

## Requirements

- macOS 15.0+
- Permissions: Screen Recording, System Audio, Microphone (System Settings > Privacy & Security)

## Installation

```bash
make install        # Builds universal binary and installs to /usr/local/bin
```

Or download from [releases](https://github.com/solpbc/solstone/releases).

## Usage

```bash
# Capture 10 seconds at default 1 Hz
sck-cli recording -l 10

# Capture indefinitely at 30 fps (Ctrl-C to stop)
sck-cli recording -r 30

# Video only, mask sensitive apps
sck-cli recording -l 60 --no-audio --mask 1Password --mask Messages
```

### Options

| Option | Description | Default |
|--------|-------------|---------|
| `<output>` | Base filename (required) | - |
| `-l, --length <sec>` | Capture duration | indefinite |
| `-r, --frame-rate <Hz>` | Frame rate | 1.0 |
| `--audio / --no-audio` | Enable/disable audio | enabled |
| `--mask <app>` | App name to mask (repeatable) | - |
| `-v, --verbose` | Verbose logging | off |

### Output

**Files created:**
- `<output>_<displayID>.mov` - HEVC video per display
- `<output>.m4a` - Audio (2 tracks: system + microphone)

**JSONL to stdout** (one line per event):
```json
{"displayID":1,"filename":"recording_1.mov","frameRate":1,"height":1080,"type":"display","width":1920,"x":0,"y":0}
{"channels":1,"filename":"recording.m4a","sampleRate":48000,"tracks":[{"deviceName":"MacBook Pro Speakers","deviceUID":"BuiltInSpeakerDevice","manufacturer":"Apple Inc.","name":"system","transportType":"built-in"},{"deviceName":"MacBook Pro Microphone","deviceUID":"BuiltInMicrophoneDevice","manufacturer":"Apple Inc.","name":"microphone","transportType":"built-in"}],"type":"audio"}
{"reason":"completed","type":"stop"}
```

**Stop event reasons:**

| Reason | Description | Extra Fields |
|--------|-------------|--------------|
| `completed` | Duration elapsed or audio finished | - |
| `device-change` | Audio device changed (for watchdog restart) | `inputDeviceChanged`, `outputDeviceChanged` |
| `error` | Stream error occurred | `errorCode`, `errorDomain` |
| `signal` | User interrupt (Ctrl-C) | - |

### Signal Handling

- **Ctrl-C (SIGINT/SIGTERM)**: Graceful shutdown - finishes writing files
- **Second Ctrl-C**: Force immediate exit

### Exit Codes

| Code | Meaning |
|------|---------|
| 0 | Success (includes device-change for watchdog restart) |
| 1 | Error |
| 130 | Interrupted (SIGINT) |
| 143 | Terminated (SIGTERM) |

## Development

```bash
make build              # Debug build
make release            # Optimized release build
make test               # Run tests (requires ffmpeg)
make clean              # Remove build artifacts
```

See [CLAUDE.md](CLAUDE.md) for architecture details and development notes.

## License

MIT License. See [LICENSE](LICENSE) for details.
