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

# Show help
.PHONY: help
help:
	@echo "Available targets:"
	@echo "  make build      - Build the project in debug mode (default)"
	@echo "  make release    - Build the project in release mode"
	@echo "  make run        - Build and run the tool"
	@echo "  make run-debug  - Run the debug executable directly"
	@echo "  make run-release - Run the release executable directly"
	@echo "  make clean      - Remove all build artifacts"
	@echo "  make install    - Install to /usr/local/bin (may require sudo)"
	@echo "  make uninstall  - Remove from /usr/local/bin"
	@echo "  make help       - Show this help message"