import Foundation

enum MixOutputFormat: String, CaseIterable, Sendable {
    case openra
    case auto
    case ra
    case classic

    init?(cliValue: String) {
        switch cliValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "openra": self = .openra
        case "auto": self = .auto
        case "ra", "extended", "ts", "ra2": self = .ra
        case "classic", "td": self = .classic
        default: return nil
        }
    }
}

enum LocalMixDBPolicy: String, CaseIterable, Sendable {
    case merge
    case keep
    case strip
    case generate

    init?(cliValue: String) {
        switch cliValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "merge": self = .merge
        case "keep": self = .keep
        case "strip", "none", "remove": self = .strip
        case "generate", "gen": self = .generate
        default: return nil
        }
    }
}

struct MixCombineOptions: Sendable {
    var duplicateStrategy: DuplicateStrategy = .overwriteLater
    var format: MixOutputFormat = .openra
    var includeRAHeaderFlagOverride: Bool? = nil
    var expandNestedMix: Bool = false
    var maxNestedDepth: Int? = nil
    var nestedFilters: [String] = []
    var keepNestedContainers: Bool = false
    var filterQuery: String? = nil
    var includePatterns: [String] = []
    var excludePatterns: [String] = []
    var localDBPolicy: LocalMixDBPolicy = .merge
    var verifyOutput: Bool = true
}

struct MixVerificationReport: Codable, Sendable {
    let archiveName: String
    let validForWestwood: Bool
    let openRACompatible: Bool
    let formatVariant: String
    let isEncrypted: Bool
    let entryCount: Int
    let bodySize: Int
    let totalSize: Int
    let isSortedByCRC: Bool
    let duplicateCRCCount: Int
    let nestedMixCount: Int
    let hasLocalMixDatabase: Bool
    let errors: [String]
    let warnings: [String]
}

struct MixCombineResult: Sendable {
    let data: Data
    let mergedEntries: [MixEntry]
    let duplicatesResolved: Int
    let expandedNestedCount: Int
    let usedRAHeaderFlag: Bool
    let localDBAction: String
    let warnings: [String]
    let verification: MixVerificationReport?
}

enum MixCombineError: LocalizedError {
    case noArchivesProvided
    case duplicatePolicyIncompatibleWithOpenRA
    case emptyClassicArchiveNotSupported
    case tooManyEntries(Int)
    case bodySizeExceedsLimit(UInt64)
    case nestedExpansionFailed(name: String, reason: String)
    case verificationFailed([String])
    case entryNotFound(String)
    case ambiguousEntry(String, [String])
    case unsupportedOperation(String)

    var errorDescription: String? {
        switch self {
        case .noArchivesProvided:
            return "No input .MIX archives or files were provided."
        case .duplicatePolicyIncompatibleWithOpenRA:
            return "OpenRA-compatible .MIX archives cannot use 'keep-all' duplicate policy because duplicate CRC IDs conflict with OpenRA's package index. Use 'overwrite-later' or 'keep-first' (or pass --format ra / --format classic)."
        case .emptyClassicArchiveNotSupported:
            return "Classic (Tiberian Dawn) .MIX format cannot encode 0 entries because a leading 0x0000 count is interpreted as an extended Red Alert header. Use --format openra or --format ra."
        case .tooManyEntries(let count):
            return "Combined archive has \(count) entries, exceeding the .MIX format maximum of 65,535 entries."
        case .bodySizeExceedsLimit(let size):
            return "Combined payload size (\(size) bytes) exceeds the 4 GiB .MIX format limit."
        case .nestedExpansionFailed(let name, let reason):
            return "Failed to expand nested .MIX '\(name)': \(reason)"
        case .verificationFailed(let errors):
            return "Archive verification failed: \(errors.joined(separator: "; "))"
        case .entryNotFound(let query):
            return "Entry '\(query)' was not found."
        case .ambiguousEntry(let query, let matches):
            return "Entry '\(query)' matched multiple entries: \(matches.joined(separator: ", ")). Specify an exact 0xCRC ID or full filename."
        case .unsupportedOperation(let msg):
            return msg
        }
    }
}

