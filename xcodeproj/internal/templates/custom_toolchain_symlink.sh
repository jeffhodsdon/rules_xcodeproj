#!/bin/bash
set -euo pipefail

# Define constants within the script
TOOLCHAIN_NAME_BASE="%toolchain_name_base%"
TOOLCHAIN_DIR="%toolchain_dir%"
XCODE_VERSION="%xcode_version%"

# Function to retry commands with exponential backoff
retry_command() {
    local max_attempts=3
    local delay=1
    local attempt=1
    
    while [ $attempt -le $max_attempts ]; do
        if "$@"; then
            return 0
        fi
        
        if [ $attempt -lt $max_attempts ]; then
            echo "Command failed (attempt $attempt/$max_attempts), retrying in ${delay}s..." >&2
            sleep $delay
            delay=$((delay * 2))
        fi
        attempt=$((attempt + 1))
    done
    
    echo "Command failed after $max_attempts attempts: $*" >&2
    return 1
}

# Clean up temp files on exit
TOOL_NAMES_FILE=$(mktemp)
CACHE_DIR=$(mktemp -d)
trap 'rm -f "$TOOL_NAMES_FILE"; rm -rf "$CACHE_DIR"' EXIT

echo "%tool_names_list%" > "$TOOL_NAMES_FILE"

# Get Xcode version and default toolchain path with retry logic
DEFAULT_TOOLCHAIN=$(retry_command xcrun --find clang | sed 's|/usr/bin/clang$||')
XCODE_RAW_VERSION=$(retry_command xcodebuild -version | head -n 1)

# Extract unique workspace hash from the Bazel output base path
# Path format: /Users/j/.cache/bazel/<hash>/rules_xcodeproj.noindex/...
# We extract the first 8 chars of the hash to make toolchain names unique per workspace
WORKSPACE_HASH=""
if [[ "$PWD" =~ \.cache/bazel/([a-f0-9]{8}) ]]; then
    WORKSPACE_HASH="_${BASH_REMATCH[1]}"
fi

HOME_TOOLCHAIN_NAME="BazelRulesXcodeProj${XCODE_VERSION}${WORKSPACE_HASH}"
USER_TOOLCHAIN_PATH="/Users/$(id -un)/Library/Developer/Toolchains/${HOME_TOOLCHAIN_NAME}.xctoolchain"
BUILT_TOOLCHAIN_PATH="$PWD/$TOOLCHAIN_DIR"

retry_command mkdir -p "$TOOLCHAIN_DIR"

# Function to get toolchain files with caching
get_toolchain_files() {
    local xcode_version_hash=$(echo "$XCODE_RAW_VERSION" | shasum -a 256 | cut -d' ' -f1)
    local cache_file="$CACHE_DIR/toolchain_files_$xcode_version_hash.txt"
    
    # Check if cache is valid
    if [[ -f "$cache_file" && "$cache_file" -nt "$DEFAULT_TOOLCHAIN" ]]; then
        echo "Using cached toolchain file list..." >&2
        cat "$cache_file"
    else
        echo "Building toolchain file cache..." >&2
        find "$DEFAULT_TOOLCHAIN" -type f -o -type l 2>/dev/null | tee "$cache_file" || {
            echo "Error: Failed to find files in $DEFAULT_TOOLCHAIN" >&2
            exit 1
        }
    fi
}

# Function to setup toolchain state file
setup_toolchain_state() {
    local xcode_version_hash=$(echo "$XCODE_RAW_VERSION" | shasum -a 256 | cut -d' ' -f1)
    local state_file="$CACHE_DIR/toolchain_state_$xcode_version_hash.json"
    
    echo "$state_file"
}

