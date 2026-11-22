import Foundation

struct AppLaunchConfiguration: Sendable {
    var inputPaths: [String] = []
    var nameDatabasePaths: [String] = []
    var duplicateStrategy: DuplicateStrategy = .overwriteLater
    var useRAHeaderFlag: Bool? = nil
    var expandNested: Bool = false

    static var shared = AppLaunchConfiguration()
}

struct CLIIO {
    let writeStdout: (String) -> Void
    let writeStderr: (String) -> Void

    static let standard = CLIIO(
        writeStdout: { text in
            if let data = text.data(using: .utf8) {
                FileHandle.standardOutput.write(data)
            }
        },
        writeStderr: { text in
            if let data = text.data(using: .utf8) {
                FileHandle.standardError.write(data)
            }
        }
    )

    func out(_ line: String) {
        writeStdout(line + "\n")
    }

    func err(_ line: String) {
        writeStderr(line + "\n")
    }
}

enum CLIParseError: LocalizedError {
    case invalidArguments(String)
    case helpRequested(String?)

    var errorDescription: String? {
        switch self {
        case .invalidArguments(let msg): return msg
        case .helpRequested: return nil
        }
    }
}

struct MixCLI {
    static let version = "1.0.0"

    static func shouldRunCLI(arguments: [String], environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        if environment["XCTestConfigurationFilePath"] != nil ||
            environment["XCTestBundlePath"] != nil ||
            environment["XCInjectBundleInto"] != nil {
            return false
        }

        let userArgs = stripSystemLaunchArguments(Array(arguments.dropFirst()))
        guard let first = userArgs.first else {
            return false
        }
        if first == "--gui" || first == "gui" {
            return false
        }
        return true
    }

    static func parseGUILaunchConfiguration(arguments: [String]) -> AppLaunchConfiguration {
        let userArgs = stripSystemLaunchArguments(Array(arguments.dropFirst()))
        var config = AppLaunchConfiguration()
        var idx = 0
        while idx < userArgs.count {
            let arg = userArgs[idx]
            if arg == "--gui" || arg == "gui" {
                idx += 1
                continue
            } else if arg == "--ra-header" {
                config.useRAHeaderFlag = true
            } else if arg == "--no-ra-header" {
                config.useRAHeaderFlag = false
            } else if arg == "--expand-nested" || arg == "--flatten" {
                config.expandNested = true
            } else if arg == "--duplicates", idx + 1 < userArgs.count {
                idx += 1
                if let parsed = parseDuplicateStrategy(userArgs[idx]) {
                    config.duplicateStrategy = parsed
                }
            } else if arg == "--names", idx + 1 < userArgs.count {
                idx += 1
                config.nameDatabasePaths.append(userArgs[idx])
            } else if !arg.hasPrefix("-") {
                config.inputPaths.append(arg)
            }
            idx += 1
        }
        return config
    }

    static func stripSystemLaunchArguments(_ args: [String]) -> [String] {
        var filtered: [String] = []
        var skipNext = false
        for arg in args {
            if skipNext {
                skipNext = false
                continue
            }
            if arg.hasPrefix("-psn_") {
                continue
            }
            if arg == "-NSDocumentRevisionsDebugMode" || arg == "-ApplePersistenceIgnoreState" {
                skipNext = true
                continue
            }
            if arg.hasPrefix("-NS") || arg.hasPrefix("-Apple") {
                continue
            }
            filtered.append(arg)
        }
        return filtered
    }

    @discardableResult
    static func run(arguments: [String], io: CLIIO = .standard) -> Int32 {
        let args = stripSystemLaunchArguments(arguments)
        guard let command = args.first else {
            io.out(globalHelpText)
            return 0
        }

        let rest = Array(args.dropFirst())
        let cmdLower = command.lowercased()

        do {
            switch cmdLower {
            case "-h", "--help", "help":
                if let topic = rest.first?.lowercased() {
                    io.out(helpText(for: topic))
                } else {
                    io.out(globalHelpText)
                }
                return 0
            case "-v", "--version", "version":
                io.out("CCMixStudio \(version)")
                return 0
            case "combine", "merge":
                try runCombine(args: rest, io: io)
            case "pack":
                try runPack(args: rest, io: io)
            case "inspect", "info":
                try runInspect(args: rest, io: io)
            case "list", "ls":
                try runList(args: rest, io: io)
            case "extract":
                try runExtract(args: rest, io: io)
            case "cat", "preview":
                try runCat(args: rest, io: io)
            case "export-shp":
                try runExportSHP(args: rest, io: io)
            case "export-aud":
                try runExportAUD(args: rest, io: io)
            case "export-vqa":
                try runExportVQA(args: rest, io: io)
            case "crc":
                try runCRC(args: rest, io: io)
            case "dict":
                try runDict(args: rest, io: io)
            case "verify":
                try runVerify(args: rest, io: io)
            default:
                throw CLIParseError.invalidArguments(
                    "Unknown command '\(command)'. Run 'CCMixStudio --help' for usage, or pass '--gui' to launch the desktop window."
                )
            }
            return 0
        } catch CLIParseError.helpRequested(let topic) {
            io.out(helpText(for: topic))
            return 0
        } catch let parseErr as CLIParseError {
            io.err("Error: \(parseErr.localizedDescription)")
            return 2
        } catch {
            io.err("Error: \(error.localizedDescription)")
            return 1
        }
    }

    // MARK: - Subcommand: combine