struct MixCombineEngine {
    static func combine(
        archives inputArchives: [LoadedMixArchive],
        options: MixCombineOptions = MixCombineOptions()
    ) throws -> MixCombineResult {
        guard !inputArchives.isEmpty else {
            throw MixCombineError.noArchivesProvided
        }

        if options.format == .openra && options.duplicateStrategy == .keepAll {
            throw MixCombineError.duplicatePolicyIncompatibleWithOpenRA
        }

        var workingArchives = inputArchives
        var expandedCount = 0
        var warnings: [String] = []

        if options.expandNestedMix || !options.nestedFilters.isEmpty {
            let expanded = try expandNestedArchives(
                in: workingArchives,
                maxDepth: options.maxNestedDepth,
                targetFilters: options.nestedFilters,
                keepContainers: options.keepNestedContainers
            )
            workingArchives = expanded.archives
            expandedCount = expanded.expandedCount
            warnings.append(contentsOf: expanded.warnings)
        }

        let anyInputHadLocalDB = workingArchives.contains { archive in
            archive.entries.contains { $0.crcID == WestwoodNameDatabase.localMixDBCRC }
        }

        // Filter entries if search/include/exclude criteria were supplied.
        let filteredArchives = workingArchives.map { archive in
            let keptEntries = archive.entries.filter { entry in
                matchesFilters(
                    entry,
                    filterQuery: options.filterQuery,
                    includePatterns: options.includePatterns,
                    excludePatterns: options.excludePatterns
                )
            }
            return LoadedMixArchive(
                fileName: archive.fileName,
                fileSize: archive.fileSize,
                variant: archive.variant,
                wasEncrypted: archive.wasEncrypted,
                isExpandedChild: archive.isExpandedChild,
                sourceCRC: archive.sourceCRC,
                entries: keptEntries
            )
        }

        var combined: [MixEntry] = []
        var seenIndexByID: [UInt32: Int] = [:]
        var duplicates = 0

        for archive in filteredArchives {
            for entry in archive.entries {
                if options.localDBPolicy == .strip && entry.crcID == WestwoodNameDatabase.localMixDBCRC {
                    continue
                }
                if let existingIdx = seenIndexByID[entry.crcID] {
                    duplicates += 1
                    switch options.duplicateStrategy {
                    case .overwriteLater:
                        combined[existingIdx] = entry
                    case .keepFirst:
                        continue
                    case .keepAll:
                        combined.append(entry)
                    }
                } else {
                    seenIndexByID[entry.crcID] = combined.count
                    combined.append(entry)
                }
            }
        }

        // Handle local mix database.dat synthesis or merging.
        var localDBAction = "none"
        let shouldRebuildLocalDB: Bool = {
            switch options.localDBPolicy {
            case .generate:
                return true
            case .merge:
                return anyInputHadLocalDB
            case .keep, .strip:
                return false
            }
        }()

        if options.localDBPolicy == .strip {
            localDBAction = "stripped"
        } else if shouldRebuildLocalDB {
            let nonDBEntries = combined.filter { $0.crcID != WestwoodNameDatabase.localMixDBCRC }
            var resolvedNames: [String] = []
            resolvedNames.reserveCapacity(nonDBEntries.count + 1)
            var seenNames = Set<String>()
            for entry in nonDBEntries {
                if let known = entry.knownName, seenNames.insert(known.uppercased()).inserted {
                    resolvedNames.append(known)
                }
            }
            if !resolvedNames.isEmpty {
                let lmdName = "local mix database.dat"
                if seenNames.insert(lmdName.uppercased()).inserted {
                    resolvedNames.append(lmdName)
                }
                let lmdData = buildLocalMixDatabase(filenames: resolvedNames)
                let lmdEntry = MixEntry(
                    crcID: WestwoodNameDatabase.localMixDBCRC,
                    originalOffset: 0,
                    size: UInt32(lmdData.count),
                    sourceArchive: "CCMixStudio (Merged LMD)",
                    payload: lmdData
                )
                combined = nonDBEntries
                combined.append(lmdEntry)
                localDBAction = "merged (\(resolvedNames.count) names)"
            } else {
                combined = nonDBEntries
                localDBAction = "skipped (no known names)"
            }
        } else if combined.contains(where: { $0.crcID == WestwoodNameDatabase.localMixDBCRC }) {
            localDBAction = "kept"
        }

        combined.sort { $0.crcID < $1.crcID }

        let useRAHeaderFlag = resolveUseRAHeaderFlag(
            archives: workingArchives,
            entryCount: combined.count,
            options: options
        )

        if !useRAHeaderFlag && combined.isEmpty {
            throw MixCombineError.emptyClassicArchiveNotSupported
        }
        if combined.count > Int(UInt16.max) {
            throw MixCombineError.tooManyEntries(combined.count)
        }
        let totalBodySize64: UInt64 = combined.reduce(0) { $0 + UInt64($1.payload.count) }
        if totalBodySize64 > UInt64(UInt32.max) {
            throw MixCombineError.bodySizeExceedsLimit(totalBodySize64)
        }

        var output = Data()
        if useRAHeaderFlag {
            appendUInt32LE(&output, 0)
        }
        appendUInt16LE(&output, UInt16(combined.count))
        appendUInt32LE(&output, UInt32(totalBodySize64))

        var runningOffset: UInt32 = 0
        var rebuiltEntries: [MixEntry] = []
        rebuiltEntries.reserveCapacity(combined.count)

        for entry in combined {
            let size = UInt32(entry.payload.count)
            appendUInt32LE(&output, entry.crcID)
            appendUInt32LE(&output, runningOffset)
            appendUInt32LE(&output, size)

            rebuiltEntries.append(MixEntry(
                crcID: entry.crcID,
                originalOffset: runningOffset,
                size: size,
                sourceArchive: entry.sourceArchive,
                payload: entry.payload
            ))
            runningOffset += size
        }

        for entry in combined {
            output.append(entry.payload)
        }

        let remainingNested = rebuiltEntries.filter { $0.isNestedMix }
        if !remainingNested.isEmpty && options.format == .openra {
            warnings.append(
                "\(remainingNested.count) unexpanded nested .MIX archive(s) remain inside the output; OpenRA does not automatically flatten nested .MIX entries unless expanded with --expand-nested."
            )
        }

        var verification: MixVerificationReport?
        if options.verifyOutput {
            let report = verify(
                data: output,
                name: "COMBINED.MIX",
                strictOpenRA: options.format == .openra
            )
            verification = report
            if !report.errors.isEmpty {
                throw MixCombineError.verificationFailed(report.errors)
            }
        }

        return MixCombineResult(
            data: output,
            mergedEntries: rebuiltEntries,
            duplicatesResolved: duplicates,
            expandedNestedCount: expandedCount,
            usedRAHeaderFlag: useRAHeaderFlag,
            localDBAction: localDBAction,
            warnings: warnings,
            verification: verification
        )
    }

