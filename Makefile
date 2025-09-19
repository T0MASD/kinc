.PHONY: build clean test fmt vet install

# Build the binary
build:
	go build -o kinc

# Install the binary to /usr/local/bin
install: build
	sudo mv kinc /usr/local/bin/

# Clean build artifacts
clean:
	rm -f kinc

# Run tests
test:
	go test ./...

# Format code
fmt:
	go fmt ./...

# Vet code
vet:
	go vet ./...

# Run all checks
check: fmt vet test

# Build for multiple platforms
build-all:
	GOOS=linux GOARCH=amd64 go build -o dist/kinc-linux-amd64
	GOOS=linux GOARCH=arm64 go build -o dist/kinc-linux-arm64
	GOOS=darwin GOARCH=amd64 go build -o dist/kinc-darwin-amd64
	GOOS=darwin GOARCH=arm64 go build -o dist/kinc-darwin-arm64

# Create dist directory
dist:
	mkdir -p dist

# Help
help:
	@echo "Available targets:"
	@echo "  build      - Build the kinc binary"
	@echo "  install    - Install kinc to /usr/local/bin"
	@echo "  clean      - Remove build artifacts"
	@echo "  test       - Run tests"
	@echo "  fmt        - Format code"
	@echo "  vet        - Vet code"
	@echo "  check      - Run fmt, vet, and test"
	@echo "  build-all  - Build for multiple platforms"
	@echo "  help       - Show this help message"