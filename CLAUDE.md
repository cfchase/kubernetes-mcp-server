# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is a Kubernetes Model Context Protocol (MCP) server implementation written in Go. It provides a native, high-performance interface to Kubernetes clusters without requiring external dependencies like kubectl or helm CLI tools. The server exposes Kubernetes operations through MCP tools that can be consumed by AI assistants.

## Key Commands

### Building and Development
```bash
# Build the project (cleans, tidies, formats, then builds)
make build

# Build for all platforms
make build-all-platforms

# Run tests
make test
go test -count=1 -v ./...

# Format code
make format
go fmt ./...

# Tidy dependencies
make tidy
go mod tidy

# Clean build artifacts
make clean
```

### Container Management
```bash
# Build container image (defaults to podman, quay.io/cfchase/kubernetes-mcp-server:latest)
make container-build

# Push container image to registry
make container-push

# Build and push in one command
make container-build-push

# Override defaults via environment or .env file:
# CONTAINER_RUNTIME=docker (default: podman)
# CONTAINER_REGISTRY=quay.io (default: quay.io)
# CONTAINER_NAMESPACE=cfchase (default: cfchase)
# CONTAINER_IMAGE_NAME=kubernetes-mcp-server (default: kubernetes-mcp-server)
# CONTAINER_TAG=latest (default: latest)
```

### Running the Server
```bash
# Run with default stdio transport
./kubernetes-mcp-server

# Run with SSE transport on port 8080
./kubernetes-mcp-server --sse-port 8080

# Run with HTTP transport on port 8080
./kubernetes-mcp-server --port 8080

# Run with specific kubeconfig
./kubernetes-mcp-server --kubeconfig /path/to/config

# Run in read-only mode
./kubernetes-mcp-server --read-only

# Run with debug logging
./kubernetes-mcp-server --log-level 9
```

### Development and Testing
```bash
# Run with mcp-inspector for debugging
make build
npx @modelcontextprotocol/inspector@latest $(pwd)/kubernetes-mcp-server
```

## Architecture

### Core Components

1. **MCP Server Layer** (`pkg/mcp/`)
   - `mcp.go`: Main MCP server implementation and configuration
   - `profiles.go`: Tool profiles (currently only "full" profile)
   - Tool implementations: `pods.go`, `resources.go`, `helm.go`, etc.

2. **Kubernetes Client Layer** (`pkg/kubernetes/`)
   - `kubernetes.go`: Core Kubernetes client manager
   - `configuration.go`: Kubeconfig handling and watching
   - Resource-specific operations: `pods.go`, `resources.go`, `events.go`

3. **Configuration** (`pkg/config/`)
   - `config.go`: Configuration file parsing and static config handling

4. **CLI Interface** (`pkg/kubernetes-mcp-server/cmd/`)
   - `root.go`: Main CLI command and option handling

5. **Entry Point** (`cmd/kubernetes-mcp-server/`)
   - `main.go`: Application entry point

### Key Design Patterns

- **Native Kubernetes Client**: Uses official Kubernetes Go client libraries directly
- **Tool-based Architecture**: Each Kubernetes operation is exposed as an MCP tool
- **Profile System**: Tools are grouped into profiles (extensible for different use cases)
- **Configuration Watching**: Automatically reloads when kubeconfig changes
- **Multiple Transport Support**: STDIO, SSE, and HTTP transports

### Tool Categories

The server exposes Kubernetes operations through these tool categories:
- **Configuration**: View kubeconfig
- **Pods**: List, get, delete, logs, exec, run, top
- **Resources**: Generic CRUD operations for any Kubernetes resource
- **Events**: List cluster events
- **Namespaces**: List namespaces
- **Helm**: Install, list, uninstall charts
- **OpenShift**: List projects

### Configuration Options

- `--profile`: Tool profile to use (default: "full")
- `--list-output`: Output format for lists ("table" or "yaml")
- `--read-only`: Expose only read-only tools
- `--disable-destructive`: Disable destructive operations
- `--kubeconfig`: Custom kubeconfig path
- `--config`: Static configuration file path

## Testing

Tests are organized by package and use Go's standard testing framework:
- Unit tests: `*_test.go` files alongside source
- Test data: `testdata/` directories
- Mock objects: `mock_*_test.go` files

Run tests with detailed output:
```bash
go test -v ./pkg/...
```

## Publishing

The project supports multiple distribution channels:
- Native binaries (via GitHub releases)
- NPM packages (platform-specific and universal)
- Python packages (via PyPI)
- Container images

Build and publish commands are in the Makefile.

## Development Conventions

### Script Management
When complexity requires separate scripts, they should be:
1. Placed in the `scripts/` directory
2. Called from Makefile targets rather than run directly
3. This keeps the Makefile as the single entry point for all operations

Example:
```makefile
.PHONY: complex-task
complex-task: ## Run complex task via script
	./scripts/complex-task.sh
```