    static func expandNestedArchives(
        in archives: [LoadedMixArchive],
        maxDepth: Int? = nil,
        targetFilters: [String] = [],
        keepContainers: Bool = false
    ) throws -> (archives: [LoadedMixArchive], expandedCount: Int, warnings: [String]) {
        var resultArchives: [LoadedMixArchive] = []
        var expandedCount = 0
        var warnings: [String] = []
        var visitedFingerprints = Set<String>()

        func fingerprint(_ data: Data) -> String {
            let prefixHex = data.prefix(32).map { String(format: "%02X", $0) }.joined()
            return "\(data.count):\(prefixHex)"
        }

        func process(archive: LoadedMixArchive, depth: Int) throws {
            var remainingEntries: [MixEntry] = []
            var childArchives: [LoadedMixArchive] = []

            let canExpandHere = maxDepth.map { depth < $0 } ?? true

            for entry in archive.entries {
                guard canExpandHere && entry.isNestedMix else {
                    remainingEntries.append(entry)
                    continue
                }

                let matchesTarget = targetFilters.isEmpty || targetFilters.contains { filter in
                    matchesEntryIdentifier(entry, query: filter)
                }

                guard matchesTarget else {
                    remainingEntries.append(entry)
                    continue
                }

                let label = entry.knownName ?? "\(entry.hexID).MIX"
                let fp = fingerprint(entry.payload)
                if visitedFingerprints.contains(fp) {
                    warnings.append("Skipped duplicate/cyclic nested archive '\(label)'.")
                    if keepContainers {
                        remainingEntries.append(entry)
                    }
                    continue
                }

                do {
                    let parsed = try WestwoodMixEngine.parse(
                        data: entry.payload,
                        name: label,
                        isExpandedChild: true,
                        sourceCRC: entry.crcID
                    )
                    visitedFingerprints.insert(fp)
                    expandedCount += 1
                    if keepContainers {
                        remainingEntries.append(entry)
                    }
                    childArchives.append(parsed)
                } catch {
                    let explicitlyNamedMix = entry.knownName?.uppercased().hasSuffix(".MIX") == true || !targetFilters.isEmpty
                    if explicitlyNamedMix {
                        throw MixCombineError.nestedExpansionFailed(name: label, reason: error.localizedDescription)
                    }
                    warnings.append("Ignored non-archive entry \(entry.displayLabel) that resembled a .MIX header: \(error.localizedDescription)")
                    remainingEntries.append(entry)
                }
            }

            let updatedArchive = LoadedMixArchive(
                fileName: archive.fileName,
                fileSize: archive.fileSize,
                variant: archive.variant,
                wasEncrypted: archive.wasEncrypted,
                isExpandedChild: archive.isExpandedChild,
                sourceCRC: archive.sourceCRC,
                entries: remainingEntries
            )
            resultArchives.append(updatedArchive)

            for child in childArchives {
                try process(archive: child, depth: depth + 1)
            }
        }

        for archive in archives {
            try process(archive: archive, depth: 0)
        }

        return (resultArchives, expandedCount, warnings)
    }

