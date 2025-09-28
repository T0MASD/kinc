#!/bin/bash
# JSON-safe crun wrapper using jq
# This wrapper intercepts crun create commands and removes oomScoreAdj from OCI specs
# to enable rootless container operation without OOM score adjustment failures

# Debug logging
echo "$(date): crun called with: $*" >> /tmp/crun-debug.log

# Check if this is a container create command
if [[ "$*" == *"create"* ]]; then
    BUNDLE_DIR=""
    # Parse arguments to find --bundle directory
    for ((i=1; i<=$#; i++)); do
        if [[ "${!i}" == "--bundle" ]]; then
            j=$((i+1))
            BUNDLE_DIR="${!j}"
            break
        fi
    done
    
    # Process config.json if bundle directory exists
    if [[ -n "$BUNDLE_DIR" && -f "$BUNDLE_DIR/config.json" ]]; then
        # Create backup
        cp "$BUNDLE_DIR/config.json" "$BUNDLE_DIR/config.json.bak"
        MODIFIED=false
        
        # Remove oomScoreAdj if present
        if grep -q "oomScoreAdj" "$BUNDLE_DIR/config.json"; then
            echo "$(date): Using jq to safely remove oomScoreAdj" >> /tmp/crun-debug.log
            jq "del(.process.oomScoreAdj)" "$BUNDLE_DIR/config.json.bak" > "$BUNDLE_DIR/config.json.tmp"
            if [[ $? -eq 0 ]]; then
                mv "$BUNDLE_DIR/config.json.tmp" "$BUNDLE_DIR/config.json"
                cp "$BUNDLE_DIR/config.json" "$BUNDLE_DIR/config.json.bak"
                echo "$(date): Successfully removed oomScoreAdj with jq" >> /tmp/crun-debug.log
                MODIFIED=true
            else
                echo "$(date): jq failed to remove oomScoreAdj" >> /tmp/crun-debug.log
                rm -f "$BUNDLE_DIR/config.json.tmp"
            fi
        fi
        
        # Remove user settings that cause capset issues in rootless mode
        if grep -q '"user"' "$BUNDLE_DIR/config.json"; then
            echo "$(date): Removing user settings to avoid capset issues in rootless mode" >> /tmp/crun-debug.log
            jq 'del(.process.user)' "$BUNDLE_DIR/config.json.bak" > "$BUNDLE_DIR/config.json.tmp"
            if [[ $? -eq 0 ]]; then
                mv "$BUNDLE_DIR/config.json.tmp" "$BUNDLE_DIR/config.json"
                cp "$BUNDLE_DIR/config.json" "$BUNDLE_DIR/config.json.bak"
                echo "$(date): Successfully removed user settings" >> /tmp/crun-debug.log
                MODIFIED=true
            else
                echo "$(date): jq failed to remove user settings" >> /tmp/crun-debug.log
                rm -f "$BUNDLE_DIR/config.json.tmp"
            fi
        fi
        
        # For helper containers, remove all capabilities to avoid capset issues
        if grep -q "helper" "$BUNDLE_DIR/config.json"; then
            echo "$(date): Removing all capabilities from helper container to avoid capset issues" >> /tmp/crun-debug.log
            jq 'del(.process.capabilities)' "$BUNDLE_DIR/config.json.bak" > "$BUNDLE_DIR/config.json.tmp"
            if [[ $? -eq 0 ]]; then
                mv "$BUNDLE_DIR/config.json.tmp" "$BUNDLE_DIR/config.json"
                cp "$BUNDLE_DIR/config.json" "$BUNDLE_DIR/config.json.bak"
                echo "$(date): Successfully removed capabilities from helper container" >> /tmp/crun-debug.log
                MODIFIED=true
            else
                echo "$(date): jq failed to remove capabilities from helper container" >> /tmp/crun-debug.log
                rm -f "$BUNDLE_DIR/config.json.tmp"
            fi
        fi
        
        if [[ "$MODIFIED" == "false" ]]; then
            echo "$(date): No modifications needed" >> /tmp/crun-debug.log
        fi
    fi
fi

# Execute the original crun binary with all arguments
exec /usr/bin/crun.orig "$@"
