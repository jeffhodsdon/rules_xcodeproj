#!/bin/bash

set -euo pipefail

# For preview builds, pass through to the real clang with optional library filtering
if [[ "${ENABLE_PREVIEWS:-}" == "YES" ]]; then
  # Extract developer dir from -isysroot argument
  DEV_DIR=""
  for arg in "$@"; do
    if [[ "$arg" == */Contents/Developer/* ]]; then
      DEV_DIR=$(echo "$arg" | sed 's|/Contents/Developer/.*|/Contents/Developer|')
      break
    fi
  done

  if [[ -z "$DEV_DIR" ]]; then
    # Fallback to xcrun
    DEV_DIR=$(xcode-select -p)
  fi

  real_clang="$DEV_DIR/Toolchains/XcodeDefault.xctoolchain/usr/bin/clang"

  # Filter merged product libraries to prevent duplicate symbols
  # RULES_XCODEPROJ_MERGED_LIBS contains semicolon-separated library names to exclude
  # e.g., "AppLib;OtherMergedLib" will filter out -lAppLib and -lOtherMergedLib
  if [[ -n "${RULES_XCODEPROJ_MERGED_LIBS:-}" ]]; then
    # Build associative array of libraries to exclude
    declare -A EXCLUDE_LIBS
    IFS=';' read -ra LIB_ARRAY <<< "$RULES_XCODEPROJ_MERGED_LIBS"
    for lib in "${LIB_ARRAY[@]}"; do
      if [[ -n "$lib" ]]; then
        EXCLUDE_LIBS["$lib"]=1
      fi
    done

    # Filter arguments
    filtered_args=()
    for arg in "$@"; do
      # Check if this is a -l flag for a library we should exclude
      if [[ "$arg" =~ ^-l(.+)$ ]]; then
        libname="${BASH_REMATCH[1]}"
        if [[ -n "${EXCLUDE_LIBS[$libname]:-}" ]]; then
          continue  # Skip this library
        fi
      fi
      # Check if this is a full path to a library we should exclude (e.g., /path/to/libAppLib.a)
      if [[ "$arg" =~ lib([^/]+)\.a$ ]]; then
        libname="${BASH_REMATCH[1]}"
        if [[ -n "${EXCLUDE_LIBS[$libname]:-}" ]]; then
          continue  # Skip this library
        fi
      fi
      filtered_args+=("$arg")
    done

    exec "$real_clang" "${filtered_args[@]}"
  else
    exec "$real_clang" "$@"
  fi
fi

# find the first argument that has a _dependency_info.dat extension
for arg in "$@"; do
  if [[ "$arg" == *_dependency_info.dat ]]; then
    ld_version=$(ld -v 2>&1 | grep ^@)
    printf "\0%s\0" "$ld_version" > "$arg"
  fi
done

while test $# -gt 0
do
  case $1 in
  -MF)
    shift
    touch "$1"
    ;;
  --serialize-diagnostics)
    shift
    cp "${BASH_SOURCE%/*}/cc.dia" "$1"
    ;;
  *.o)
    break
    ;;
  -v)
    # TODO: Make this work with custom toolchains
    DEV_DIR_PREFIX=$(awk '{ sub(/.*-isysroot /, ""); sub(/.Contents\/Developer.*/, ""); print}' <<< "${@:1}")
    clang="$DEV_DIR_PREFIX/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/clang"
    "$clang" "${@:1}"
    break
    ;;
  esac

  shift
done
