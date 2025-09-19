package cmd

import (
	"testing"
)

func TestRootCmd(t *testing.T) {
	if RootCmd.Use != "kinc" {
		t.Errorf("Expected RootCmd.Use to be 'kinc', got '%s'", RootCmd.Use)
	}

	if RootCmd.Short == "" {
		t.Error("Expected RootCmd.Short to be non-empty")
	}

	if RootCmd.Long == "" {
		t.Error("Expected RootCmd.Long to be non-empty")
	}
}

func TestCommandsExist(t *testing.T) {
	commands := []string{"create", "delete", "get"}

	for _, cmdName := range commands {
		found := false
		for _, cmd := range RootCmd.Commands() {
			if cmd.Use == cmdName {
				found = true
				break
			}
		}
		if !found {
			t.Errorf("Expected command '%s' to exist", cmdName)
		}
	}
}