    static func packFiles(
        fileURLs: [URL],
        options: MixCombineOptions = MixCombineOptions()
    ) throws -> MixCombineResult {
        guard !fileURLs.isEmpty else {
            throw MixCombineError.noArchivesProvided
        }

        var entries: [MixEntry] = []
        var registeredNames: [String] = []
        var totalSize = 0

        for url in fileURLs {
            let data = try Data(contentsOf: url)
            let name = url.lastPathComponent
            let crc = WestwoodMixEngine.westwoodCRC(filename: name)
            registeredNames.append(name)
            entries.append(MixEntry(
                crcID: crc,
                originalOffset: UInt32(totalSize),
                size: UInt32(data.count),
                sourceArchive: name,
                payload: data
            ))
            totalSize += data.count
        }

        WestwoodNameDatabase.shared.registerExact(names: registeredNames)

        let syntheticArchive = LoadedMixArchive(
            fileName: "PACKED_INPUT",
            fileSize: totalSize,
            variant: options.format == .classic ? .tiberianDawn : .redAlertTS,
            wasEncrypted: false,
            isExpandedChild: false,
            sourceCRC: nil,
            entries: entries
        )

        return try combine(archives: [syntheticArchive], options: options)
    }

    static func buildLocalMixDatabase(filenames: [String], gameID: UInt32 = 1) -> Data {
        let cleaned = filenames
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        var payload = Data()
        for name in cleaned {
            if let encoded = name.data(using: .windowsCP1252) ?? name.data(using: .utf8) {
                payload.append(encoded)
                payload.append(0)
            }
        }

        let totalSize = UInt32(52 + payload.count)
        var data = Data()
        data.reserveCapacity(Int(totalSize))

        // 32-byte XCC signature: "XCC by Olaf van der Spek" (24 bytes) + 8-byte magic
        data.append(contentsOf: "XCC by Olaf van der Spek".utf8)
        data.append(contentsOf: [0x1A, 0x04, 0x17, 0x27, 0x10, 0x19, 0x80, 0x00])
        // 20-byte header fields: size, type (0 = LMD), version (0), game, entry count
        appendUInt32LE(&data, totalSize)
        appendUInt32LE(&data, 0)
        appendUInt32LE(&data, 0)
        appendUInt32LE(&data, gameID)
        appendUInt32LE(&data, UInt32(cleaned.count))
        data.append(payload)
        return data
    }

