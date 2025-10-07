# Makefile for sck-cli
# A macOS video and audio capture CLI tool

# Variables
EXECUTABLE = sck-cli
BUILD_DIR = .build
DEBUG_BUILD = $(BUILD_DIR)/debug/$(EXECUTABLE)
RELEASE_BUILD = $(BUILD_DIR)/release/$(EXECUTABLE)

# Default target
.PHONY: all
all: build

# Build in debug mode
.PHONY: build
build:
	@echo "Building $(EXECUTABLE) in debug mode..."
	swift build

# Build in release mode (optimized)
.PHONY: release
release:
	@echo "Building $(EXECUTABLE) in release mode..."
	swift build -c release

# Run the tool (builds if needed)
.PHONY: run
run: build
	@echo "Running $(EXECUTABLE)..."
	swift run $(EXECUTABLE)

# Run the debug executable directly
.PHONY: run-debug
run-debug: build
	@echo "Running debug build..."
	$(DEBUG_BUILD)

# Run the release executable directly
.PHONY: run-release
run-release: release
	@echo "Running release build..."
	$(RELEASE_BUILD)

# Clean build artifacts
.PHONY: clean
clean:
	@echo "Cleaning build artifacts..."
	swift package clean
	rm -rf $(BUILD_DIR)
	@echo "Clean complete."

# Clean captured output files
.PHONY: clean-output
clean-output:
	@echo "Cleaning capture outputs..."
	rm -f capture.mov audio.m4a
	@echo "Output files cleaned."

# Install to /usr/local/bin (requires sudo)
.PHONY: install
install: release
	@echo "Installing $(EXECUTABLE) to /usr/local/bin..."
	@echo "Note: This may require administrator privileges."
	cp $(RELEASE_BUILD) /usr/local/bin/$(EXECUTABLE)
	@echo "Installation complete. You can now run '$(EXECUTABLE)' from anywhere."

# Uninstall from /usr/local/bin
.PHONY: uninstall
uninstall:
	@echo "Uninstalling $(EXECUTABLE) from /usr/local/bin..."
	rm -f /usr/local/bin/$(EXECUTABLE)
	@echo "Uninstallation complete."

# Test the tool by running it and verifying outputs
.PHONY: test
test: build
	@echo "Testing $(EXECUTABLE)..."
	@echo "Cleaning up any previous test outputs..."
	@rm -f capture.mov audio.m4a
	@echo "Running capture (this will take ~5 seconds)..."
	@$(DEBUG_BUILD) capture.mov --length 5
	@echo ""
	@echo "Verifying outputs..."
	@echo ""
	@# Check for video file exists
	@if [ ! -f capture.mov ]; then \
		echo "❌ FAIL: capture.mov not found"; \
		exit 1; \
	fi
	@# Verify video file is valid QuickTime/MOV
	@if file capture.mov | grep -q "ISO Media.*QuickTime"; then \
		echo "✓ capture.mov exists and is valid .mov file"; \
	else \
		echo "❌ FAIL: capture.mov is not a valid .mov video file"; \
		exit 1; \
	fi
	@# Verify video duration is ~5 seconds (4-7 second range)
	@VIDEO_DURATION=$$(ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 capture.mov 2>/dev/null | cut -d. -f1); \
	if [ -z "$$VIDEO_DURATION" ]; then \
		echo "⚠ WARNING: Could not determine capture.mov duration (ffprobe not installed?)"; \
	elif [ $$VIDEO_DURATION -lt 4 ] || [ $$VIDEO_DURATION -gt 7 ]; then \
		echo "❌ FAIL: capture.mov duration is $$VIDEO_DURATION seconds (expected ~5)"; \
		exit 1; \
	else \
		echo "✓ capture.mov duration is $$VIDEO_DURATION seconds"; \
	fi
	@# Verify video codec is H.264 or HEVC
	@VIDEO_CODEC=$$(ffprobe -v error -select_streams v:0 -show_entries stream=codec_name -of default=noprint_wrappers=1:nokey=1 capture.mov 2>/dev/null); \
	if [ -z "$$VIDEO_CODEC" ]; then \
		echo "⚠ WARNING: Could not determine video codec (ffprobe not installed?)"; \
	elif [ "$$VIDEO_CODEC" = "h264" ]; then \
		echo "✓ Video codec is H.264"; \
	elif [ "$$VIDEO_CODEC" = "hevc" ]; then \
		echo "✓ Video codec is HEVC (H.265)"; \
	else \
		echo "❌ FAIL: Video codec is $$VIDEO_CODEC, expected h264 or hevc"; \
		exit 1; \
	fi
	@# Check stereo audio file exists and is valid
	@if [ ! -f audio.m4a ]; then \
		echo "❌ FAIL: audio.m4a not found"; \
		exit 1; \
	fi
	@if file audio.m4a | grep -q "ISO Media"; then \
		echo "✓ audio.m4a exists and is valid M4A"; \
	else \
		echo "❌ FAIL: audio.m4a is not a valid M4A file"; \
		exit 1; \
	fi
	@# Verify audio duration is ~5 seconds (4-7 second range)
	@AUDIO_DURATION=$$(ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 audio.m4a 2>/dev/null | cut -d. -f1); \
	if [ -z "$$AUDIO_DURATION" ]; then \
		echo "⚠ WARNING: Could not determine audio.m4a duration (ffprobe not installed?)"; \
	elif [ $$AUDIO_DURATION -lt 4 ] || [ $$AUDIO_DURATION -gt 7 ]; then \
		echo "❌ FAIL: audio.m4a duration is $$AUDIO_DURATION seconds (expected ~5)"; \
		exit 1; \
	else \
		echo "✓ audio.m4a duration is $$AUDIO_DURATION seconds"; \
	fi
	@# Verify audio has 2 tracks (system audio + microphone)
	@AUDIO_TRACKS=$$(ffprobe -v error -show_entries format=nb_streams -of default=noprint_wrappers=1:nokey=1 audio.m4a 2>/dev/null); \
	if [ -z "$$AUDIO_TRACKS" ]; then \
		echo "⚠ WARNING: Could not determine audio.m4a track count (ffprobe not installed?)"; \
	elif [ "$$AUDIO_TRACKS" != "2" ]; then \
		echo "❌ FAIL: audio.m4a has $$AUDIO_TRACKS track(s), expected 2 (system + microphone)"; \
		exit 1; \
	else \
		echo "✓ audio.m4a has $$AUDIO_TRACKS tracks (system audio + microphone)"; \
	fi
	@echo ""
	@echo "✅ All tests passed!"

# Show help
.PHONY: help
help:
	@echo "Available targets:"
	@echo "  make build        - Build the project in debug mode (default)"
	@echo "  make release      - Build the project in release mode"
	@echo "  make run          - Build and run the tool"
	@echo "  make run-debug    - Run the debug executable directly"
	@echo "  make run-release  - Run the release executable directly"
	@echo "  make test         - Run the tool and verify outputs are valid"
	@echo "  make clean        - Remove all build artifacts"
	@echo "  make clean-output - Remove captured video and audio files"
	@echo "  make install      - Install to /usr/local/bin (may require sudo)"
	@echo "  make uninstall    - Remove from /usr/local/bin"
	@echo "  make help         - Show this help message"