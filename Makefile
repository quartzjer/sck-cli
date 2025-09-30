# Makefile for sck-cli
# A macOS screenshot capture CLI tool

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
	rm -f capture_*.png system_audio.m4a microphone.m4a
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
	@rm -f capture_*.png system_audio.m4a microphone.m4a
	@echo "Running capture (this will take ~10 seconds)..."
	@$(DEBUG_BUILD)
	@echo ""
	@echo "Verifying outputs..."
	@echo ""
	@# Check for PNG screenshots (expecting ~10 files at 1Hz over 10 seconds)
	@SCREENSHOT_COUNT=$$(ls -1 capture_*.png 2>/dev/null | wc -l | tr -d ' '); \
	if [ $$SCREENSHOT_COUNT -lt 8 ]; then \
		echo "❌ FAIL: Expected at least 8 screenshots, found $$SCREENSHOT_COUNT"; \
		exit 1; \
	else \
		echo "✓ Found $$SCREENSHOT_COUNT screenshot(s)"; \
	fi
	@# Verify first screenshot is valid PNG
	@if file capture_0.png | grep -q "PNG image data"; then \
		DIMENSIONS=$$(file capture_0.png | sed -n 's/.*PNG image data, \([0-9]* x [0-9]*\).*/\1/p'); \
		echo "✓ capture_0.png is valid PNG ($$DIMENSIONS)"; \
	else \
		echo "❌ FAIL: capture_0.png is not a valid PNG file"; \
		exit 1; \
	fi
	@# Check system audio file exists and is valid
	@if [ ! -f system_audio.m4a ]; then \
		echo "❌ FAIL: system_audio.m4a not found"; \
		exit 1; \
	fi
	@if file system_audio.m4a | grep -q "ISO Media"; then \
		echo "✓ system_audio.m4a exists and is valid M4A"; \
	else \
		echo "❌ FAIL: system_audio.m4a is not a valid M4A file"; \
		exit 1; \
	fi
	@# Verify system audio duration is ~10 seconds (8-12 second range)
	@SYSTEM_DURATION=$$(ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 system_audio.m4a 2>/dev/null | cut -d. -f1); \
	if [ -z "$$SYSTEM_DURATION" ]; then \
		echo "⚠ WARNING: Could not determine system_audio.m4a duration (ffprobe not installed?)"; \
	elif [ $$SYSTEM_DURATION -lt 8 ] || [ $$SYSTEM_DURATION -gt 12 ]; then \
		echo "❌ FAIL: system_audio.m4a duration is $$SYSTEM_DURATION seconds (expected ~10)"; \
		exit 1; \
	else \
		echo "✓ system_audio.m4a duration is $$SYSTEM_DURATION seconds"; \
	fi
	@# Check microphone file exists and is valid
	@if [ ! -f microphone.m4a ]; then \
		echo "❌ FAIL: microphone.m4a not found"; \
		exit 1; \
	fi
	@if file microphone.m4a | grep -q "ISO Media"; then \
		echo "✓ microphone.m4a exists and is valid M4A"; \
	else \
		echo "❌ FAIL: microphone.m4a is not a valid M4A file"; \
		exit 1; \
	fi
	@# Verify microphone duration is ~10 seconds (8-12 second range)
	@MIC_DURATION=$$(ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 microphone.m4a 2>/dev/null | cut -d. -f1); \
	if [ -z "$$MIC_DURATION" ]; then \
		echo "⚠ WARNING: Could not determine microphone.m4a duration (ffprobe not installed?)"; \
	elif [ $$MIC_DURATION -lt 8 ] || [ $$MIC_DURATION -gt 12 ]; then \
		echo "❌ FAIL: microphone.m4a duration is $$MIC_DURATION seconds (expected ~10)"; \
		exit 1; \
	else \
		echo "✓ microphone.m4a duration is $$MIC_DURATION seconds"; \
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
	@echo "  make clean-output - Remove captured screenshots and audio files"
	@echo "  make install      - Install to /usr/local/bin (may require sudo)"
	@echo "  make uninstall    - Remove from /usr/local/bin"
	@echo "  make help         - Show this help message"