    static func verify(data: Data, name: String, strictOpenRA: Bool = true) -> MixVerificationReport {
        var errors: [String] = []
        var warnings: [String] = []

        do {
            let parsed = try WestwoodMixEngine.parse(data: data, name: name)
            var isSorted = true
            var seenCRCs = Set<UInt32>()
            var duplicateCRCs = 0
            var previousCRC: UInt32 = 0

            for (idx, entry) in parsed.entries.enumerated() {
                if idx > 0 && entry.crcID < previousCRC {
                    isSorted = false
                }
                previousCRC = entry.crcID
                if !seenCRCs.insert(entry.crcID).inserted {
                    duplicateCRCs += 1
                }
            }

            if !isSorted {
                errors.append("Index entries are not sorted in ascending CRC order.")
            }
            if duplicateCRCs > 0 {
                let msg = "Archive contains \(duplicateCRCs) duplicate CRC ID(s)."
                if strictOpenRA {
                    errors.append(msg)
                } else {
                    warnings.append(msg)
                }
            }

            if parsed.wasEncrypted {
                warnings.append("Archive header is RSA/Blowfish encrypted (valid for retail RA/TS, though unencrypted is recommended for custom OpenRA packs).")
            }

            let nestedCount = parsed.entries.filter { $0.isNestedMix }.count
            if nestedCount > 0 {
                warnings.append("Archive contains \(nestedCount) nested .MIX sub-archive(s) that were not flattened.")
            }

            let hasLMD = parsed.entries.contains { $0.crcID == WestwoodNameDatabase.localMixDBCRC }
            let bodySize = parsed.entries.reduce(0) { $0 + Int($1.size) }

            return MixVerificationReport(
                archiveName: name,
                validForWestwood: isSorted,
                openRACompatible: errors.isEmpty,
                formatVariant: parsed.variant.rawValue,
                isEncrypted: parsed.wasEncrypted,
                entryCount: parsed.entries.count,
                bodySize: bodySize,
                totalSize: data.count,
                isSortedByCRC: isSorted,
                duplicateCRCCount: duplicateCRCs,
                nestedMixCount: nestedCount,
                hasLocalMixDatabase: hasLMD,
                errors: errors,
                warnings: warnings
            )
        } catch {
            errors.append(error.localizedDescription)
            return MixVerificationReport(
                archiveName: name,
                validForWestwood: false,
                openRACompatible: false,
                formatVariant: "Invalid",
                isEncrypted: false,
                entryCount: 0,
                bodySize: 0,
                totalSize: data.count,
                isSortedByCRC: false,
                duplicateCRCCount: 0,
                nestedMixCount: 0,
                hasLocalMixDatabase: false,
                errors: errors,
                warnings: warnings
            )
        }
    }

    static func resolveEntry(in entries: [MixEntry], query: String) throws -> MixEntry {
        let exactMatches = entries.filter { matchesEntryIdentifier($0, query: query) }
        if exactMatches.count == 1 {
            return exactMatches[0]
        }
        if exactMatches.count > 1 {
            throw MixCombineError.ambiguousEntry(query, exactMatches.map { "\($0.displayLabel) [\($0.sourceArchive)]" })
        }

        let fuzzyMatches = entries.filter { matchesPattern($0, pattern: query) }
        if fuzzyMatches.count == 1 {
            return fuzzyMatches[0]
        }
        if fuzzyMatches.count > 1 {
            throw MixCombineError.ambiguousEntry(query, fuzzyMatches.map { "\($0.displayLabel) [\($0.sourceArchive)]" })
        }

        throw MixCombineError.entryNotFound(query)
    }

