import PBXProj
import ToolCommon

extension Generator {
    struct CreateCreateLinkDependenciesBuildPhaseObject {
        private let callable: Callable

        /// - Parameters:
        ///   - callable: The function that will be called in
        ///     `callAsFunction()`.
        init(callable: @escaping Callable = Self.defaultCallable) {
            self.callable = callable
        }

        /// Creates the "Create Link Dependencies" build phase object for a
        /// target.
        func callAsFunction(
            subIdentifier: Identifiers.Targets.SubIdentifier,
            hasCompileStub: Bool
        ) -> Object {
            return callable(
                /*subIdentifier:*/ subIdentifier,
                /*hasCompileStub:*/ hasCompileStub
            )
        }
    }
}

// MARK: - CreateCreateLinkDependenciesBuildPhaseObject.Callable

extension Generator.CreateCreateLinkDependenciesBuildPhaseObject {
    typealias Callable = (
        _ subIdentifier: Identifiers.Targets.SubIdentifier,
        _ hasCompileStub: Bool
    ) -> Object

    static func defaultCallable(
        subIdentifier: Identifiers.Targets.SubIdentifier,
        hasCompileStub: Bool
    ) -> Object {
        // Shell script that:
        // 1. Expands environment variables in link.params
        // 2. Filters out libraries that will be compiled by Xcode to avoid duplicate symbols
        // 3. Creates empty stub libraries so -l flags find empty libraries instead of Bazel's
        // Uses perl for filtering since /bin/sh doesn't support associative arrays
        let action = #"""
perl -e '
use strict;
use warnings;

# Build hash of libraries to exclude
my %exclude_libs;
if (defined $ENV{RULES_XCODEPROJ_MERGED_LIBS} && $ENV{RULES_XCODEPROJ_MERGED_LIBS} ne "") {
    foreach my $lib (split /;/, $ENV{RULES_XCODEPROJ_MERGED_LIBS}) {
        $exclude_libs{$lib} = 1 if $lib ne "";
    }
}

# Process input file
open my $in, "<", $ENV{SCRIPT_INPUT_FILE_0} or die "Cannot open input: $!";
open my $out, ">", $ENV{SCRIPT_OUTPUT_FILE_0} or die "Cannot open output: $!";


my $skip_next = 0;
while (my $line = <$in>) {
    chomp $line;

    # Expand environment variables
    $line =~ s/\$\(([a-zA-Z_]\w*)\)/$ENV{$1} \/\/ ""/ge;
    $line =~ s/\$([a-zA-Z_]\w*)/$ENV{$1} \/\/ ""/ge;

    if ($skip_next) {
        $skip_next = 0;
        next;
    }

    # Check if this is -force_load followed by a library to filter
    if ($line eq "-force_load") {
        my $next_line = <$in>;
        if (defined $next_line) {
            chomp $next_line;
            $next_line =~ s/\$\(([a-zA-Z_]\w*)\)/$ENV{$1} \/\/ ""/ge;
            $next_line =~ s/\$([a-zA-Z_]\w*)/$ENV{$1} \/\/ ""/ge;

            if ($next_line =~ /lib([^\/]+)\.a$/) {
                my $libname = $1;
                if (exists $exclude_libs{$libname}) {
                    next;  # Skip both -force_load and the library path
                }
            }
            # Not filtered, output both
            print $out "$line\n";
            print $out "$next_line\n";
            next;
        }
    }

    # Check for library path pattern
    if ($line =~ /lib([^\/]+)\.a$/) {
        my $libname = $1;
        next if exists $exclude_libs{$libname};
    }

    # Check for -l<libname> pattern
    if ($line =~ /^-l(.+)$/) {
        my $libname = $1;
        next if exists $exclude_libs{$libname};
    }

    # Filter out -ObjC flag for preview builds since it forces loading all
    # archive members, causing duplicate symbols with Xcode-compiled objects
    if (keys %exclude_libs && $line eq "-ObjC") {
        next;
    }

    print $out "$line\n";
}

close $in;
close $out;
'
"""#
        var shellScriptComponents: [String] = [
            #"""
set -euo pipefail

if [[ "${ENABLE_PREVIEWS:-}" == "YES" ]]; then
\#(action)
else
  touch "$SCRIPT_OUTPUT_FILE_0"
fi

"""#,
        ]

        var outputPaths = [#"""
				"$(DERIVED_FILE_DIR)/link.params",
"""#]
        if hasCompileStub {
            outputPaths.append(#"""
				"$(DERIVED_FILE_DIR)/_CompileStub_.m",
"""#)
            shellScriptComponents.append(#"""
touch "$SCRIPT_OUTPUT_FILE_1"

"""#)
        }

        // The tabs for indenting are intentional
        let content = #"""
{
			isa = PBXShellScriptBuildPhase;
			buildActionMask = 2147483647;
			files = (
			);
			inputPaths = (
				"$(LINK_PARAMS_FILE)",
			);
			name = "Create Link Dependencies";
			outputPaths = (
\#(outputPaths.joined(separator: "\n"))
			);
			runOnlyForDeploymentPostprocessing = 0;
			shellPath = /bin/sh;
			shellScript = \#(
    shellScriptComponents.joined(separator: "\n").pbxProjEscaped
);
			showEnvVarsInLog = 0;
		}
"""#

        return Object(
            identifier: Identifiers.Targets.buildPhase(
                .createLinkDependencies,
                subIdentifier: subIdentifier
            ),
            content: content
        )
    }
}
