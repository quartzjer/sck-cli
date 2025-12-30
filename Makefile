# Makefile for sck-cli
# A macOS video and audio capture CLI tool

# Variables
EXECUTABLE = sck-cli
BUILD_DIR = .build
DEBUG_BUILD = $(BUILD_DIR)/arm64-apple-macosx/debug/$(EXECUTABLE)
RELEASE_BUILD = $(BUILD_DIR)/arm64-apple-macosx/release/$(EXECUTABLE)

# Distribution variables
VERSION := $(shell git describe --tags --always 2>/dev/null || echo "dev")
X86_64_BUILD = $(BUILD_DIR)/x86_64-apple-macosx/release/$(EXECUTABLE)
UNIVERSAL_DIR = $(BUILD_DIR)/universal
UNIVERSAL_BUILD = $(UNIVERSAL_DIR)/$(EXECUTABLE)
DIST_DIR = dist

# Default target
.PHONY: all
all: build

# Build in debug mode
.PHONY: build
build:
	@echo "Building $(EXECUTABLE) in debug mode..."
	swift build

# Build in release mode (optimized, native architecture)
.PHONY: release
release:
	@echo "Building $(EXECUTABLE) in release mode..."
	swift build -c release

# Build universal binary (arm64 + x86_64)
.PHONY: release-universal
release-universal:
	@echo "Building $(EXECUTABLE) universal binary..."
	@echo "  Building for arm64..."
	swift build -c release --arch arm64
	@echo "  Building for x86_64..."
	swift build -c release --arch x86_64
	@mkdir -p $(UNIVERSAL_DIR)
	@# Verify both architecture builds exist
	@test -f $(RELEASE_BUILD) || (echo "ERROR: arm64 build not found at $(RELEASE_BUILD)" && exit 1)
	@test -f $(X86_64_BUILD) || (echo "ERROR: x86_64 build not found at $(X86_64_BUILD)" && exit 1)
	@echo "  Creating universal binary with lipo..."
	lipo -create -output $(UNIVERSAL_BUILD) $(RELEASE_BUILD) $(X86_64_BUILD)
	@echo "Universal binary created: $(UNIVERSAL_BUILD)"
	@lipo -info $(UNIVERSAL_BUILD)

# Create distribution package (universal, stripped, zipped)
.PHONY: dist
dist: release-universal
	@echo "Creating distribution package..."
	@mkdir -p $(DIST_DIR)
	@# Strip symbols from a copy of the universal binary
	@cp $(UNIVERSAL_BUILD) $(DIST_DIR)/$(EXECUTABLE)
	@echo "  Stripping symbols..."
	strip -x $(DIST_DIR)/$(EXECUTABLE)
	@# Show size comparison
	@echo "  Size before strip: $$(ls -lh $(UNIVERSAL_BUILD) | awk '{print $$5}')"
	@echo "  Size after strip:  $$(ls -lh $(DIST_DIR)/$(EXECUTABLE) | awk '{print $$5}')"
	@# Create versioned zip archive
	@echo "  Creating archive..."
	@cd $(DIST_DIR) && zip -q $(EXECUTABLE)-$(VERSION).zip $(EXECUTABLE)
	@rm $(DIST_DIR)/$(EXECUTABLE)
	@# Generate SHA256 checksum
	@shasum -a 256 $(DIST_DIR)/$(EXECUTABLE)-$(VERSION).zip > $(DIST_DIR)/$(EXECUTABLE)-$(VERSION).zip.sha256
	@echo ""
	@echo "Distribution package ready:"
	@echo "  $(DIST_DIR)/$(EXECUTABLE)-$(VERSION).zip"
	@cat $(DIST_DIR)/$(EXECUTABLE)-$(VERSION).zip.sha256

# Clean distribution artifacts
.PHONY: clean-dist
clean-dist:
	@echo "Cleaning distribution artifacts..."
	rm -rf $(DIST_DIR) $(UNIVERSAL_DIR)
	@echo "Distribution artifacts cleaned."

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
	rm -rf $(BUILD_DIR) $(DIST_DIR)
	@echo "Clean complete."

# Clean captured output files
.PHONY: clean-output
clean-output:
	@echo "Cleaning capture outputs..."
	rm -f capture_*.mov capture.m4a
	@echo "Output files cleaned."

