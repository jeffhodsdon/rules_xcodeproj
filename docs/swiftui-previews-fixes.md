# SwiftUI Previews Fixes for rules_xcodeproj

This document describes fixes implemented to enable SwiftUI Previews in Xcode for projects using rules_xcodeproj with BwX (Build with Xcode) mode.

## Background

SwiftUI Previews in rules_xcodeproj-generated projects were failing with various errors. This work builds on PRs [#3139](https://github.com/MobileNativeFoundation/rules_xcodeproj/pull/3139) and [#3140](https://github.com/MobileNativeFoundation/rules_xcodeproj/pull/3140) by @karim-alweheshy and @chrisballinger.

## Fixes Implemented

### 1. Filter `LINKED_BINARY=` from Linker Arguments

**File:** `tools/params_processors/link_params_processor.py`

**Problem:** The `LINKED_BINARY=` flag is a wrapped_clang-specific argument that was being passed through to the linker, causing errors like:
```
ld: file not found: LINKED_BINARY=bazel-out/.../App
```

**Fix:** Added filter to skip `LINKED_BINARY=` arguments:

```python
# These flags are for wrapped_clang only
if (opt.startswith("DSYM_HINT_DSYM_PATH=") or
    opt.startswith("DSYM_HINT_LINKED_BINARY=") or
    opt.startswith("LINKED_BINARY=")):
    return
```

### 2. Filter Malformed `-objc_abi_version` Arguments

**File:** `tools/params_processors/link_params_processor.py`

**Problem:** The `-objc_abi_version` flag was incorrectly split across 3 lines in the params file:
```
-objc_abi_version
-Xlinker
2
```

This caused the linker error:
```
ld: file cannot be open()ed, errno=2 path=2 in '2'
```

The correct version `-Wl,-objc_abi_version,2` was already present in the params.

**Fix:** Added skip rule in `_LD_SKIP_OPTS`:

```python
_LD_SKIP_OPTS = {
    # ... existing entries ...

    # This flag is incorrectly split across lines (-objc_abi_version, -Xlinker, 2)
    # and is already correctly specified as -Wl,-objc_abi_version,2
    "-objc_abi_version": 3,
}
```

### 3. Exclude Merged Product Files from Linking

**File:** `xcodeproj/internal/processed_targets/top_level_targets.bzl`

**Problem:** When a `swift_library` is merged into an `ios_application` target, Xcode compiles the Swift sources directly during preview builds. However, the Bazel-built library (e.g., `libAppLib.a`) was still being linked via `PBXFrameworksBuildPhase`, causing 56+ duplicate symbol errors:

```
duplicate symbol 'App.ContentView.body.getter : some' in:
    .../libAppLib.a[3](ContentView.swift.o)
    .../Objects-normal/arm64/ContentView.o
```

**Fix:** Filter merged product files from `libraries_path_to_link` before passing to `xcode_targets.make()`:

```python
# Exclude merged product files from libraries to link
# When sources are merged from a library target, Xcode compiles them during
# preview builds, so we shouldn't also link the Bazel-built library
raw_libraries_path_to_link = linker_input_files.get_libraries_path_to_link(linker_inputs)
if mergeable_info:
    merged_product_paths = {f.path: None for f in mergeable_info.product_files if f}
    libraries_path_to_link = depset([
        path
        for path in raw_libraries_path_to_link.to_list()
        if path not in merged_product_paths
    ])
else:
    libraries_path_to_link = raw_libraries_path_to_link
```

This change is safe for both preview and regular builds since Xcode compiles these sources itself in BwX mode.

### 4. Unique Toolchain Names per Workspace

**Files:** `xcodeproj/internal/templates/custom_toolchain_symlink.sh`, `xcodeproj/internal/templates/custom_toolchain_override.sh`

**Problem:** Multiple Bazel workspaces sharing the same toolchain symlink at `~/Library/Developer/Toolchains/` would conflict, causing `CreateSymlinkToolchain` failures when switching between projects:

```
ERROR: ApplyCustomToolchainOverrides failed to create symlink
```

**Fix:** Extract a unique workspace hash from the Bazel output base path and include it in the toolchain name:

```bash
# Extract unique workspace hash from the Bazel output base path
# Path format: /Users/j/.cache/bazel/<hash>/rules_xcodeproj.noindex/...
WORKSPACE_HASH=""
if [[ "$PWD" =~ \.cache/bazel/([a-f0-9]{8}) ]]; then
    WORKSPACE_HASH="_${BASH_REMATCH[1]}"
fi

HOME_TOOLCHAIN_NAME="BazelRulesXcodeProj${XCODE_VERSION}${WORKSPACE_HASH}"
```

This creates unique toolchains per workspace:
- `BazelRulesXcodeProj17C52_c68ec90b.xctoolchain` (project A)
- `BazelRulesXcodeProj17C52_f0a7fc99.xctoolchain` (project B)

## Requirements

### Build Before Previews

Users must perform a normal build (Cmd+B in Xcode or `xcodebuild`) before SwiftUI Previews will work. This is required because Xcode creates an SDK stat cache file on first build that the preview compiler needs.

**Error if skipped:**
```
Compiling failed: stat cache file '.../SDKStatCaches.noindex/iphonesimulator26.2-XXX.sdkstatcache' not found
```

**Workflow:**
1. Generate project: `bazel run //:xcodeproj`
2. Open in Xcode
3. **Build once** (Cmd+B)
4. Then use SwiftUI Previews

## Testing

### Test App

A minimal test app is available at `xcodeproj_swiftui/app/`:

```bash
# Generate Xcode project
cd /path/to/xcodeproj_swiftui
bazel run //app:xcodeproj

# Open in Xcode
xed app

# Build once, then test previews
```

### Using Local Fork in Your Project

Add to your `MODULE.bazel`:

```python
bazel_dep(name = "rules_xcodeproj", version = "3.5.1")

# Local override for SwiftUI Previews fixes
local_path_override(
    module_name = "rules_xcodeproj",
    path = "/path/to/xcodeproj_swiftui/rules_xcodeproj",
)
```

Or in `.bazelrc` for non-bzlmod:
```
build --override_repository=rules_xcodeproj=/path/to/rules_xcodeproj
```

## Files Modified

| File | Change |
|------|--------|
| `tools/params_processors/link_params_processor.py` | Filter `LINKED_BINARY=` and `-objc_abi_version` |
| `xcodeproj/internal/processed_targets/top_level_targets.bzl` | Exclude merged products from linking |
| `xcodeproj/internal/templates/custom_toolchain_symlink.sh` | Unique toolchain names per workspace |
| `xcodeproj/internal/templates/custom_toolchain_override.sh` | Unique toolchain names per workspace |

## Compatibility

- Tested with Xcode 26.2 beta (iOS 26.2 SDK)
- Bazel 8.x
- rules_xcodeproj 3.x (BwX mode)

## Known Limitations

1. Requires initial build before previews work (SDK stat cache creation)
2. Only tested with simple Swift-only apps; mixed ObjC/Swift may need additional work

## Related Issues & PRs

- [#3139](https://github.com/MobileNativeFoundation/rules_xcodeproj/pull/3139) - Initial preview fixes by @karim-alweheshy
- [#3140](https://github.com/MobileNativeFoundation/rules_xcodeproj/pull/3140) - Additional fixes by @chrisballinger
- [#3201](https://github.com/MobileNativeFoundation/rules_xcodeproj/issues/3201) - SwiftUI Previews tracking issue