    static func matchesEntryIdentifier(_ entry: MixEntry, query: String) -> Bool {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        if let parsedCRC = parseHexCRC(trimmed), parsedCRC == entry.crcID {
            return true
        }
        if let known = entry.knownName, known.caseInsensitiveCompare(trimmed) == .orderedSame {
            return true
        }
        if entry.suggestedFilename.caseInsensitiveCompare(trimmed) == .orderedSame {
            return true
        }
        if entry.displayLabel.caseInsensitiveCompare(trimmed) == .orderedSame {
            return true
        }
        return false
    }

    static func matchesFilters(
        _ entry: MixEntry,
        filterQuery: String?,
        includePatterns: [String],
        excludePatterns: [String]
    ) -> Bool {
        if let q = filterQuery?.trimmingCharacters(in: .whitespacesAndNewlines), !q.isEmpty {
            let upper = q.uppercased()
            let matchesQuery =
                entry.displayLabel.uppercased().contains(upper) ||
                entry.sourceArchive.uppercased().contains(upper) ||
                entry.detectedType.uppercased().contains(upper) ||
                entry.suggestedFilename.uppercased().contains(upper)
            if !matchesQuery { return false }
        }

        if !includePatterns.isEmpty {
            let matchedAny = includePatterns.contains { matchesPattern(entry, pattern: $0) }
            if !matchedAny { return false }
        }

        if excludePatterns.contains(where: { matchesPattern(entry, pattern: $0) }) {
            return false
        }

        return true
    }

    static func matchesPattern(_ entry: MixEntry, pattern: String) -> Bool {
        let trimmed = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        if let crc = parseHexCRC(trimmed), crc == entry.crcID {
            return true
        }

        if trimmed.contains("*") || trimmed.contains("?") {
            let candidates = [entry.knownName, entry.suggestedFilename, entry.hexID, entry.sourceArchive].compactMap { $0 }
            return candidates.contains { globMatch(pattern: trimmed, text: $0) }
        }

        let upper = trimmed.uppercased()
        return entry.displayLabel.uppercased().contains(upper) ||
            entry.suggestedFilename.uppercased().contains(upper) ||
            entry.sourceArchive.uppercased().contains(upper) ||
            entry.detectedType.uppercased().contains(upper)
    }

    static func parseHexCRC(_ text: String) -> UInt32? {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if s.hasPrefix("0X") {
            s = String(s.dropFirst(2))
        } else if s.count != 8 {
            return nil
        }
        guard !s.isEmpty, s.count <= 8 else { return nil }
        return UInt32(s, radix: 16)
    }

    private static func globMatch(pattern: String, text: String) -> Bool {
        let p = Array(pattern.uppercased())
        let t = Array(text.uppercased())
        var pi = 0
        var ti = 0
        var starIdx: Int?
        var matchIdx = 0

        while ti < t.count {
            if pi < p.count && (p[pi] == "?" || p[pi] == t[ti]) {
                pi += 1
                ti += 1
            } else if pi < p.count && p[pi] == "*" {
                starIdx = pi
                matchIdx = ti
                pi += 1
            } else if let star = starIdx {
                pi = star + 1
                matchIdx += 1
                ti = matchIdx
            } else {
                return false
            }
        }
        while pi < p.count && p[pi] == "*" {
            pi += 1
        }
        return pi == p.count
    }

    private static func resolveUseRAHeaderFlag(
        archives: [LoadedMixArchive],
        entryCount: Int,
        options: MixCombineOptions
    ) -> Bool {
        if let override = options.includeRAHeaderFlagOverride {
            return override
        }
        switch options.format {
        case .openra, .ra:
            return true
        case .classic:
            return false
        case .auto:
            if entryCount == 0 { return true }
            return archives.contains { $0.variant == .redAlertTS || $0.variant == .redAlertTSEncrypted }
        }
    }

    private static func appendUInt16LE(_ data: inout Data, _ val: UInt16) {
        data.append(UInt8(val & 0xFF))
        data.append(UInt8((val >> 8) & 0xFF))
    }

    private static func appendUInt32LE(_ data: inout Data, _ val: UInt32) {
        data.append(UInt8(val & 0xFF))
        data.append(UInt8((val >> 8) & 0xFF))
        data.append(UInt8((val >> 16) & 0xFF))
        data.append(UInt8((val >> 24) & 0xFF))
    }
}
