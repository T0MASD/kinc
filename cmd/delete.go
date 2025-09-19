package cmd

import (
	"fmt"
	"os/exec"
	"strings"

	"github.com/spf13/cobra"
)

var deleteCmd = &cobra.Command{
	Use:   "delete",
	Short: "Delete commands",
	Long:  "Commands for deleting kinc resources",
}

var deleteClusterCmd = &cobra.Command{
	Use:   "cluster [name]",
	Short: "Delete a Kubernetes cluster",
	Long:  "Delete a Kubernetes cluster and cleanup associated resources",
	Args:  cobra.MaximumNArgs(1),
	RunE:  deleteClusterRun,
}

func init() {
	deleteCmd.AddCommand(deleteClusterCmd)
}

func deleteClusterRun(cmd *cobra.Command, args []string) error {
	clusterName := "kinc"
	if len(args) > 0 {
		clusterName = args[0]
	}

	fmt.Printf("Deleting cluster '%s'...\n", clusterName)

	// Get all containers related to this cluster
	containers, err := getClusterContainers(clusterName)
	if err != nil {
		return fmt.Errorf("failed to get cluster containers: %v", err)
	}

	if len(containers) == 0 {
		fmt.Printf("No containers found for cluster '%s'\n", clusterName)
		return nil
	}

	// Stop and remove all containers
	for _, containerName := range containers {
		if err := removeContainer(containerName); err != nil {
			fmt.Printf("Warning: failed to remove container %s: %v\n", containerName, err)
		} else {
			fmt.Printf("✓ Removed container: %s\n", containerName)
		}
	}

	// Remove the network
	networkName := fmt.Sprintf("kinc-%s", clusterName)
	if err := removeNetwork(networkName); err != nil {
		fmt.Printf("Warning: failed to remove network %s: %v\n", networkName, err)
	} else {
		fmt.Printf("✓ Removed network: %s\n", networkName)
	}

	fmt.Printf("✓ Cluster '%s' deleted successfully!\n", clusterName)
	return nil
}

func getClusterContainers(clusterName string) ([]string, error) {
	// List all containers that start with the cluster name
	cmd := exec.Command("podman", "ps", "-a", "--format", "{{.Names}}", "--filter", fmt.Sprintf("name=%s-", clusterName))
	output, err := cmd.Output()
	if err != nil {
		return nil, err
	}

	lines := strings.Split(strings.TrimSpace(string(output)), "\n")
	var containers []string
	for _, line := range lines {
		if line != "" {
			containers = append(containers, line)
		}
	}

	return containers, nil
}

func removeContainer(containerName string) error {
	// Stop the container
	stopCmd := exec.Command("podman", "stop", containerName)
	stopCmd.Run() // Ignore errors as container might already be stopped

	// Remove the container
	rmCmd := exec.Command("podman", "rm", "-f", containerName)
	return rmCmd.Run()
}

func removeNetwork(networkName string) error {
	cmd := exec.Command("podman", "network", "rm", networkName)
	return cmd.Run()
}
