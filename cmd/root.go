package cmd

import (
	"github.com/spf13/cobra"
)

var RootCmd = &cobra.Command{
	Use:   "kinc",
	Short: "kinc is a tool for running Kubernetes clusters in containers using podman",
	Long: `kinc (Kubernetes in Container) is a tool similar to kind that allows you to run 
Kubernetes clusters in containers using podman with systemd support.

This tool provides an easy way to create, manage, and delete local Kubernetes clusters
for development and testing purposes.`,
}

func init() {
	RootCmd.AddCommand(createCmd)
	RootCmd.AddCommand(deleteCmd)
	RootCmd.AddCommand(getCmd)
}