# Function to check if incremental update is possible
check_incremental_update() {
    local state_file=$(setup_toolchain_state)
    
    if [[ -f "$state_file" ]]; then
        # Check if jq is available for JSON parsing
        if ! command -v jq >/dev/null 2>&1; then
            echo "jq not available, performing full update" >&2
            return 1
        fi
        
        # Load previous state
        local prev_xcode_version=$(jq -r '.xcode_version' "$state_file" 2>/dev/null || echo "")
        local prev_tool_names=$(jq -r '.tool_names[]' "$state_file" 2>/dev/null | tr '\n' ' ' || echo "")
        
        # Check if only tool overrides changed
        if [[ "$prev_xcode_version" == "$XCODE_VERSION" && -d "$TOOLCHAIN_DIR" ]]; then
            local current_tool_names=$(cat "$TOOL_NAMES_FILE" | tr '\n' ' ')
            
            if [[ "$current_tool_names" == "$prev_tool_names" ]]; then
                echo "No changes detected, skipping toolchain update" >&2
                return 0
            else
                echo "Tool overrides changed, performing incremental update" >&2
                update_changed_tools_only "$prev_tool_names"
                return 0
            fi
        fi
    fi
    
    return 1  # Full update needed
}

# Function to update only changed tools
update_changed_tools_only() {
    local prev_tool_names="$1"
    local current_tool_names=$(cat "$TOOL_NAMES_FILE" | tr '\n' ' ')
    
    # Remove old overrides that are no longer in the list
    echo "$prev_tool_names" | tr ' ' '\n' | while read -r tool_name; do
        if [[ -n "$tool_name" && ! "$current_tool_names" =~ $tool_name ]]; then
            echo "Removing old override: $tool_name" >&2
            find "$TOOLCHAIN_DIR" -name "$tool_name" -type l -delete 2>/dev/null || true
        fi
    done
    
    # Restore symlinks for tools that are no longer overridden
    echo "$prev_tool_names" | tr ' ' '\n' | while read -r tool_name; do
        if [[ -n "$tool_name" && ! "$current_tool_names" =~ $tool_name ]]; then
            # Find the original tool in the default toolchain
            local original_tool=$(find "$DEFAULT_TOOLCHAIN" -name "$tool_name" -type f -o -name "$tool_name" -type l 2>/dev/null | head -1)
            if [[ -n "$original_tool" ]]; then
                local rel_path="${original_tool#"$DEFAULT_TOOLCHAIN/"}"
                local target_path="$TOOLCHAIN_DIR/$rel_path"
                local target_dir="$(dirname "$target_path")"
                
                mkdir -p "$target_dir" 2>/dev/null || true
                ln -sf "$original_tool" "$target_path" 2>/dev/null || {
                    echo "Warning: Failed to restore symlink $target_path" >&2
                }
            fi
        fi
    done
    
    echo "Incremental update completed" >&2
}

# Function to save toolchain state
save_toolchain_state() {
    local state_file=$(setup_toolchain_state)
    
    # Only save state if jq is available
    if command -v jq >/dev/null 2>&1; then
        local tool_names_json=$(cat "$TOOL_NAMES_FILE" | jq -R . | jq -s .)
        jq -n --arg xcode_version "$XCODE_VERSION" \
              --argjson tool_names "$tool_names_json" \
              '{xcode_version: $xcode_version, tool_names: $tool_names}' > "$state_file" || {
            echo "Warning: Failed to save toolchain state" >&2
        }
    fi
}

# Function to process files in parallel
process_files_parallel() {
    local batch_size=100
    local max_jobs=8
    
    # Export variables for use in subshells
    export DEFAULT_TOOLCHAIN TOOLCHAIN_DIR TOOL_NAMES_FILE
    
    get_toolchain_files | \
        while read -r file; do
            # Skip empty lines
            [[ -n "$file" ]] || continue
            
            rel_path="${file#"$DEFAULT_TOOLCHAIN/"}"
            base_name=$(basename "$rel_path")

            # Skip ToolchainInfo.plist as we'll create our own
            if [[ "$rel_path" == "ToolchainInfo.plist" ]]; then
                continue
            fi

            # Check if this file is in the list of tools to be overridden
            should_skip=0
            for tool_name in $(cat "$TOOL_NAMES_FILE"); do
                if [[ "$base_name" == "$tool_name" ]]; then
                    # Skip creating a symlink for overridden tools
                    should_skip=1
                    break
                fi
            done

            if [[ $should_skip -eq 0 ]]; then
                echo "$file"
            fi
        done | \
        xargs -P "$max_jobs" -n "$batch_size" bash -c '
            for file in "$@"; do
                rel_path="${file#$DEFAULT_TOOLCHAIN/}"
                target_path="$TOOLCHAIN_DIR/$rel_path"
                target_dir="$(dirname "$target_path")"
                
                # Create directory if it doesn'\''t exist
                mkdir -p "$target_dir" 2>/dev/null || true
                
                # Create symlink
                ln -sf "$file" "$target_path" 2>/dev/null || {
                    echo "Warning: Failed to create symlink $target_path" >&2
                }
            done
        ' _
}

