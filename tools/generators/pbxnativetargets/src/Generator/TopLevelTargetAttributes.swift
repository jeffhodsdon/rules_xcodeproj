import ArgumentParser
import Foundation
import PBXProj
import ToolCommon

struct TopLevelTargetAttributes {
    let bundleID: String?

    /// e.g. "bazel-out/App.zip" or "bazel-out/App.app"
    let outputsProductPath: String?

    let linkParams: String?
    let executableName: String?
    let compileTargetIDs: String?
    let unitTestHost: TargetID?

    /// Semicolon-separated library names for runtime filtering during previews.
    /// e.g., "AppLib;OtherLib" for -lAppLib and -lOtherLib
    let mergedProductLibNames: String?
}

extension Dictionary<TargetID, TopLevelTargetAttributes> {
    static func parse(from url: URL) async throws -> Self {
        var rawArgs = ArraySlice(try await url.allLines.collect())

        guard rawArgs.count.isMultiple(of: 8) else {
            throw PreconditionError(message: """
"\(url.path)": Number of lines must be a multiple of 8.
""")
        }

        let targetCount = rawArgs.count / 8

        var keysWithValues: [(TargetID, TopLevelTargetAttributes)] = []
        for _ in (0..<targetCount) {
            let id =
                try rawArgs.consumeArg("target-id", as: TargetID.self, in: url)
            let bundleID =
                try rawArgs.consumeArg("bundle-id", as: String?.self, in: url)
            let outputsProductPath = try rawArgs.consumeArg(
                "outputs-product-path",
                as: String?.self,
                in: url
            )
            let linkParams =
                try rawArgs.consumeArg("link-params", as: String?.self, in: url)
            let executableName = try rawArgs.consumeArg(
                "executable-name",
                as: String?.self,
                in: url
            )
            let compileTargetIDs = try rawArgs.consumeArg(
                "compile-target-ids",
                as: String?.self,
                in: url
            )
            let unitTestHost = try rawArgs.consumeArg(
                "unit-test-host",
                as: TargetID?.self,
                in: url
            )
            let mergedProductLibNames = try rawArgs.consumeArg(
                "merged-product-lib-names",
                as: String?.self,
                in: url
            )

            keysWithValues.append(
                (
                    id,
                    .init(
                        bundleID: bundleID,
                        outputsProductPath: outputsProductPath,
                        linkParams: linkParams,
                        executableName: executableName,
                        compileTargetIDs: compileTargetIDs,
                        unitTestHost: unitTestHost,
                        mergedProductLibNames: mergedProductLibNames
                    )
                )
            )
        }

        return Dictionary(uniqueKeysWithValues: keysWithValues)
    }
}

private extension Array {
    func slicedBy<CountsCollection>(
        targetIndex: Int,
        counts: CountsCollection,
        startIndex: inout Index
    ) -> Self where
        CountsCollection: RandomAccessCollection,
        CountsCollection.Element == Int,
        CountsCollection.Index == Index
    {
        guard !isEmpty else {
            return self
        }

        let endIndex = startIndex.advanced(by: counts[targetIndex])
        let range = startIndex ..< endIndex
        startIndex = endIndex

        return Array(self[range])
    }
}