    private static func runCombine(args: [String], io: CLIIO) throws {
        var mixInputs: [String] = []
        var looseFiles: [String] = []
        var looseDirs: [String] = []
        var recursiveLoose = false
        var outputPath: String?
        var namePaths: [String] = []
        var options = MixCombineOptions()
        var dryRun = false
        var jsonOutput = false
        var quiet = false

        var idx = 0
        while idx < args.count {
            let arg = args[idx]
            switch arg {
            case "-h", "--help":
                throw CLIParseError.helpRequested("combine")
            case "-o", "--output":
                outputPath = try nextValue(args, index: &idx, flag: arg)
            case "-i", "--input":
                mixInputs.append(try nextValue(args, index: &idx, flag: arg))
            case "--add-file":
                looseFiles.append(try nextValue(args, index: &idx, flag: arg))
            case "--add-dir":
                looseDirs.append(try nextValue(args, index: &idx, flag: arg))
            case "-r", "--recursive":
                recursiveLoose = true
            case "--duplicates", "--duplicate-policy":
                let val = try nextValue(args, index: &idx, flag: arg)
                guard let parsed = parseDuplicateStrategy(val) else {
                    throw CLIParseError.invalidArguments("Invalid duplicate policy '\(val)'. Expected: overwrite-later, keep-first, keep-all.")
                }
                options.duplicateStrategy = parsed
            case "--format":
                let val = try nextValue(args, index: &idx, flag: arg)
                guard let fmt = MixOutputFormat(cliValue: val) else {
                    throw CLIParseError.invalidArguments("Invalid format '\(val)'. Expected: openra, auto, ra, classic.")
                }
                options.format = fmt
            case "--ra-header":
                options.includeRAHeaderFlagOverride = true
            case "--no-ra-header":
                options.includeRAHeaderFlagOverride = false
            case "--expand-nested", "--flatten":
                options.expandNestedMix = true
            case "--expand":
                options.nestedFilters.append(try nextValue(args, index: &idx, flag: arg))
            case "--expand-depth":
                let raw = try nextValue(args, index: &idx, flag: arg)
                guard let depth = Int(raw), depth >= 0 else {
                    throw CLIParseError.invalidArguments("Invalid --expand-depth '\(raw)'. Expected a non-negative integer.")
                }
                options.maxNestedDepth = depth
                options.expandNestedMix = true
            case "--keep-nested-containers":
                options.keepNestedContainers = true
            case "--filter":
                options.filterQuery = try nextValue(args, index: &idx, flag: arg)
            case "--include":
                options.includePatterns.append(try nextValue(args, index: &idx, flag: arg))
            case "--exclude":
                options.excludePatterns.append(try nextValue(args, index: &idx, flag: arg))
            case "--names":
                namePaths.append(try nextValue(args, index: &idx, flag: arg))
            case "--local-db":
                let val = try nextValue(args, index: &idx, flag: arg)
                guard let policy = LocalMixDBPolicy(cliValue: val) else {
                    throw CLIParseError.invalidArguments("Invalid --local-db policy '\(val)'. Expected: merge, keep, strip, generate.")
                }
                options.localDBPolicy = policy
            case "--verify":
                options.verifyOutput = true
            case "--no-verify":
                options.verifyOutput = false
            case "--dry-run":
                dryRun = true
            case "--json":
                jsonOutput = true
            case "-q", "--quiet":
                quiet = true
            default:
                if arg.hasPrefix("-") {
                    throw CLIParseError.invalidArguments("Unknown option '\(arg)' for 'combine'.")
                }
                mixInputs.append(arg)
            }
            idx += 1
        }

        if !dryRun && outputPath == nil {
            throw CLIParseError.invalidArguments("Missing required output path (-o / --output <output.mix>).")
        }

        try importNameDatabases(paths: namePaths)

        var archives = try loadArchives(paths: mixInputs)
        let extraFiles = try collectInputFiles(files: looseFiles, directories: looseDirs, recursive: recursiveLoose)
        if !extraFiles.isEmpty {
            archives.append(try buildSyntheticArchive(from: extraFiles))
        }

        let result = try MixCombineEngine.combine(archives: archives, options: options)

        if !dryRun, let outPath = outputPath {
            let outURL = URL(fileURLWithPath: outPath)
            try ensureParentDirectory(for: outURL)
            try result.data.write(to: outURL, options: .atomic)
        }

        if jsonOutput {
            struct CombineJSON: Codable {
                let outputPath: String?
                let dryRun: Bool
                let inputArchiveCount: Int
                let expandedNestedCount: Int
                let entryCount: Int
                let duplicatesResolved: Int
                let byteSize: Int
                let usedRAHeaderFlag: Bool
                let format: String
                let localDBAction: String
                let warnings: [String]
                let verification: MixVerificationReport?
            }
            let payload = CombineJSON(
                outputPath: outputPath,
                dryRun: dryRun,
                inputArchiveCount: mixInputs.count + (extraFiles.isEmpty ? 0 : 1),
                expandedNestedCount: result.expandedNestedCount,
                entryCount: result.mergedEntries.count,
                duplicatesResolved: result.duplicatesResolved,
                byteSize: result.data.count,
                usedRAHeaderFlag: result.usedRAHeaderFlag,
                format: options.format.rawValue,
                localDBAction: result.localDBAction,
                warnings: result.warnings,
                verification: result.verification
            )
            io.out(try encodeJSON(payload))
            return
        }

        if !quiet {
            let targetLabel = dryRun ? "[dry-run]" : (outputPath ?? "COMBINED.MIX")
            io.out("Combined -> \(targetLabel)")
            io.out("  Entries: \(result.mergedEntries.count) (\(result.duplicatesResolved) duplicate(s) resolved via \(options.duplicateStrategy.rawValue))")
            io.out("  Size: \(result.data.count) bytes (\(formatBytes(result.data.count)))")
            io.out("  Header: \(result.usedRAHeaderFlag ? "Red Alert / Extended (4-byte 0x00000000 flags)" : "Tiberian Dawn / Classic (6-byte)") [mode: \(options.format.rawValue)]")
            if result.expandedNestedCount > 0 {
                io.out("  Expanded nested .MIX archives: \(result.expandedNestedCount)")
            }
            io.out("  Local Mix Database: \(result.localDBAction)")
            if let v = result.verification {
                io.out("  OpenRA Compatible: \(v.openRACompatible ? "YES" : "NO") (sorted=\(v.isSortedByCRC), duplicateCRCs=\(v.duplicateCRCCount))")
            }
            for warning in result.warnings {
                io.err("Warning: \(warning)")
            }
        }
    }

    // MARK: - Subcommand: pack

    private static func runPack(args: [String], io: CLIIO) throws {
        var inputFiles: [String] = []
        var inputDirs: [String] = []
        var recursive = false
        var outputPath: String?
        var namePaths: [String] = []
        var options = MixCombineOptions()
        options.localDBPolicy = .generate
        var dryRun = false
        var jsonOutput = false
        var quiet = false

        var idx = 0
        while idx < args.count {
            let arg = args[idx]
            switch arg {
            case "-h", "--help":
                throw CLIParseError.helpRequested("pack")
            case "-o", "--output":
                outputPath = try nextValue(args, index: &idx, flag: arg)
            case "-r", "--recursive":
                recursive = true
            case "--duplicates":
                let val = try nextValue(args, index: &idx, flag: arg)
                guard let parsed = parseDuplicateStrategy(val) else {
                    throw CLIParseError.invalidArguments("Invalid duplicate policy '\(val)'.")
                }
                options.duplicateStrategy = parsed
            case "--format":
                let val = try nextValue(args, index: &idx, flag: arg)
                guard let fmt = MixOutputFormat(cliValue: val) else {
                    throw CLIParseError.invalidArguments("Invalid format '\(val)'.")
                }
                options.format = fmt
            case "--ra-header":
                options.includeRAHeaderFlagOverride = true
            case "--no-ra-header":
                options.includeRAHeaderFlagOverride = false
            case "--local-db":
                let val = try nextValue(args, index: &idx, flag: arg)
                guard let policy = LocalMixDBPolicy(cliValue: val) else {
                    throw CLIParseError.invalidArguments("Invalid --local-db policy '\(val)'.")
                }
                options.localDBPolicy = policy
            case "--names":
                namePaths.append(try nextValue(args, index: &idx, flag: arg))
            case "--verify":
                options.verifyOutput = true
            case "--no-verify":
                options.verifyOutput = false
            case "--dry-run":
                dryRun = true
            case "--json":
                jsonOutput = true
            case "-q", "--quiet":
                quiet = true
            default:
                if arg.hasPrefix("-") {
                    throw CLIParseError.invalidArguments("Unknown option '\(arg)' for 'pack'.")
                }
                var isDir: ObjCBool = false
                if FileManager.default.fileExists(atPath: arg, isDirectory: &isDir), isDir.boolValue {
                    inputDirs.append(arg)
                } else {
                    inputFiles.append(arg)
                }
            }
            idx += 1
        }

        if !dryRun && outputPath == nil {
            throw CLIParseError.invalidArguments("Missing required output path (-o / --output <output.mix>).")
        }

        try importNameDatabases(paths: namePaths)
        let urls = try collectInputFiles(files: inputFiles, directories: inputDirs, recursive: recursive)
        let result = try MixCombineEngine.packFiles(fileURLs: urls, options: options)

        if !dryRun, let outPath = outputPath {
            let outURL = URL(fileURLWithPath: outPath)
            try ensureParentDirectory(for: outURL)
            try result.data.write(to: outURL, options: .atomic)
        }

        if jsonOutput {
            struct PackJSON: Codable {
                let outputPath: String?
                let dryRun: Bool
                let packedFileCount: Int
                let entryCount: Int
                let byteSize: Int
                let usedRAHeaderFlag: Bool
                let verification: MixVerificationReport?
            }
            let payload = PackJSON(
                outputPath: outputPath,
                dryRun: dryRun,
                packedFileCount: urls.count,
                entryCount: result.mergedEntries.count,
                byteSize: result.data.count,
                usedRAHeaderFlag: result.usedRAHeaderFlag,
                verification: result.verification
            )
            io.out(try encodeJSON(payload))
            return
        }

        if !quiet {
            io.out("Packed \(urls.count) file(s) -> \(dryRun ? "[dry-run]" : (outputPath ?? ""))")
            io.out("  Entries: \(result.mergedEntries.count) • Size: \(result.data.count) bytes (\(formatBytes(result.data.count)))")
            io.out("  OpenRA Compatible: \(result.verification?.openRACompatible == true ? "YES" : "unverified")")
        }
    }

    // MARK: - Subcommand: inspect