# Function to generate ToolchainInfo.plist and setup user symlink
finalize_toolchain() {
    # Generate the ToolchainInfo.plist directly with Xcode version information
    cat > "$TOOLCHAIN_DIR/ToolchainInfo.plist" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple Computer//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
  <dict>
    <key>Aliases</key>
    <array>
      <string>${HOME_TOOLCHAIN_NAME}</string>
    </array>
    <key>CFBundleIdentifier</key>
    <string>com.rules_xcodeproj.${HOME_TOOLCHAIN_NAME}</string>
    <key>CompatibilityVersion</key>
    <integer>2</integer>
    <key>CompatibilityVersionDisplayString</key>
    <string>${XCODE_RAW_VERSION}</string>
    <key>DisplayName</key>
    <string>${HOME_TOOLCHAIN_NAME}</string>
    <key>ReportProblemURL</key>
    <string>https://github.com/MobileNativeFoundation/rules_xcodeproj</string>
    <key>ShortDisplayName</key>
    <string>${HOME_TOOLCHAIN_NAME}</string>
    <key>Version</key>
    <string>0.1.0</string>
  </dict>
</plist>
EOF

    # Note: We intentionally do NOT create .dia files here
    # Missing .dia files are better than invalid ASCII text ones that cause
    # "Invalid diagnostics signature" errors in Xcode Previews
    # However, we need to include the specific binary cc.dia file that clang.sh expects
    TOOLCHAIN_BIN_DIR="$TOOLCHAIN_DIR/usr/bin"
    mkdir -p "$TOOLCHAIN_BIN_DIR"

    # Copy the binary cc.dia file that clang.sh needs
    # This is a proper binary diagnostic file, not an ASCII placeholder
    # Find cc.dia in the current directory and its subdirectories (from Bazel inputs)
    echo "Looking for cc.dia file..." >&2
    CC_DIA_FILE=$(find . -name "cc.dia" -type f 2>/dev/null | head -1)
    if [[ -f "$CC_DIA_FILE" ]]; then
        retry_command cp "$CC_DIA_FILE" "$TOOLCHAIN_BIN_DIR/cc.dia"
        echo "Copied cc.dia from $CC_DIA_FILE to $TOOLCHAIN_BIN_DIR/cc.dia" >&2
        
        # Verify the file was copied successfully
        if [[ ! -f "$TOOLCHAIN_BIN_DIR/cc.dia" ]]; then
            echo "Error: Failed to copy cc.dia file" >&2
            exit 1
        fi
    else
        echo "Warning: cc.dia file not found in inputs" >&2
    fi

    # Create user toolchain symlink with retry logic
    user_toolchain_dir="$(dirname "$USER_TOOLCHAIN_PATH")"
    retry_command mkdir -p "$user_toolchain_dir"

    if [[ -e "$USER_TOOLCHAIN_PATH" || -L "$USER_TOOLCHAIN_PATH" ]]; then
        retry_command rm -rf "$USER_TOOLCHAIN_PATH"
    fi

    retry_command ln -sf "$BUILT_TOOLCHAIN_PATH" "$USER_TOOLCHAIN_PATH"

    # Verify final symlink was created successfully
    if [[ ! -L "$USER_TOOLCHAIN_PATH" ]]; then
        echo "Error: Failed to create user toolchain symlink at $USER_TOOLCHAIN_PATH" >&2
        exit 1
    fi

    echo "Successfully created custom toolchain at $USER_TOOLCHAIN_PATH" >&2
}

# Main execution
# Check if incremental update is possible
if check_incremental_update; then
    # Incremental update completed, still need to finalize toolchain
    finalize_toolchain
    save_toolchain_state
else
    # Process all files from the default toolchain using parallel processing
    echo "Processing toolchain files from $DEFAULT_TOOLCHAIN..." >&2
    process_files_parallel
    
    # Finalize the toolchain setup
    finalize_toolchain
    
    # Save state after successful full update
    save_toolchain_state
fi
