# kinc

**kinc** (Kubernetes in Container) is a tool for running local Kubernetes clusters using podman containers. It's similar to [kind](https://kind.sigs.k8s.io/) (Kubernetes in Docker) but designed to work with podman and systemd.

## Features

- 🐳 **Podman Native**: Uses podman instead of Docker for better rootless container support
- 🔧 **Systemd Integration**: Leverages systemd for proper container lifecycle management
- ⚡ **Fast Setup**: Quick cluster creation and deletion
- 🎯 **Development Focus**: Perfect for local Kubernetes development and testing
- 🛠️ **Familiar Interface**: Command structure similar to kind for easy adoption

## Prerequisites

- [Podman](https://podman.io/) installed and configured
- Linux environment with systemd support
- Go 1.21+ (for building from source)

## Installation

### From Source

```bash
git clone https://github.com/T0MASD/kinc.git
cd kinc
go build -o kinc
sudo mv kinc /usr/local/bin/
```

## Usage

### Create a Cluster

Create a simple single-node cluster:

```bash
kinc create cluster
```

Create a cluster with a custom name:

```bash
kinc create cluster my-cluster
```

Create a multi-node cluster:

```bash
kinc create cluster --control-plane-nodes 3 --worker-nodes 2
```

Use a specific Kubernetes version:

```bash
kinc create cluster --image kindest/node:v1.30.0
```

### List Clusters

```bash
kinc get clusters
```

### Delete a Cluster

```bash
kinc delete cluster
```

Delete a specific cluster:

```bash
kinc delete cluster my-cluster
```

## How it Works

kinc creates Kubernetes clusters by:

1. **Network Setup**: Creates a dedicated podman network for cluster isolation
2. **Container Creation**: Spins up privileged containers with systemd support
3. **Kubernetes Bootstrap**: Uses the same container images as kind for compatibility
4. **Service Management**: Leverages systemd for proper service lifecycle management

Each cluster consists of:
- **Control Plane Nodes**: Run the Kubernetes API server, etcd, and other control plane components
- **Worker Nodes**: Run the kubelet and container runtime for hosting workloads
- **Dedicated Network**: Isolated podman network for cluster communication

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                        Host System                          │
│  ┌─────────────┐    ┌─────────────┐    ┌─────────────┐     │
│  │   Control   │    │   Worker    │    │   Worker    │     │
│  │   Plane     │    │    Node     │    │    Node     │     │
│  │ Container   │    │ Container   │    │ Container   │     │
│  │             │    │             │    │             │     │
│  │ ┌─────────┐ │    │ ┌─────────┐ │    │ ┌─────────┐ │     │
│  │ │systemd  │ │    │ │systemd  │ │    │ │systemd  │ │     │
│  │ │ └─┬─┘   │ │    │ │ └─┬─┘   │ │    │ │ └─┬─┘   │ │     │
│  │ │   │     │ │    │ │   │     │ │    │ │   │     │ │     │
│  │ │ k8s     │ │    │ │ kubelet │ │    │ │ kubelet │ │     │
│  │ │ control │ │    │ │         │ │    │ │         │ │     │
│  │ │ plane   │ │    │ │         │ │    │ │         │ │     │
│  │ └─────────┘ │    │ └─────────┘ │    │ └─────────┘ │     │
│  └─────────────┘    └─────────────┘    └─────────────┘     │
│                                                             │
│              Connected via Podman Network                   │
└─────────────────────────────────────────────────────────────┘
```

## Differences from kind

| Feature | kind | kinc |
|---------|------|------|
| Container Runtime | Docker | Podman |
| Init System | Custom | systemd |
| Rootless Support | Limited | Native |
| Service Management | Manual | systemd |
| Network Isolation | Docker networks | Podman networks |

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

## License

This project is licensed under the MIT License - see the LICENSE file for details.

## Acknowledgments

- [kind](https://kind.sigs.k8s.io/) - The inspiration for this project
- [Podman](https://podman.io/) - The container engine that powers kinc
- [Kubernetes](https://kubernetes.io/) - The platform we're running