    private static func runInspect(args: [String], io: CLIIO) throws {
        let parsed = try parseArchiveQueryArgs(args, command: "inspect", allowShowEntries: true)
        try importNameDatabases(paths: parsed.namePaths)
        let loaded = try loadArchives(paths: parsed.inputPaths)
        let prepared = try prepareArchivesForQuery(loaded, queryArgs: parsed)

        let merged = WestwoodMixEngine.merge(
            archives: prepared.archives,
            strategy: parsed.duplicateStrategy,
            includeRAHeaderFlag: prepared.archives.contains { $0.variant == .redAlertTS || $0.variant == .redAlertTSEncrypted }
        )
        let filtered = filterEntries(merged.mergedEntries, queryArgs: parsed)

        if parsed.jsonOutput {
            struct ArchiveJSON: Codable {
                let fileName: String
                let fileSize: Int
                let variant: String
                let wasEncrypted: Bool
                let isExpandedChild: Bool
                let entryCount: Int
                let nestedMixCount: Int
            }
            struct InspectJSON: Codable {
                let archives: [ArchiveJSON]
                let expandedNestedCount: Int
                let mergedEntryCount: Int
                let filteredEntryCount: Int
                let duplicatesResolved: Int
                let mergedByteSize: Int
                let dictionaryCount: Int
                let entries: [EntryJSON]?
            }
            let archiveItems = prepared.archives.map { arch in
                ArchiveJSON(
                    fileName: arch.fileName,
                    fileSize: arch.fileSize,
                    variant: arch.variant.rawValue,
                    wasEncrypted: arch.wasEncrypted,
                    isExpandedChild: arch.isExpandedChild,
                    entryCount: arch.entries.count,
                    nestedMixCount: arch.entries.filter { $0.isNestedMix }.count
                )
            }
            let entryItems = parsed.showEntries ? filtered.map { EntryJSON($0) } : nil
            let payload = InspectJSON(
                archives: archiveItems,
                expandedNestedCount: prepared.expandedCount,
                mergedEntryCount: merged.mergedEntries.count,
                filteredEntryCount: filtered.count,
                duplicatesResolved: merged.duplicatesResolved,
                mergedByteSize: merged.data.count,
                dictionaryCount: WestwoodNameDatabase.shared.count,
                entries: entryItems
            )
            io.out(try encodeJSON(payload))
            return
        }

        io.out("Archives (\(prepared.archives.count)):")
        for arch in prepared.archives {
            let nested = arch.entries.filter { $0.isNestedMix }.count
            let enc = arch.wasEncrypted ? " [Encrypted Header]" : ""
            let child = arch.isExpandedChild ? " [Expanded Nested]" : ""
            io.out("  - \(arch.fileName): \(arch.entries.count) entries, \(formatBytes(arch.fileSize)), \(arch.variant.rawValue)\(enc)\(child)\(nested > 0 ? ", \(nested) nested .MIX" : "")")
        }
        io.out("Merge Preview: \(merged.mergedEntries.count) entries, \(formatBytes(merged.data.count)), \(merged.duplicatesResolved) duplicate(s) resolved (\(parsed.duplicateStrategy.rawValue))")
        io.out("Global Name Dictionary: \(WestwoodNameDatabase.shared.count) known names")
        if parsed.showEntries {
            io.out("")
            printEntryTable(filtered, io: io)
        }
    }

    // MARK: - Subcommand: list

    private static func runList(args: [String], io: CLIIO) throws {
        let parsed = try parseArchiveQueryArgs(args, command: "list", allowRawList: true)
        try importNameDatabases(paths: parsed.namePaths)
        let loaded = try loadArchives(paths: parsed.inputPaths)
        let prepared = try prepareArchivesForQuery(loaded, queryArgs: parsed)

        let baseEntries: [MixEntry]
        if parsed.rawList {
            baseEntries = prepared.archives.flatMap { $0.entries }
        } else {
            baseEntries = WestwoodMixEngine.merge(
                archives: prepared.archives,
                strategy: parsed.duplicateStrategy,
                includeRAHeaderFlag: false
            ).mergedEntries
        }

        let filtered = filterEntries(baseEntries, queryArgs: parsed)

        if parsed.jsonOutput {
            io.out(try encodeJSON(filtered.map { EntryJSON($0) }))
            return
        }

        printEntryTable(filtered, io: io)
        io.out("Total: \(filtered.count) entry(s)")
    }

    // MARK: - Subcommand: extract

    private static func runExtract(args: [String], io: CLIIO) throws {
        var outputPath: String?
        var entryQueries: [String] = []
        var remaining: [String] = []

        var idx = 0
        while idx < args.count {
            let arg = args[idx]
            if arg == "-o" || arg == "--output" {
                outputPath = try nextValue(args, index: &idx, flag: arg)
            } else if arg == "--entry" {
                entryQueries.append(try nextValue(args, index: &idx, flag: arg))
            } else {
                remaining.append(arg)
            }
            idx += 1
        }

        let parsed = try parseArchiveQueryArgs(remaining, command: "extract")
        guard let outPath = outputPath else {
            throw CLIParseError.invalidArguments("Missing required output path (-o / --output <dir-or-file>).")
        }

        try importNameDatabases(paths: parsed.namePaths)
        let loaded = try loadArchives(paths: parsed.inputPaths)
        let prepared = try prepareArchivesForQuery(loaded, queryArgs: parsed)

        let merged = WestwoodMixEngine.merge(
            archives: prepared.archives,
            strategy: parsed.duplicateStrategy,
            includeRAHeaderFlag: false
        )

        let entriesToExtract: [MixEntry]
        if !entryQueries.isEmpty {
            entriesToExtract = try entryQueries.map { try MixCombineEngine.resolveEntry(in: merged.mergedEntries, query: $0) }
        } else {
            entriesToExtract = filterEntries(merged.mergedEntries, queryArgs: parsed)
        }

        guard !entriesToExtract.isEmpty else {
            throw MixCombineError.entryNotFound("No matching entries to extract.")
        }

        let outURL = URL(fileURLWithPath: outPath)
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: outPath, isDirectory: &isDir)

        if entriesToExtract.count == 1 && !entryQueries.isEmpty && (!exists || !isDir.boolValue) && !outPath.hasSuffix("/") {
            let single = entriesToExtract[0]
            try ensureParentDirectory(for: outURL)
            try single.payload.write(to: outURL, options: .atomic)
            if parsed.jsonOutput {
                struct ExtractSingleJSON: Codable {
                    let extracted: [String]
                    let count: Int
                }
                io.out(try encodeJSON(ExtractSingleJSON(extracted: [outURL.path], count: 1)))
            } else {
                io.out("Extracted \(single.displayLabel) -> \(outPath) (\(single.payload.count) bytes)")
            }
            return
        }

        try FileManager.default.createDirectory(at: outURL, withIntermediateDirectories: true)
        let count = try WestwoodMixEngine.batchExtract(entries: entriesToExtract, to: outURL)

