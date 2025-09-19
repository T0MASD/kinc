package cmd

import (
	"fmt"
	"os"
	"os/exec"
	"strings"
	"text/tabwriter"

	"github.com/spf13/cobra"
)

var getCmd = &cobra.Command{
	Use:   "get",
	Short: "Get commands",
	Long:  "Commands for getting information about kinc resources",
}

var getClustersCmd = &cobra.Command{
	Use:   "clusters",
	Short: "List all clusters",
	Long:  "List all kinc clusters and their status",
	RunE:  getClustersRun,
}

func init() {
	getCmd.AddCommand(getClustersCmd)
}

func getClustersRun(cmd *cobra.Command, args []string) error {
	clusters, err := listClusters()
	if err != nil {
		return fmt.Errorf("failed to list clusters: %v", err)
	}

	if len(clusters) == 0 {
		fmt.Println("No clusters found.")
		return nil
	}

	// Create tabwriter for formatted output
	w := tabwriter.NewWriter(os.Stdout, 0, 0, 2, ' ', 0)
	fmt.Fprintln(w, "NAME\tSTATUS\tROLE\tAGE")

	for _, cluster := range clusters {
		fmt.Fprintf(w, "%s\t%s\t%s\t%s\n", cluster.Name, cluster.Status, cluster.Role, cluster.Age)
	}

	w.Flush()
	return nil
}

type ClusterInfo struct {
	Name   string
	Status string
	Role   string
	Age    string
}

func listClusters() ([]ClusterInfo, error) {
	// Get all containers with kinc- prefix
	cmd := exec.Command("podman", "ps", "-a", "--format", "{{.Names}}\t{{.Status}}\t{{.CreatedHuman}}", "--filter", "name=kinc-")
	output, err := cmd.Output()
	if err != nil {
		return nil, err
	}

	var clusters []ClusterInfo
	lines := strings.Split(strings.TrimSpace(string(output)), "\n")

	for _, line := range lines {
		if line == "" {
			continue
		}

		parts := strings.Split(line, "\t")
		if len(parts) < 3 {
			continue
		}

		name := parts[0]
		status := parts[1]
		age := parts[2]

		// Determine role from container name
		role := "worker"
		if strings.Contains(name, "control-plane") {
			role = "control-plane"
		}

		clusters = append(clusters, ClusterInfo{
			Name:   name,
			Status: status,
			Role:   role,
			Age:    age,
		})
	}

	return clusters, nil
}
