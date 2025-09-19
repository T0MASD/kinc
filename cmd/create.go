package cmd

import (
	"fmt"
	"os/exec"

	"github.com/spf13/cobra"
)

var createCmd = &cobra.Command{
	Use:   "create",
	Short: "Create commands",
	Long:  "Commands for creating kinc resources",
}

var createClusterCmd = &cobra.Command{
	Use:   "cluster [name]",
	Short: "Create a new Kubernetes cluster",
	Long:  "Create a new Kubernetes cluster using podman containers",
	Args:  cobra.MaximumNArgs(1),
	RunE:  createClusterRun,
}

func init() {
	createClusterCmd.Flags().StringP("image", "i", "kindest/node:v1.31.2", "Node docker image to use for booting the cluster")
	createClusterCmd.Flags().IntP("control-plane-nodes", "", 1, "Number of control-plane nodes in the cluster")
	createClusterCmd.Flags().IntP("worker-nodes", "w", 0, "Number of worker nodes in the cluster")
	createClusterCmd.Flags().StringP("config", "", "", "Path to a kind config file")

	createCmd.AddCommand(createClusterCmd)
}

func createClusterRun(cmd *cobra.Command, args []string) error {
	clusterName := "kinc"
	if len(args) > 0 {
		clusterName = args[0]
	}

	image, _ := cmd.Flags().GetString("image")
	controlPlaneNodes, _ := cmd.Flags().GetInt("control-plane-nodes")
	workerNodes, _ := cmd.Flags().GetInt("worker-nodes")

	fmt.Printf("Creating cluster '%s'...\n", clusterName)
	fmt.Printf("Using image: %s\n", image)
	fmt.Printf("Control plane nodes: %d\n", controlPlaneNodes)
	fmt.Printf("Worker nodes: %d\n", workerNodes)

	// Check if podman is available
	if err := checkPodmanAvailable(); err != nil {
		return fmt.Errorf("podman is required but not available: %v", err)
	}

	// Create podman network for the cluster
	networkName := fmt.Sprintf("kinc-%s", clusterName)
	if err := createPodmanNetwork(networkName); err != nil {
		return fmt.Errorf("failed to create network: %v", err)
	}

	// Create control plane nodes
	for i := 0; i < controlPlaneNodes; i++ {
		nodeName := fmt.Sprintf("%s-control-plane", clusterName)
		if controlPlaneNodes > 1 {
			nodeName = fmt.Sprintf("%s-control-plane-%d", clusterName, i+1)
		}

		if err := createControlPlaneNode(nodeName, networkName, image, i == 0); err != nil {
			return fmt.Errorf("failed to create control plane node %s: %v", nodeName, err)
		}
	}

	// Create worker nodes
	for i := 0; i < workerNodes; i++ {
		nodeName := fmt.Sprintf("%s-worker-%d", clusterName, i+1)
		if err := createWorkerNode(nodeName, networkName, image); err != nil {
			return fmt.Errorf("failed to create worker node %s: %v", nodeName, err)
		}
	}

	fmt.Printf("✓ Cluster '%s' created successfully!\n", clusterName)
	fmt.Printf("You can now use kubectl to interact with your cluster:\n")
	fmt.Printf("  kubectl cluster-info --context kinc-%s\n", clusterName)

	return nil
}

func checkPodmanAvailable() error {
	cmd := exec.Command("podman", "--version")
	return cmd.Run()
}

func createPodmanNetwork(networkName string) error {
	// Check if network already exists
	cmd := exec.Command("podman", "network", "exists", networkName)
	if cmd.Run() == nil {
		fmt.Printf("Network %s already exists, reusing...\n", networkName)
		return nil
	}

	// Create new network
	cmd = exec.Command("podman", "network", "create", networkName)
	output, err := cmd.CombinedOutput()
	if err != nil {
		return fmt.Errorf("failed to create network %s: %v, output: %s", networkName, err, string(output))
	}

	fmt.Printf("✓ Created network: %s\n", networkName)
	return nil
}

func createControlPlaneNode(nodeName, networkName, image string, isPrimary bool) error {
	fmt.Printf("Creating control plane node: %s\n", nodeName)

	// Run the container with necessary privileges and systemd
	args := []string{
		"run", "-d",
		"--name", nodeName,
		"--network", networkName,
		"--privileged",
		"--cgroupns=host",
		"--tmpfs", "/tmp",
		"--tmpfs", "/run",
		"--tmpfs", "/run/lock",
		"--volume", "/sys/fs/cgroup:/sys/fs/cgroup:rw",
		"--restart", "unless-stopped",
		image,
		"/usr/local/bin/entrypoint",
		"/sbin/init",
	}

	cmd := exec.Command("podman", args...)
	output, err := cmd.CombinedOutput()
	if err != nil {
		return fmt.Errorf("failed to create container %s: %v, output: %s", nodeName, err, string(output))
	}

	fmt.Printf("✓ Created control plane node: %s\n", nodeName)
	return nil
}

func createWorkerNode(nodeName, networkName, image string) error {
	fmt.Printf("Creating worker node: %s\n", nodeName)

	// Run the container with necessary privileges and systemd
	args := []string{
		"run", "-d",
		"--name", nodeName,
		"--network", networkName,
		"--privileged",
		"--cgroupns=host",
		"--tmpfs", "/tmp",
		"--tmpfs", "/run",
		"--tmpfs", "/run/lock",
		"--volume", "/sys/fs/cgroup:/sys/fs/cgroup:rw",
		"--restart", "unless-stopped",
		image,
		"/usr/local/bin/entrypoint",
		"/sbin/init",
	}

	cmd := exec.Command("podman", args...)
	output, err := cmd.CombinedOutput()
	if err != nil {
		return fmt.Errorf("failed to create container %s: %v, output: %s", nodeName, err, string(output))
	}

	fmt.Printf("✓ Created worker node: %s\n", nodeName)
	return nil
}