# Install to /usr/local/bin (requires sudo)
.PHONY: install
install: release-universal
	@echo "Installing $(EXECUTABLE) to /usr/local/bin..."
	@echo "Note: This may require administrator privileges."
	cp $(UNIVERSAL_BUILD) /usr/local/bin/$(EXECUTABLE)
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
	@rm -f capture_*.mov capture.m4a
	@echo "Running capture (this will take ~5 seconds)..."
	@$(DEBUG_BUILD) capture --length 5
	@echo ""
	@echo "Verifying outputs..."
	@echo ""
	@# Check for at least one video file with displayID naming
	@VIDEO_FILES=$$(ls capture_*.mov 2>/dev/null | wc -l | tr -d ' '); \
	if [ "$$VIDEO_FILES" -eq 0 ]; then \
		echo "❌ FAIL: No capture_<displayID>.mov files found"; \
		exit 1; \
	else \
		echo "✓ Found $$VIDEO_FILES video file(s)"; \
	fi
	@# Verify each video file
	@for VIDEO_FILE in capture_*.mov; do \
		echo "Checking $$VIDEO_FILE..."; \
		if ! file "$$VIDEO_FILE" | grep -q "ISO Media.*QuickTime"; then \
			echo "❌ FAIL: $$VIDEO_FILE is not a valid .mov video file"; \
			exit 1; \
		fi; \
		echo "  ✓ Valid .mov file"; \
		VIDEO_DURATION=$$(ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$$VIDEO_FILE" 2>/dev/null | cut -d. -f1); \
		if [ -z "$$VIDEO_DURATION" ]; then \
			echo "  ⚠ WARNING: Could not determine duration (ffprobe not installed?)"; \
		elif [ $$VIDEO_DURATION -lt 4 ] || [ $$VIDEO_DURATION -gt 7 ]; then \
			echo "❌ FAIL: $$VIDEO_FILE duration is $$VIDEO_DURATION seconds (expected ~5)"; \
			exit 1; \
		else \
			echo "  ✓ Duration is $$VIDEO_DURATION seconds"; \
		fi; \
		VIDEO_CODEC=$$(ffprobe -v error -select_streams v:0 -show_entries stream=codec_name -of default=noprint_wrappers=1:nokey=1 "$$VIDEO_FILE" 2>/dev/null); \
		if [ -z "$$VIDEO_CODEC" ]; then \
			echo "  ⚠ WARNING: Could not determine video codec (ffprobe not installed?)"; \
		elif [ "$$VIDEO_CODEC" = "hevc" ]; then \
			echo "  ✓ Video codec is HEVC"; \
		else \
			echo "❌ FAIL: Video codec is $$VIDEO_CODEC, expected hevc"; \
			exit 1; \
		fi; \
	done
	@# Check audio file exists and is valid
	@if [ ! -f capture.m4a ]; then \
		echo "❌ FAIL: capture.m4a not found"; \
		exit 1; \
	fi
	@if file capture.m4a | grep -q "ISO Media"; then \
		echo "✓ capture.m4a exists and is valid M4A"; \
	else \
		echo "❌ FAIL: capture.m4a is not a valid M4A file"; \
		exit 1; \
	fi
	@# Verify audio duration is ~5 seconds (4-7 second range)
	@AUDIO_DURATION=$$(ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 capture.m4a 2>/dev/null | cut -d. -f1); \
	if [ -z "$$AUDIO_DURATION" ]; then \
		echo "⚠ WARNING: Could not determine capture.m4a duration (ffprobe not installed?)"; \
	elif [ $$AUDIO_DURATION -lt 4 ] || [ $$AUDIO_DURATION -gt 7 ]; then \
		echo "❌ FAIL: capture.m4a duration is $$AUDIO_DURATION seconds (expected ~5)"; \
		exit 1; \
	else \
		echo "✓ capture.m4a duration is $$AUDIO_DURATION seconds"; \
	fi
	@# Verify audio has 2 tracks (system audio + microphone)
	@AUDIO_TRACKS=$$(ffprobe -v error -show_entries format=nb_streams -of default=noprint_wrappers=1:nokey=1 capture.m4a 2>/dev/null); \
	if [ -z "$$AUDIO_TRACKS" ]; then \
		echo "⚠ WARNING: Could not determine capture.m4a track count (ffprobe not installed?)"; \
	elif [ "$$AUDIO_TRACKS" != "2" ]; then \
		echo "❌ FAIL: capture.m4a has $$AUDIO_TRACKS track(s), expected 2 (system + microphone)"; \
		exit 1; \
	else \
		echo "✓ capture.m4a has $$AUDIO_TRACKS tracks (system audio + microphone)"; \
	fi
	@echo ""
	@echo "✅ All tests passed!"

# Show help
.PHONY: help
help:
	@echo "Available targets:"
	@echo ""
	@echo "  Development:"
	@echo "    make build           - Build in debug mode (default)"
	@echo "    make release         - Build in release mode (native arch)"
	@echo "    make run             - Build and run the tool"
	@echo "    make run-debug       - Run the debug executable directly"
	@echo "    make run-release     - Run the release executable directly"
	@echo "    make test            - Run the tool and verify outputs"
	@echo ""
	@echo "  Distribution:"
	@echo "    make release-universal - Build universal binary (arm64 + x86_64)"
	@echo "    make dist            - Create distribution package (stripped + zipped)"
	@echo ""
	@echo "  Cleanup:"
	@echo "    make clean           - Remove all build artifacts"
	@echo "    make clean-dist      - Remove distribution artifacts only"
	@echo "    make clean-output    - Remove captured video/audio files"
	@echo ""
	@echo "  Installation:"
	@echo "    make install         - Install to /usr/local/bin (may require sudo)"
	@echo "    make uninstall       - Remove from /usr/local/bin"