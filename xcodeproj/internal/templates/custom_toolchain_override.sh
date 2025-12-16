#!/bin/bash
set -euo pipefail

SYMLINK_TOOLCHAIN_DIR="%symlink_toolchain_dir%"
FINAL_TOOLCHAIN_DIR="%final_toolchain_dir%"
MARKER_FILE="%marker_file%"

# Get the default toolchain path
DEFAULT_TOOLCHAIN=$(xcrun --find clang | sed 's|/usr/bin/clang$||')

OVERRIDES_FILE=$(mktemp)
echo "%overrides_list%" > "$OVERRIDES_FILE"

TOOL_NAMES_FILE=$(mktemp)
echo "%tool_names_list%" > "$TOOL_NAMES_FILE"

for tool_name in $(cat "$TOOL_NAMES_FILE"); do
    VALUE=""
    for override in $(cat "$OVERRIDES_FILE"); do
        KEY="${override%%=*}"
        if [[ "$KEY" == "$tool_name" ]]; then
            VALUE="${override#*=}"
            break
        fi
    done

    if [[ -z "$VALUE" ]]; then
        echo "Error: No override found for tool: $tool_name"
        echo "ERROR: No override found for tool: $tool_name" >> "$MARKER_FILE"
        continue
    fi

    find "$DEFAULT_TOOLCHAIN/usr/bin" -name "$tool_name" | while read -r default_tool_path; do
        rel_path="${default_tool_path#"$DEFAULT_TOOLCHAIN/"}"
        target_file="$FINAL_TOOLCHAIN_DIR/$rel_path"

        mkdir -p "$(dirname "$target_file")"

        override_path="$PWD/$VALUE"
        cp "$override_path" "$target_file"

        echo "Copied $override_path to $target_file (rel_path: $rel_path)" >> "$MARKER_FILE"
    done
done

# Clean up temporary files
rm -f "$OVERRIDES_FILE"
rm -f "$TOOL_NAMES_FILE"

# Copy the symlink toolchain to the final toolchain directory
mkdir -p "$FINAL_TOOLCHAIN_DIR"
cp -RP "$SYMLINK_TOOLCHAIN_DIR/"* "$FINAL_TOOLCHAIN_DIR/"

# Note: We intentionally do NOT create .dia files here
# Missing .dia files are better than invalid ASCII text ones that cause
# "Invalid diagnostics signature" errors in Xcode Previews
# Bazel will create proper binary .dia files when needed
TOOLCHAIN_BIN_DIR="$FINAL_TOOLCHAIN_DIR/usr/bin"
mkdir -p "$TOOLCHAIN_BIN_DIR"

# Extract unique workspace hash from the Bazel output base path
# Path format: /Users/j/.cache/bazel/<hash>/rules_xcodeproj.noindex/...
WORKSPACE_HASH=""
if [[ "$PWD" =~ \.cache/bazel/([a-f0-9]{8}) ]]; then
    WORKSPACE_HASH="_${BASH_REMATCH[1]}"
fi

# Create a symlink to the toolchain in the user's Library directory
# Include workspace hash to allow multiple projects to coexist
BASE_TOOLCHAIN_NAME=$(basename "$FINAL_TOOLCHAIN_DIR" | sed 's/\.xctoolchain$//')
HOME_TOOLCHAIN_NAME="${BASE_TOOLCHAIN_NAME}${WORKSPACE_HASH}"
USER_TOOLCHAIN_PATH="/Users/$(id -un)/Library/Developer/Toolchains/${HOME_TOOLCHAIN_NAME}.xctoolchain"
mkdir -p "$(dirname "$USER_TOOLCHAIN_PATH")"
if [[ -e "$USER_TOOLCHAIN_PATH" || -L "$USER_TOOLCHAIN_PATH" ]]; then
    rm -rf "$USER_TOOLCHAIN_PATH"
fi
ln -sf "$PWD/$FINAL_TOOLCHAIN_DIR" "$USER_TOOLCHAIN_PATH"
echo "Created symlink: $USER_TOOLCHAIN_PATH -> $PWD/$FINAL_TOOLCHAIN_DIR" >> "$MARKER_FILE"