        if parsed.jsonOutput {
            struct ExtractJSON: Codable {
                let outputDirectory: String
                let extractedCount: Int
            }
            io.out(try encodeJSON(ExtractJSON(outputDirectory: outURL.path, extractedCount: count)))
        } else {
            io.out("Extracted \(count) file(s) to \(outPath)")
        }
    }

    // MARK: - Subcommand: cat / preview

    private static func runCat(args: [String], io: CLIIO) throws {
        var entryQuery: String?
        var forceHex = false
        var rawOutput = false
        var maxBytes = 65_536
        var remaining: [String] = []

        var idx = 0
        while idx < args.count {
            let arg = args[idx]
            switch arg {
            case "--entry":
                entryQuery = try nextValue(args, index: &idx, flag: arg)
            case "--hex":
                forceHex = true
            case "--raw":
                rawOutput = true
            case "--max-bytes":
                let val = try nextValue(args, index: &idx, flag: arg)
                guard let n = Int(val), n > 0 else {
                    throw CLIParseError.invalidArguments("Invalid --max-bytes '\(val)'.")
                }
                maxBytes = n
            default:
                remaining.append(arg)
            }
            idx += 1
        }

        let parsed = try parseArchiveQueryArgs(remaining, command: "cat")
        guard let query = entryQuery else {
            throw CLIParseError.invalidArguments("Missing required --entry <name-or-crc> for 'cat'.")
        }

        try importNameDatabases(paths: parsed.namePaths)
        let loaded = try loadArchives(paths: parsed.inputPaths)
        let prepared = try prepareArchivesForQuery(loaded, queryArgs: parsed)
        let merged = WestwoodMixEngine.merge(archives: prepared.archives, strategy: parsed.duplicateStrategy, includeRAHeaderFlag: false)
        let entry = try MixCombineEngine.resolveEntry(in: merged.mergedEntries, query: query)

        if rawOutput {
            FileHandle.standardOutput.write(entry.payload)
            return
        }

        if !forceHex && entry.detectedType == "INI / Text" {
            let slice = entry.payload.prefix(maxBytes)
            let text = String(data: slice, encoding: .windowsCP1252) ?? String(decoding: slice, as: UTF8.self)
            io.out(text)
            return
        }

        if !forceHex && entry.detectedType == "PAL (256-Color)" && entry.payload.count >= 768 {
            io.out("Palette \(entry.displayLabel) (256 6-bit VGA entries):")
            for i in 0..<256 {
                let base = i * 3
                io.out(String(format: "  [%3d] R=%2d G=%2d B=%2d", i, entry.payload[base], entry.payload[base + 1], entry.payload[base + 2]))
            }
            return
        }

        let slice = entry.payload.prefix(maxBytes)
        io.out(hexDump(data: slice))
    }

    // MARK: - Subcommand: export-shp

    private static func runExportSHP(args: [String], io: CLIIO) throws {
        var entryQuery: String?
        var outputPath: String?
        var paletteSpec = "snow"
        var frameIndex: Int?
        var exportSheet = false
        var exportAllFrames = false
        var sheetColumns: Int?
        var remaining: [String] = []

        var idx = 0
        while idx < args.count {
            let arg = args[idx]
            switch arg {
            case "--entry":
                entryQuery = try nextValue(args, index: &idx, flag: arg)
            case "-o", "--output":
                outputPath = try nextValue(args, index: &idx, flag: arg)
            case "--palette":
                paletteSpec = try nextValue(args, index: &idx, flag: arg)
            case "--frame":
                let val = try nextValue(args, index: &idx, flag: arg)
                guard let n = Int(val), n >= 0 else {
                    throw CLIParseError.invalidArguments("Invalid --frame '\(val)'.")
                }
                frameIndex = n
            case "--sheet":
                exportSheet = true
            case "--all-frames":
                exportAllFrames = true
            case "--columns":
                let val = try nextValue(args, index: &idx, flag: arg)
                guard let n = Int(val), n > 0 else {
                    throw CLIParseError.invalidArguments("Invalid --columns '\(val)'.")
                }
                sheetColumns = n
            default:
                remaining.append(arg)
            }
            idx += 1
        }

        let parsed = try parseArchiveQueryArgs(remaining, command: "export-shp")
        guard let outPath = outputPath else {
            throw CLIParseError.invalidArguments("Missing required output path (-o / --output <out.png or dir>).")
        }

        try importNameDatabases(paths: parsed.namePaths)

        let shpData: Data
        let mergedEntries: [MixEntry]
        let baseName: String

        if parsed.inputPaths.count == 1 && entryQuery == nil && !parsed.inputPaths[0].lowercased().hasSuffix(".mix") {
            let url = URL(fileURLWithPath: parsed.inputPaths[0])
            shpData = try Data(contentsOf: url)
            mergedEntries = []
            baseName = url.deletingPathExtension().lastPathComponent
        } else {
            guard let query = entryQuery else {
                throw CLIParseError.invalidArguments("Specify --entry <name-or-crc> when reading from .MIX archive(s), or pass a standalone .SHP file.")
            }
            let loaded = try loadArchives(paths: parsed.inputPaths)
            let prepared = try prepareArchivesForQuery(loaded, queryArgs: parsed)
            let merged = WestwoodMixEngine.merge(archives: prepared.archives, strategy: parsed.duplicateStrategy, includeRAHeaderFlag: false)
            mergedEntries = merged.mergedEntries
            let entry = try MixCombineEngine.resolveEntry(in: mergedEntries, query: query)
            shpData = entry.payload
            baseName = (entry.knownName as NSString?)?.deletingPathExtension ?? entry.hexID
        }

        guard let sprite = WestwoodSHPDecoder.decodeSHP(shpData) else {
            throw MixCombineError.unsupportedOperation("Input is not a valid Westwood .SHP sprite.")
        }

        let palette = try resolvePalette(spec: paletteSpec, entries: mergedEntries)
        let outURL = URL(fileURLWithPath: outPath)

        if exportAllFrames {
            try FileManager.default.createDirectory(at: outURL, withIntermediateDirectories: true)
            var writtenPaths: [String] = []
            for f in 0..<sprite.frameCount {
                guard let png = sprite.pngData(forFrame: f, palette768: palette) else {
                    throw MixCombineError.unsupportedOperation("Failed to render SHP frame \(f).")
                }
                let fileURL = outURL.appendingPathComponent("\(baseName)_frame\(f + 1).png")
                try png.write(to: fileURL, options: .atomic)
                writtenPaths.append(fileURL.path)
            }
            if parsed.jsonOutput {
                struct SHPFramesJSON: Codable {
                    let frames: [String]
                    let width: Int
                    let height: Int
                }
                io.out(try encodeJSON(SHPFramesJSON(frames: writtenPaths, width: sprite.width, height: sprite.height)))
            } else {
                io.out("Exported \(sprite.frameCount) SHP frame(s) (\(sprite.width)x\(sprite.height)) to \(outPath)")
            }
            return
        }

        let pngData: Data?
        if exportSheet {
            pngData = sprite.spriteSheetPNGData(palette768: palette, columns: sheetColumns)
        } else {
            let f = frameIndex ?? 0
            guard f < sprite.frameCount else {
                throw CLIParseError.invalidArguments("Frame index \(f) out of bounds (sprite has \(sprite.frameCount) frame(s), 0..\(sprite.frameCount - 1)).")
            }
            pngData = sprite.pngData(forFrame: f, palette768: palette)
        }

        guard let finalPNG = pngData else {
            throw MixCombineError.unsupportedOperation("Failed to encode PNG output.")
        }
        try ensureParentDirectory(for: outURL)
        try finalPNG.write(to: outURL, options: .atomic)

        if parsed.jsonOutput {
            struct SHPJSON: Codable {
                let outputPath: String
                let width: Int
                let height: Int
                let frameCount: Int
                let mode: String
            }
            io.out(try encodeJSON(SHPJSON(
                outputPath: outURL.path,
                width: sprite.width,
                height: sprite.height,
                frameCount: sprite.frameCount,
                mode: exportSheet ? "sheet" : "frame"
            )))
        } else {
            io.out("Exported SHP \(exportSheet ? "sprite sheet" : "frame \(frameIndex ?? 0)") (\(sprite.width)x\(sprite.height), \(sprite.frameCount) frames) -> \(outPath)")
        }
    }

    // MARK: - Subcommand: export-aud

    private static func runExportAUD(args: [String], io: CLIIO) throws {
        var entryQuery: String?
        var outputPath: String?
        var remaining: [String] = []

        var idx = 0
        while idx < args.count {
            let arg = args[idx]
            if arg == "--entry" {
                entryQuery = try nextValue(args, index: &idx, flag: arg)
            } else if arg == "-o" || arg == "--output" {
                outputPath = try nextValue(args, index: &idx, flag: arg)
            } else {
                remaining.append(arg)
            }
            idx += 1
        }

        let parsed = try parseArchiveQueryArgs(remaining, command: "export-aud")
        guard let outPath = outputPath else {
            throw CLIParseError.invalidArguments("Missing required output path (-o / --output <out.wav>).")
        }

        try importNameDatabases(paths: parsed.namePaths)
        let audData = try loadEntryOrStandalonePayload(parsed: parsed, entryQuery: entryQuery, extensionHint: ".aud")

        guard let wavData = WestwoodAudioDecoder.decodeAUDToWAV(audData) else {
            throw MixCombineError.unsupportedOperation("Input could not be decoded as a Westwood .AUD audio stream.")
        }

        let outURL = URL(fileURLWithPath: outPath)
        try ensureParentDirectory(for: outURL)
        try wavData.write(to: outURL, options: .atomic)

        if parsed.jsonOutput {
            struct AUDJSON: Codable {
                let outputPath: String
                let wavBytes: Int
            }
            io.out(try encodeJSON(AUDJSON(outputPath: outURL.path, wavBytes: wavData.count)))
        } else {
            io.out("Exported decoded WAV (\(wavData.count) bytes) -> \(outPath)")
        }
    }

    // MARK: - Subcommand: export-vqa

    private static func runExportVQA(args: [String], io: CLIIO) throws {
        var entryQuery: String?
        var audioOutPath: String?
        var frameOutPath: String?
        var framesDirPath: String?
        var frameIndex: Int = 0
        var infoOnly = false
        var remaining: [String] = []

        var idx = 0
        while idx < args.count {
            let arg = args[idx]
            switch arg {
            case "--entry":
                entryQuery = try nextValue(args, index: &idx, flag: arg)
            case "--audio-out":
                audioOutPath = try nextValue(args, index: &idx, flag: arg)
            case "-o", "--output":
                frameOutPath = try nextValue(args, index: &idx, flag: arg)
            case "--frames-dir":
                framesDirPath = try nextValue(args, index: &idx, flag: arg)
            case "--frame":
                let val = try nextValue(args, index: &idx, flag: arg)
                guard let n = Int(val), n >= 0 else {
                    throw CLIParseError.invalidArguments("Invalid --frame '\(val)'.")
                }
                frameIndex = n
            case "--info":
                infoOnly = true
            default:
                remaining.append(arg)
            }
            idx += 1
        }

        let parsed = try parseArchiveQueryArgs(remaining, command: "export-vqa")
        try importNameDatabases(paths: parsed.namePaths)
        let vqaData = try loadEntryOrStandalonePayload(parsed: parsed, entryQuery: entryQuery, extensionHint: ".vqa")

        guard let vqa = WestwoodAudioDecoder.WestwoodVQADecoder.decodeVQA(vqaData) else {
            throw MixCombineError.unsupportedOperation("Input is not a valid Westwood .VQA video.")
        }

        if let audioPath = audioOutPath {
            guard let wav = vqa.wavAudioData else {
                throw MixCombineError.unsupportedOperation("VQA stream contains no SND2 audio.")
            }
            let audioURL = URL(fileURLWithPath: audioPath)
            try ensureParentDirectory(for: audioURL)
            try wav.write(to: audioURL, options: .atomic)
        }

        if let fPath = frameOutPath {
            guard frameIndex < vqa.frameOffsets.count else {
                throw CLIParseError.invalidArguments("Frame index \(frameIndex) out of bounds (\(vqa.frameOffsets.count) frames).")
            }
            guard let png = vqa.pngData(forFrame: frameIndex, vqaData: vqaData) else {
                throw MixCombineError.unsupportedOperation("Failed to render VQA frame \(frameIndex).")
            }
            let fURL = URL(fileURLWithPath: fPath)
            try ensureParentDirectory(for: fURL)
            try png.write(to: fURL, options: .atomic)
        }

        if let dirPath = framesDirPath {
            let dirURL = URL(fileURLWithPath: dirPath)
            try FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true)
            for f in 0..<vqa.frameOffsets.count {
                guard let png = vqa.pngData(forFrame: f, vqaData: vqaData) else {
                    throw MixCombineError.unsupportedOperation("Failed to render VQA frame \(f).")
                }
                let fURL = dirURL.appendingPathComponent(String(format: "frame_%04d.png", f + 1))
                try png.write(to: fURL, options: .atomic)
            }
        }

        if parsed.jsonOutput {
            struct VQAJSON: Codable {
                let width: Int
                let height: Int
                let frameCount: Int
                let decodedFrameOffsets: Int
                let fps: Int
                let hasAudio: Bool
                let audioWavBytes: Int?
                let audioOutPath: String?
                let frameOutPath: String?
                let framesDirPath: String?
            }
            io.out(try encodeJSON(VQAJSON(
                width: vqa.width,
                height: vqa.height,
                frameCount: vqa.frameCount,
                decodedFrameOffsets: vqa.frameOffsets.count,
                fps: vqa.fps,
                hasAudio: vqa.hasAudio,
                audioWavBytes: vqa.wavAudioData?.count,
                audioOutPath: audioOutPath,
                frameOutPath: frameOutPath,
                framesDirPath: framesDirPath
            )))
            return
        }

        if infoOnly || (audioOutPath == nil && frameOutPath == nil && framesDirPath == nil) {
            io.out("VQA: \(vqa.width)x\(vqa.height), \(vqa.frameOffsets.count) frame(s), \(vqa.fps) FPS, audio=\(vqa.hasAudio ? "yes (\(vqa.wavAudioData?.count ?? 0) WAV bytes)" : "no")")
        } else {
            io.out("Exported VQA assets (\(vqa.width)x\(vqa.height), \(vqa.frameOffsets.count) frame(s), \(vqa.fps) FPS)")
        }
    }

    // MARK: - Subcommand: crc

    private static func runCRC(args: [String], io: CLIIO) throws {
        var filenames: [String] = []
        var jsonOutput = false
        for arg in args {
            if arg == "-h" || arg == "--help" {
                throw CLIParseError.helpRequested("crc")
            } else if arg == "--json" {
                jsonOutput = true
            } else if arg.hasPrefix("-") {
                throw CLIParseError.invalidArguments("Unknown option '\(arg)' for 'crc'.")
            } else {
                filenames.append(arg)
            }
        }

        guard !filenames.isEmpty else {
            throw CLIParseError.invalidArguments("Provide at least one filename for 'crc'.")
        }

        if jsonOutput {
            struct CRCItem: Codable {
                let filename: String
                let normalized: String
                let crcHex: String
                let crcDecimal: UInt32
            }
            let items = filenames.map { name -> CRCItem in
                let crc = WestwoodMixEngine.westwoodCRC(filename: name)
                return CRCItem(
                    filename: name,
                    normalized: name.uppercased(),
                    crcHex: String(format: "0x%08X", crc),
                    crcDecimal: crc
                )
            }
            io.out(try encodeJSON(items))
            return
        }

        for name in filenames {
            let crc = WestwoodMixEngine.westwoodCRC(filename: name)
            io.out(String(format: "%@ -> 0x%08X", name.uppercased(), crc))
        }
    }

    // MARK: - Subcommand: dict

    private static func runDict(args: [String], io: CLIIO) throws {
        guard let action = args.first?.lowercased() else {
            throw CLIParseError.invalidArguments("Missing action for 'dict'. Expected: lookup, check, stats.")
        }
        if action == "-h" || action == "--help" {
            throw CLIParseError.helpRequested("dict")
        }

        var namePaths: [String] = []
        var queries: [String] = []
        var jsonOutput = false

        var idx = 1
        while idx < args.count {
            let arg = args[idx]
            if arg == "-h" || arg == "--help" {
                throw CLIParseError.helpRequested("dict")
            } else if arg == "--names" {
                namePaths.append(try nextValue(args, index: &idx, flag: arg))
            } else if arg == "--json" {
                jsonOutput = true
            } else if arg.hasPrefix("-") {
                throw CLIParseError.invalidArguments("Unknown option '\(arg)' for 'dict'.")
            } else {
                queries.append(arg)
            }
            idx += 1
        }

        let importedCount = try importNameDatabases(paths: namePaths)

        switch action {
        case "stats":
            if jsonOutput {
                io.out(try encodeJSON(["totalCount": WestwoodNameDatabase.shared.count, "newlyImported": importedCount]))
            } else {
                io.out("Dictionary entries: \(WestwoodNameDatabase.shared.count) (newly imported: \(importedCount))")
            }
        case "lookup":
            guard !queries.isEmpty else {
                throw CLIParseError.invalidArguments("Provide one or more CRC IDs (e.g. 0xB9A5D8F1) for 'dict lookup'.")
            }
            struct LookupJSON: Codable {
                let crcHex: String
                let name: String?
            }
            var items: [LookupJSON] = []
            for q in queries {
                guard let crc = MixCombineEngine.parseHexCRC(q) else {
                    throw CLIParseError.invalidArguments("Invalid hex CRC '\(q)'.")
                }
                items.append(LookupJSON(crcHex: String(format: "0x%08X", crc), name: WestwoodNameDatabase.shared.lookup(crc)))
            }
            if jsonOutput {
                io.out(try encodeJSON(items))
            } else {
                for item in items {
                    io.out("\(item.crcHex) -> \(item.name ?? "<unknown>")")
                }
            }
        case "check":
            guard !queries.isEmpty else {
                throw CLIParseError.invalidArguments("Provide one or more filenames for 'dict check'.")
            }
            struct CheckJSON: Codable {
                let filename: String
                let crcHex: String
                let inDictionary: Bool
                let registeredName: String?
            }
            var items: [CheckJSON] = []
            for q in queries {
                let crc = WestwoodMixEngine.westwoodCRC(filename: q)
                let known = WestwoodNameDatabase.shared.lookup(crc)
                items.append(CheckJSON(
                    filename: q,
                    crcHex: String(format: "0x%08X", crc),
                    inDictionary: known != nil,
                    registeredName: known
                ))
            }
            if jsonOutput {
                io.out(try encodeJSON(items))
            } else {
                for item in items {
                    let status = item.inDictionary ? "KNOWN (\(item.registeredName ?? ""))" : "NOT IN DICTIONARY"
                    io.out("\(item.filename) [\(item.crcHex)] -> \(status)")
                }
            }
        default:
            throw CLIParseError.invalidArguments("Unknown 'dict' action '\(action)'. Expected: lookup, check, stats.")
        }
    }

    // MARK: - Subcommand: verify

    private static func runVerify(args: [String], io: CLIIO) throws {
        var paths: [String] = []
        var namePaths: [String] = []
        var strictOpenRA = true
        var jsonOutput = false

        var idx = 0
        while idx < args.count {
            let arg = args[idx]
            switch arg {
            case "-h", "--help":
                throw CLIParseError.helpRequested("verify")
            case "--names":
                namePaths.append(try nextValue(args, index: &idx, flag: arg))
            case "--strict-openra":
                strictOpenRA = true
            case "--no-strict-openra":
                strictOpenRA = false
            case "--json":
                jsonOutput = true
            default:
                if arg.hasPrefix("-") {
                    throw CLIParseError.invalidArguments("Unknown option '\(arg)' for 'verify'.")
                }
                paths.append(arg)
            }
            idx += 1
        }

        guard !paths.isEmpty else {
            throw CLIParseError.invalidArguments("Provide at least one .MIX file to verify.")
        }

        try importNameDatabases(paths: namePaths)

        var reports: [MixVerificationReport] = []
        var anyInvalid = false
        for path in paths {
            let url = URL(fileURLWithPath: path)
            let data = try Data(contentsOf: url)
            let report = MixCombineEngine.verify(data: data, name: url.lastPathComponent, strictOpenRA: strictOpenRA)
            reports.append(report)
            if !report.openRACompatible {
                anyInvalid = true
            }
        }

        if jsonOutput {
            io.out(try encodeJSON(reports))
        } else {
            for r in reports {
                io.out("\(r.archiveName): OpenRA=\(r.openRACompatible ? "PASS" : "FAIL") • Westwood=\(r.validForWestwood ? "PASS" : "FAIL") • \(r.formatVariant) • \(r.entryCount) entries • \(r.totalSize) bytes")
                for w in r.warnings {
                    io.out("  Warning: \(w)")
                }
                for e in r.errors {
                    io.err("  Error: \(e)")
                }
            }
        }

        if anyInvalid {
            throw MixCombineError.verificationFailed(reports.flatMap { $0.errors })
        }
    }

    // MARK: - Shared Argument & Data Helpers

    private struct ArchiveQueryArgs {
        var inputPaths: [String] = []
        var namePaths: [String] = []
        var duplicateStrategy: DuplicateStrategy = .overwriteLater
        var expandNested: Bool = false
        var expandFilters: [String] = []
        var maxDepth: Int? = nil
        var keepContainers: Bool = false
        var filterQuery: String? = nil
        var includePatterns: [String] = []
        var excludePatterns: [String] = []
        var typeFilter: String? = nil
        var showEntries: Bool = false
        var rawList: Bool = false
        var jsonOutput: Bool = false
    }

    private struct EntryJSON: Codable {
        let crcHex: String
        let crcDecimal: UInt32
        let knownName: String?
        let suggestedFilename: String
        let detectedType: String
        let offset: UInt32
        let size: UInt32
        let sourceArchive: String

        init(_ entry: MixEntry) {
            self.crcHex = entry.hexID
            self.crcDecimal = entry.crcID
            self.knownName = entry.knownName
            self.suggestedFilename = entry.suggestedFilename
            self.detectedType = entry.detectedType
            self.offset = entry.originalOffset
            self.size = entry.size
            self.sourceArchive = entry.sourceArchive
        }
    }

    private static func parseArchiveQueryArgs(
        _ args: [String],
        command: String,
        allowShowEntries: Bool = false,
        allowRawList: Bool = false
    ) throws -> ArchiveQueryArgs {
        var parsed = ArchiveQueryArgs()
        var idx = 0
        while idx < args.count {
            let arg = args[idx]
            switch arg {
            case "-h", "--help":
                throw CLIParseError.helpRequested(command)
            case "-i", "--input":
                parsed.inputPaths.append(try nextValue(args, index: &idx, flag: arg))
            case "--names":
                parsed.namePaths.append(try nextValue(args, index: &idx, flag: arg))
            case "--duplicates", "--duplicate-policy":
                let val = try nextValue(args, index: &idx, flag: arg)
                guard let strat = parseDuplicateStrategy(val) else {
                    throw CLIParseError.invalidArguments("Invalid duplicate policy '\(val)'.")
                }
                parsed.duplicateStrategy = strat
            case "--expand-nested", "--flatten":
                parsed.expandNested = true
            case "--expand":
                parsed.expandFilters.append(try nextValue(args, index: &idx, flag: arg))
            case "--expand-depth":
                let raw = try nextValue(args, index: &idx, flag: arg)
                guard let d = Int(raw), d >= 0 else {
                    throw CLIParseError.invalidArguments("Invalid --expand-depth '\(raw)'.")
                }
                parsed.maxDepth = d
                parsed.expandNested = true
            case "--keep-nested-containers":
                parsed.keepContainers = true
            case "--filter":
                parsed.filterQuery = try nextValue(args, index: &idx, flag: arg)
            case "--include":
                parsed.includePatterns.append(try nextValue(args, index: &idx, flag: arg))
            case "--exclude":
                parsed.excludePatterns.append(try nextValue(args, index: &idx, flag: arg))
            case "--type":
                parsed.typeFilter = try nextValue(args, index: &idx, flag: arg)
            case "--entries" where allowShowEntries:
                parsed.showEntries = true
            case "--raw-list" where allowRawList:
                parsed.rawList = true
            case "--json":
                parsed.jsonOutput = true
            default:
                if arg.hasPrefix("-") {
                    throw CLIParseError.invalidArguments("Unknown option '\(arg)' for '\(command)'.")
                }
                parsed.inputPaths.append(arg)
            }
            idx += 1
        }
        guard !parsed.inputPaths.isEmpty else {
            throw CLIParseError.invalidArguments("Provide at least one input file for '\(command)'.")
        }
        return parsed
    }

    private static func prepareArchivesForQuery(
        _ loaded: [LoadedMixArchive],
        queryArgs: ArchiveQueryArgs
    ) throws -> (archives: [LoadedMixArchive], expandedCount: Int) {
        if queryArgs.expandNested || !queryArgs.expandFilters.isEmpty {
            let expanded = try MixCombineEngine.expandNestedArchives(
                in: loaded,
                maxDepth: queryArgs.maxDepth,
                targetFilters: queryArgs.expandFilters,
                keepContainers: queryArgs.keepContainers
            )
            return (expanded.archives, expanded.expandedCount)
        }
        return (loaded, 0)
    }

    private static func filterEntries(_ entries: [MixEntry], queryArgs: ArchiveQueryArgs) -> [MixEntry] {
        entries.filter { entry in
            guard MixCombineEngine.matchesFilters(
                entry,
                filterQuery: queryArgs.filterQuery,
                includePatterns: queryArgs.includePatterns,
                excludePatterns: queryArgs.excludePatterns
            ) else {
                return false
            }
            if let typeFilter = queryArgs.typeFilter?.trimmingCharacters(in: .whitespacesAndNewlines), !typeFilter.isEmpty {
                return entry.detectedType.localizedCaseInsensitiveContains(typeFilter)
            }
            return true
        }
    }

    private static func loadEntryOrStandalonePayload(
        parsed: ArchiveQueryArgs,
        entryQuery: String?,
        extensionHint: String
    ) throws -> Data {
        if parsed.inputPaths.count == 1 && entryQuery == nil && parsed.inputPaths[0].lowercased().hasSuffix(extensionHint) {
            return try Data(contentsOf: URL(fileURLWithPath: parsed.inputPaths[0]))
        }
        guard let query = entryQuery else {
            throw CLIParseError.invalidArguments("Specify --entry <name-or-crc> when reading from .MIX archive(s), or pass a standalone \(extensionHint.uppercased()) file.")
        }
        let loaded = try loadArchives(paths: parsed.inputPaths)
        let prepared = try prepareArchivesForQuery(loaded, queryArgs: parsed)
        let merged = WestwoodMixEngine.merge(archives: prepared.archives, strategy: parsed.duplicateStrategy, includeRAHeaderFlag: false)
        let entry = try MixCombineEngine.resolveEntry(in: merged.mergedEntries, query: query)
        return entry.payload
    }

    private static func resolvePalette(spec: String, entries: [MixEntry]) throws -> Data {
        let lower = spec.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if lower == "snow" {
            return WestwoodSHPDecoder.builtInSnowPalette
        }
        if lower == "temperate" || lower == "temp" {
            return WestwoodSHPDecoder.builtInTemperatePalette
        }
        let url = URL(fileURLWithPath: spec)
        if FileManager.default.fileExists(atPath: url.path) {
            let data = try Data(contentsOf: url)
            guard data.count >= 768 else {
                throw CLIParseError.invalidArguments("Palette file '\(spec)' must be at least 768 bytes.")
            }
            return Data(data.prefix(768))
        }
        if !entries.isEmpty, let entry = try? MixCombineEngine.resolveEntry(in: entries, query: spec), entry.payload.count >= 768 {
            return Data(entry.payload.prefix(768))
        }
        throw CLIParseError.invalidArguments("Unknown palette '\(spec)'. Use 'snow', 'temperate', a .PAL entry name/CRC, or a 768-byte .PAL file path.")
    }

    @discardableResult
    private static func importNameDatabases(paths: [String]) throws -> Int {
        var added = 0
        for path in paths {
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            added += WestwoodNameDatabase.shared.importDatabaseBlob(data)
        }
        return added
    }

    private static func loadArchives(paths: [String]) throws -> [LoadedMixArchive] {
        var archives: [LoadedMixArchive] = []
        archives.reserveCapacity(paths.count)
        for path in paths {
            archives.append(try WestwoodMixEngine.parse(url: URL(fileURLWithPath: path)))
        }
        return archives
    }

    private static func collectInputFiles(
        files: [String],
        directories: [String],
        recursive: Bool
    ) throws -> [URL] {
        var urls: [URL] = files.map { URL(fileURLWithPath: $0) }
        let fm = FileManager.default
        for dir in directories {
            let dirURL = URL(fileURLWithPath: dir)
            if recursive {
                guard let enumerator = fm.enumerator(
                    at: dirURL,
                    includingPropertiesForKeys: [.isRegularFileKey],
                    options: [.skipsHiddenFiles]
                ) else { continue }
                for case let fileURL as URL in enumerator {
                    let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey])
                    if values.isRegularFile == true {
                        urls.append(fileURL)
                    }
                }
            } else {
                let items = try fm.contentsOfDirectory(
                    at: dirURL,
                    includingPropertiesForKeys: [.isRegularFileKey],
                    options: [.skipsHiddenFiles]
                )
                for fileURL in items {
                    let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey])
                    if values.isRegularFile == true {
                        urls.append(fileURL)
                    }
                }
            }
        }
        return urls.sorted { $0.path < $1.path }
    }

    private static func buildSyntheticArchive(from fileURLs: [URL]) throws -> LoadedMixArchive {
        var entries: [MixEntry] = []
        var names: [String] = []
        var total = 0
        for url in fileURLs {
            let data = try Data(contentsOf: url)
            let name = url.lastPathComponent
            names.append(name)
            entries.append(MixEntry(
                crcID: WestwoodMixEngine.westwoodCRC(filename: name),
                originalOffset: UInt32(total),
                size: UInt32(data.count),
                sourceArchive: name,
                payload: data
            ))
            total += data.count
        }
        WestwoodNameDatabase.shared.registerExact(names: names)
        return LoadedMixArchive(
            fileName: "LOOSE_FILES",
            fileSize: total,
            variant: .redAlertTS,
            wasEncrypted: false,
            isExpandedChild: false,
            sourceCRC: nil,
            entries: entries
        )
    }

    private static func parseDuplicateStrategy(_ raw: String) -> DuplicateStrategy? {
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "overwrite-later", "overwrite", "later", "last":
            return .overwriteLater
        case "keep-first", "first":
            return .keepFirst
        case "keep-all", "all":
            return .keepAll
        default:
            return nil
        }
    }

    private static func nextValue(_ args: [String], index: inout Int, flag: String) throws -> String {
        guard index + 1 < args.count else {
            throw CLIParseError.invalidArguments("Option '\(flag)' requires a value.")
        }
        index += 1
        return args[index]
    }

    private static func ensureParentDirectory(for fileURL: URL) throws {
        let dir = fileURL.deletingLastPathComponent()
        if !dir.path.isEmpty {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    private static func printEntryTable(_ entries: [MixEntry], io: CLIIO) {
        io.out("Name / CRC File ID                  Type             Offset      Size        Source")
        io.out(String(repeating: "-", count: 96))
        for entry in entries {
            let nameCol = entry.displayLabel.padding(toLength: 35, withPad: " ", startingAt: 0)
            let typeCol = entry.detectedType.padding(toLength: 16, withPad: " ", startingAt: 0)
            let offCol = String(format: "0x%06X", entry.originalOffset).padding(toLength: 11, withPad: " ", startingAt: 0)
            let sizeCol = "\(entry.size)".padding(toLength: 11, withPad: " ", startingAt: 0)
            io.out("\(nameCol) \(typeCol) \(offCol) \(sizeCol) \(entry.sourceArchive)")
        }
    }

    private static func hexDump(data: Data) -> String {
        var lines: [String] = []
        let bytes = Array(data)
        var offset = 0
        while offset < bytes.count {
            let chunk = bytes[offset..<min(offset + 16, bytes.count)]
            let hexPart = chunk.map { String(format: "%02X", $0) }.joined(separator: " ")
            let paddedHex = hexPart.padding(toLength: 48, withPad: " ", startingAt: 0)
            let asciiPart = chunk.map { ($0 >= 32 && $0 <= 126) ? String(UnicodeScalar($0)) : "." }.joined()
            lines.append(String(format: "%04X:  %@  |%@|", offset, paddedHex, asciiPart))
            offset += 16
        }
        return lines.joined(separator: "\n")
    }

    private static func formatBytes(_ count: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(count), countStyle: .file)
    }

    private static func encodeJSON<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(value)
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - Help Text

    private static let globalHelpText = """
    CCMixStudio \(version) — Westwood .MIX Archive CLI & Studio

    USAGE:
      CCMixStudio <command> [options] [arguments]
      CCMixStudio [--gui [archive.mix ...]]

    COMMANDS:
      combine (merge)   Combine multiple .MIX archives (and optional loose files) into a single OpenRA-compatible .MIX
      pack              Pack loose files / directories into a .MIX archive
      inspect (info)    Inspect .MIX archive metadata and merge summary
      list (ls)         List and filter entries across .MIX archives
      extract           Extract single or batch entries from .MIX archives
      cat (preview)     Print text, palette, hex dump, or raw bytes of an entry
      export-shp        Decode a .SHP sprite to PNG frame(s) or a sprite sheet
      export-aud        Decode a Westwood .AUD audio stream to .WAV
      export-vqa        Inspect or export audio/frames from a .VQA video
      crc               Calculate Westwood CRC file IDs for filenames
      dict              Lookup, check, or import filename dictionaries
      verify            Validate .MIX archives for Westwood & OpenRA compatibility
      gui               Launch the CCMixStudio desktop GUI (optionally preloading .MIX files)
      help [command]    Show global or command-specific help

    EXAMPLES:
      Combine multiple .MIX archives into one OpenRA-compatible .MIX (flattening nested .MIX files):
        CCMixStudio combine MAIN.MIX EXPAND.MIX MOD.MIX -o COMBINED.MIX --expand-nested

      Combine classic Tiberian Dawn archives with a specific duplicate policy:
        CCMixStudio combine CONQUER.MIX GENERAL.MIX -o TD_ALL.MIX --format openra --duplicates overwrite-later

      Verify an archive for OpenRA client compatibility:
        CCMixStudio verify COMBINED.MIX --strict-openra

    Run 'CCMixStudio help <command>' for detailed options on any command.
    """

    private static func helpText(for topic: String?) -> String {
        switch topic {
        case "combine", "merge":
            return """
            USAGE:
              CCMixStudio combine <archive1.mix> [archive2.mix ...] -o <output.mix> [options]

            OPTIONS:
              -i, --input <path>             Add an input .MIX archive (or pass positionally)
              -o, --output <path>            Output .MIX path (required unless --dry-run)
                  --add-file <path>          Include a loose asset file in the combined archive
                  --add-dir <dir>            Include files from a directory (-r/--recursive for subdirs)
              -r, --recursive                Recurse into --add-dir directories
                  --duplicates <policy>      overwrite-later (default), keep-first, keep-all
                  --format <mode>            openra (default), auto, ra, classic
                  --ra-header                Force 4-byte 0x00000000 RA/TS/RA2 flag header
                  --no-ra-header             Force classic 6-byte Tiberian Dawn header
                  --expand-nested            Recursively expand nested .MIX archives (alias: --flatten)
                  --expand <name-or-crc>     Expand only matching nested .MIX entry (repeatable)
                  --expand-depth <n>         Maximum nested expansion recursion depth
                  --keep-nested-containers   Keep original nested .MIX entries alongside expanded files
                  --filter <query>           Filter entries by name, 0xCRC, type, or source
                  --include <pattern>        Keep entries matching glob/substring/0xCRC (repeatable)
                  --exclude <pattern>        Drop entries matching glob/substring/0xCRC (repeatable)
                  --names <path>             Import XCC database.dat or .txt/.ini filename list (repeatable)
                  --local-db <policy>        merge (default), keep, strip, generate
                  --verify / --no-verify     Verify output archive after build (default: --verify)
                  --dry-run                  Simulate merge and verification without writing output
                  --json                     Output machine-readable JSON
              -q, --quiet                    Suppress status output
            """
        case "pack":
            return """
            USAGE:
              CCMixStudio pack <file-or-dir ...> -o <output.mix> [options]

            OPTIONS:
              -o, --output <path>            Output .MIX file path (required unless --dry-run)
              -r, --recursive                Walk directories recursively
                  --format <mode>            openra (default), auto, ra, classic
                  --duplicates <policy>      overwrite-later (default), keep-first, keep-all
                  --ra-header / --no-ra-header
                  --local-db <policy>        generate (default), merge, keep, strip
                  --names <path>             Import additional filename lists
                  --verify / --no-verify     Verify output archive (default: --verify)
                  --dry-run                  Simulate without writing output
                  --json                     Output machine-readable JSON
            """
        case "inspect", "info":
            return """
            USAGE:
              CCMixStudio inspect <archive.mix ...> [options]

            OPTIONS:
                  --entries                  Also print the merged entry table
                  --expand-nested            Recursively expand nested .MIX archives
                  --expand <name-or-crc>     Expand specific nested .MIX entry
                  --duplicates <policy>      overwrite-later, keep-first, keep-all
                  --filter <query>           Filter entries
                  --names <path>             Import XCC database.dat or filename list
                  --json                     Output JSON
            """
        case "list", "ls":
            return """
            USAGE:
              CCMixStudio list <archive.mix ...> [options]

            OPTIONS:
                  --expand-nested            Recursively expand nested .MIX archives
                  --expand <name-or-crc>     Expand specific nested .MIX entry
                  --duplicates <policy>      overwrite-later, keep-first, keep-all
                  --raw-list                 List raw entries per archive without deduplication
                  --filter <query>           Filter by name, 0xCRC, type, or source
                  --include <pattern>        Include matching entries (repeatable)
                  --exclude <pattern>        Exclude matching entries (repeatable)
                  --type <type>              Filter by detected type substring (e.g. SHP, AUD)
                  --names <path>             Import filename dictionary
                  --json                     Output JSON
            """
        case "extract":
            return """
            USAGE:
              CCMixStudio extract <archive.mix ...> -o <dir-or-file> [options]

            OPTIONS:
              -o, --output <path>            Destination directory (or file path for single --entry)
                  --entry <name-or-crc>      Extract specific entry (repeatable)
                  --expand-nested            Recursively expand nested .MIX archives
                  --duplicates <policy>      overwrite-later, keep-first, keep-all
                  --filter / --include / --exclude
                  --names <path>             Import filename dictionary
                  --json                     Output JSON
            """
        case "cat", "preview":
            return """
            USAGE:
              CCMixStudio cat <archive.mix ...> --entry <name-or-crc> [--hex | --raw] [--max-bytes N]
            """
        case "export-shp":
            return """
            USAGE:
              CCMixStudio export-shp <archive.mix ... --entry <name-or-crc> | sprite.shp> -o <out.png | dir> [options]

            OPTIONS:
                  --palette <spec>           snow (default), temperate, archive .PAL name/CRC, or .PAL file path
                  --frame <index>            0-based frame index to export (default: 0)
                  --sheet                    Stitch all frames into a single transparent PNG sprite sheet
                  --columns <n>              Column count for sprite sheet grid
                  --all-frames               Export every frame as individual PNGs into output directory
                  --expand-nested            Expand nested .MIX archives when reading from .MIX
                  --names <path>             Import filename dictionary
                  --json                     Output JSON
            """
        case "export-aud":
            return """
            USAGE:
              CCMixStudio export-aud <archive.mix ... --entry <name-or-crc> | sound.aud> -o <out.wav> [options]
            """
        case "export-vqa":
            return """
            USAGE:
              CCMixStudio export-vqa <archive.mix ... --entry <name-or-crc> | video.vqa> [options]

            OPTIONS:
                  --info                     Print VQA metadata (default if no export flag given)
                  --audio-out <out.wav>      Export decoded SND2 audio stream to WAV
              -o, --output <out.png>         Export single rendered frame (select with --frame <0-based>)
                  --frame <index>            0-based frame index (default: 0)
                  --frames-dir <dir>         Export all rendered frames as PNGs to directory
                  --json                     Output JSON
            """
        case "crc":
            return """
            USAGE:
              CCMixStudio crc <filename...> [--json]
            """
        case "dict":
            return """
            USAGE:
              CCMixStudio dict <stats | lookup <0xCRC...> | check <filename...>> [--names <path>] [--json]
            """
        case "verify":
            return """
            USAGE:
              CCMixStudio verify <archive.mix ...> [--strict-openra | --no-strict-openra] [--names <path>] [--json]
            """
        default:
            return globalHelpText
        }
    }
}
