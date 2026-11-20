import SwiftUI
import UniformTypeIdentifiers
import AVFoundation
import Combine

struct ContentView: View {
    @State private var archives: [LoadedMixArchive] = []
    @State private var duplicateStrategy: DuplicateStrategy = .overwriteLater
    @State private var useRAHeaderFlag: Bool = false
    @State private var searchQuery: String = ""
    @State private var crcLookupInput: String = "RULES.INI"
    @State private var selectedEntryID: MixEntry.ID?
    @State private var errorMessage: String?
    @State private var statusBanner: String?
    @State private var isDropTargeted: Bool = false
    @State private var isLoading: Bool = false
    @State private var audioPlayer: AVAudioPlayer?
    @State private var isPlayingAudio: Bool = false
    @State private var dictionaryRevision: Int = 0

    var previewMerge: (data: Data, mergedEntries: [MixEntry], duplicatesResolved: Int) {
        _ = dictionaryRevision
        return WestwoodMixEngine.merge(
            archives: archives,
            strategy: duplicateStrategy,
            includeRAHeaderFlag: useRAHeaderFlag
        )
    }

    var filteredEntries: [MixEntry] {
        let all = previewMerge.mergedEntries
        let trimmed = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if trimmed.isEmpty { return all }
        return all.filter {
            $0.displayLabel.uppercased().contains(trimmed) ||
            $0.sourceArchive.uppercased().contains(trimmed) ||
            $0.detectedType.uppercased().contains(trimmed)
        }
    }

    var selectedEntry: MixEntry? {
        guard let id = selectedEntryID else { return nil }
        return previewMerge.mergedEntries.first { $0.id == id }
    }

    var availablePalettes: [(name: String, data: Data)] {
        var pals: [(String, Data)] = [
            ("Built-in Red Alert Snow", WestwoodSHPDecoder.builtInSnowPalette),
            ("Built-in Red Alert Temperate", WestwoodSHPDecoder.builtInTemperatePalette)
        ]
        for entry in previewMerge.mergedEntries {
            let isPalByName = entry.knownName?.uppercased().hasSuffix(".PAL") == true
            if entry.payload.count == 768 || (isPalByName && entry.payload.count >= 768) {
                pals.append((entry.knownName ?? entry.hexID, entry.payload.prefix(768)))
            }
        }
        return pals
    }

    var expandedChildCount: Int {
        archives.filter { $0.isExpandedChild }.count
    }

    var computedCRC: String {
        let trimmed = crcLookupInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "0x00000000" }
        return String(format: "0x%08X", WestwoodMixEngine.westwoodCRC(filename: trimmed))
    }

    var body: some View {
        HSplitView {
            // Left Sidebar
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Loaded .MIX Queue")
                        .font(.headline)
                    if isLoading {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Spacer()
                    if expandedChildCount > 0 {
                        Button("Unexpand (\(expandedChildCount))") {
                            unexpandAllNested()
                        }
                        .font(.caption)
                        .controlSize(.small)
                        .help("Remove all expanded nested .MIX archives from the queue")
                    }
                    Button {
                        addMixFiles()
                    } label: {
                        Label("Add", systemImage: "plus")
                    }
                    .keyboardShortcut("o", modifiers: .command)
                }

                if archives.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "archivebox")
                            .font(.system(size: 32))
                            .foregroundColor(.secondary)
                        Text("Drop official or modded .MIX files here")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity, minHeight: 150)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6]))
                            .foregroundColor(isDropTargeted ? .accentColor : .gray.opacity(0.4))
                    )
                } else {
                    List {
                        ForEach(archives) { arch in
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 6) {
                                    if arch.isExpandedChild {
                                        Image(systemName: "arrow.turn.down.right")
                                            .font(.caption2)
                                            .foregroundColor(.accentColor)
                                    }
                                    Text(arch.fileName)
                                        .font(.system(.subheadline, design: .monospaced))
                                        .fontWeight(.bold)
                                    if arch.wasEncrypted {
                                        Image(systemName: "lock.open.fill")
                                            .font(.caption2)
                                            .foregroundColor(.green)
                                            .help("Decrypted RSA/Blowfish Header")
                                    }
                                    Spacer()
                                    Button {
                                        archives.removeAll { $0.id == arch.id }
                                    } label: {
                                        Image(systemName: arch.isExpandedChild ? "arrow.up.left.and.arrow.down.right" : "xmark.circle.fill")
                                            .foregroundColor(arch.isExpandedChild ? .accentColor : .secondary)
                                    }
                                    .buttonStyle(.plain)
                                    .help(arch.isExpandedChild ? "Unexpand Nested .MIX" : "Remove Archive")
                                }
                                Text("\(arch.entries.count) files • \(ByteCountFormatter.string(fromByteCount: Int64(arch.fileSize), countStyle: .file))")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                Text(arch.isExpandedChild ? "Expanded Nested Archive" : arch.variant.rawValue)
                                    .font(.caption2)
                                    .foregroundColor(arch.isExpandedChild ? .accentColor : (arch.wasEncrypted ? .green : .secondary))
                            }
                            .padding(.vertical, 2)
                        }
                        .onMove { from, to in
                            archives.move(fromOffsets: from, toOffset: to)
                        }
                    }
                    .frame(minHeight: 140)
                }

                GroupBox("Merge Options") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Duplicate CRC ID Policy:")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Picker("Duplicate Policy", selection: $duplicateStrategy) {
                            ForEach(DuplicateStrategy.allCases) { strat in
                                Text(strat.rawValue).tag(strat)
                            }
                        }
                        .labelsHidden()

                        Toggle("Include RA/TS/RA2 4-Byte Flag Header", isOn: $useRAHeaderFlag)
                            .font(.caption)
                    }
                    .padding(4)
                }

                GroupBox("Global Filename Dictionary (\(WestwoodNameDatabase.shared.count))") {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 6) {
                            TextField("e.g. RULES.INI", text: $crcLookupInput)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(.caption, design: .monospaced))
                            Button("Import Names...") {
                                importFilenameDatabase()
                            }
                            .font(.caption)
                            .controlSize(.small)
                            .help("Load global mix database.dat or any .txt/.ini filename list")
                        }
                        HStack {
                            Text("CRC ID:")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Spacer()
                            Text(computedCRC)
                                .font(.system(.caption, design: .monospaced))
                                .fontWeight(.bold)
                                .textSelection(.enabled)
                        }
                    }
                    .padding(4)
                }

                Spacer()

                VStack(spacing: 8) {
                    HStack {
                        Button("Clear All") {
                            stopAudio()
                            archives.removeAll()
                            selectedEntryID = nil
                            errorMessage = nil
                            statusBanner = nil
                        }
                        .disabled(archives.isEmpty)

                        Spacer()

                        Button {
                            batchExtractAll()
                        } label: {
                            Label("Extract All...", systemImage: "folder.badge.plus")
                        }
                        .disabled(archives.isEmpty)
                    }

                    Button {
                        exportMergedMix()
                    } label: {
                        Label("Combine & Export .MIX", systemImage: "square.and.arrow.down")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(archives.isEmpty)
                }
            }
            .padding(14)
            .frame(minWidth: 305, maxWidth: 345)

            // Right Pane: Table + Bottom Inspector Preview
            VSplitView {
                VStack(spacing: 0) {
                    HStack(spacing: 10) {
                        TextField("Filter by Name, CRC (0x...), Type, or Source...", text: $searchQuery)
                            .textFieldStyle(.roundedBorder)

                        if let entry = selectedEntry, entry.isNestedMix {
                            if isNestedArchiveExpanded(entry) {
                                Button {
                                    unexpandNestedMix(entry)
                                } label: {
                                    Label("Unexpand .MIX", systemImage: "arrow.up.left.and.arrow.down.right")
                                }
                                .controlSize(.small)
                            } else {
                                Button {
                                    expandNestedMix(entry)
                                } label: {
                                    Label("Expand .MIX", systemImage: "arrow.down.right.and.arrow.up.left")
                                }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.small)
                            }
                        }

                        if !archives.isEmpty {
                            let summary = previewMerge
                            Text("\(summary.mergedEntries.count) Entries • \(ByteCountFormatter.string(fromByteCount: Int64(summary.data.count), countStyle: .file)) (\(summary.duplicatesResolved) dupes)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding(10)

                    Divider()

                    if let err = errorMessage {
                        HStack {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(.red)
                            Text(err)
                                .font(.caption)
                                .foregroundColor(.red)
                            Spacer()
                            Button("Dismiss") { errorMessage = nil }
                                .font(.caption)
                        }
                        .padding(8)
                        .background(Color.red.opacity(0.1))
                    }

                    if let status = statusBanner {
                        HStack {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.green)
                            Text(status)
                                .font(.caption)
                            Spacer()
                            Button("Dismiss") { statusBanner = nil }
                                .font(.caption)
                        }
                        .padding(8)
                        .background(Color.green.opacity(0.1))
                    }

                    Table(filteredEntries, selection: $selectedEntryID) {
                        TableColumn("Name / CRC File ID") { entry in
                            HStack(spacing: 6) {
                                if entry.isNestedMix {
                                    Image(systemName: isNestedArchiveExpanded(entry) ? "shippingbox" : "shippingbox.fill")
                                        .foregroundColor(.accentColor)
                                        .font(.caption)
                                } else if entry.isSHPSprite {
                                    Image(systemName: "photo.on.rectangle")
                                        .foregroundColor(.purple)
                                        .font(.caption)
                                } else if entry.isPlayableAudio {
                                    Image(systemName: "waveform")
                                        .foregroundColor(.orange)
                                        .font(.caption)
                                }
                                Text(entry.displayLabel)
                                    .font(.system(.caption, design: .monospaced))
                                    .fontWeight(.semibold)
                            }
                        }
                        .width(min: 185, max: 250)

                        TableColumn("Detected Type") { entry in
                            Text(entry.detectedType)
                                .font(.caption)
                                .foregroundColor(typeColor(for: entry))
                        }
                        .width(min: 100, max: 125)

                        TableColumn("Offset") { entry in
                            Text(String(format: "0x%06X", entry.originalOffset))
                                .font(.system(.caption, design: .monospaced))
                                .foregroundColor(.secondary)
                        }
                        .width(min: 75, max: 95)

                        TableColumn("Size") { entry in
                            Text(ByteCountFormatter.string(fromByteCount: Int64(entry.size), countStyle: .file))
                                .font(.caption)
                        }
                        .width(min: 70, max: 90)

                        TableColumn("Source Archive") { entry in
                            Text(entry.sourceArchive)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .width(min: 95, max: 135)

                        TableColumn("Actions") { entry in
                            HStack(spacing: 6) {
                                if entry.isNestedMix {
                                    if isNestedArchiveExpanded(entry) {
                                        Button("Unexpand") {
                                            selectedEntryID = entry.id
                                            unexpandNestedMix(entry)
                                        }
                                        .buttonStyle(.bordered)
                                        .controlSize(.mini)
                                    } else {
                                        Button("Expand") {
                                            selectedEntryID = entry.id
                                            expandNestedMix(entry)
                                        }
                                        .buttonStyle(.borderedProminent)
                                        .controlSize(.mini)
                                    }
                                } else if entry.isPlayableAudio {
                                    Button {
                                        selectedEntryID = entry.id
                                        toggleAudio(for: entry)
                                    } label: {
                                        Image(systemName: (isPlayingAudio && selectedEntryID == entry.id) ? "stop.fill" : "play.fill")
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.mini)
                                }
                                Button {
                                    extractSingleEntry(entry)
                                } label: {
                                    Image(systemName: "arrow.down.doc")
                                }
                                .buttonStyle(.borderless)
                                .help("Extract File")
                            }
                        }
                        .width(min: 105, max: 125)
                    }
                    .contextMenu(forSelectionType: MixEntry.ID.self) { ids in
                        if let firstID = ids.first,
                           let entry = previewMerge.mergedEntries.first(where: { $0.id == firstID }) {
                            if entry.isNestedMix {
                                Button(isNestedArchiveExpanded(entry) ? "Unexpand Nested .MIX" : "Expand Nested .MIX") {
                                    toggleNestedMix(entry)
                                }
                            }
                            Button("Extract File...") {
                                extractSingleEntry(entry)
                            }
                        }
                    } primaryAction: { ids in
                        if let firstID = ids.first,
                           let entry = previewMerge.mergedEntries.first(where: { $0.id == firstID }) {
                            if entry.isNestedMix {
                                toggleNestedMix(entry)
                            } else if entry.isPlayableAudio {
                                toggleAudio(for: entry)
                            }
                        }
                    }
                    .onChange(of: selectedEntryID) { _, _ in
                        stopAudio()
                    }
                }
                .frame(minHeight: 280)

                // Bottom Inspector Preview Pane
                if let entry = selectedEntry {
                    EntryPreviewInspector(
                        entry: entry,
                        isExpanded: isNestedArchiveExpanded(entry),
                        availablePalettes: availablePalettes,
                        isPlayingAudio: $isPlayingAudio,
                        onToggleAudio: { toggleAudio(for: entry) },
                        onExportDecodedWAV: { exportDecodedWAV(for: entry) },
                        onToggleExpand: { toggleNestedMix(entry) },
                        onExtract: { extractSingleEntry(entry) }
                    )
                    .frame(minHeight: 190, idealHeight: 240, maxHeight: 360)
                }
            }
        }
        .frame(minWidth: 1000, minHeight: 640)
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            handleDrop(providers: providers)
        }
    }

    private func typeColor(for entry: MixEntry) -> Color {
        if entry.isNestedMix { return .accentColor }
        if entry.isSHPSprite { return .purple }
        if entry.isPlayableAudio { return .orange }
        return .primary
    }

    private func isNestedArchiveExpanded(_ entry: MixEntry) -> Bool {
        let label = entry.knownName ?? "\(entry.hexID).MIX"
        return archives.contains { $0.isExpandedChild && ($0.sourceCRC == entry.crcID || $0.fileName == label) }
    }

    private func toggleNestedMix(_ entry: MixEntry) {
        if isNestedArchiveExpanded(entry) {
            unexpandNestedMix(entry)
        } else {
            expandNestedMix(entry)
        }
    }

    private func unexpandNestedMix(_ entry: MixEntry) {
        let label = entry.knownName ?? "\(entry.hexID).MIX"
        archives.removeAll { $0.isExpandedChild && ($0.sourceCRC == entry.crcID || $0.fileName == label) }
        statusBanner = "Unexpanded \(label)."
    }

    private func unexpandAllNested() {
        let count = expandedChildCount
        archives.removeAll { $0.isExpandedChild }
        statusBanner = "Unexpanded \(count) nested archive(s)."
    }

    private func importFilenameDatabase() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        if panel.runModal() == .OK {
            var totalAdded = 0
            for url in panel.urls {
                let accessed = url.startAccessingSecurityScopedResource()
                defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                if let data = try? Data(contentsOf: url) {
                    totalAdded += WestwoodNameDatabase.shared.importDatabaseBlob(data)
                }
            }
            dictionaryRevision += 1
            statusBanner = "Imported \(totalAdded) new filename(s) into Global Dictionary (\(WestwoodNameDatabase.shared.count) total)."
        }
    }

    private func toggleAudio(for entry: MixEntry) {
        if isPlayingAudio {
            stopAudio()
            return
        }
        do {
            let playableData: Data
            if entry.detectedType == "AUD Audio" {
                guard let decoded = WestwoodAudioDecoder.decodeAUDToWAV(entry.payload) else {
                    errorMessage = "Could not decode Westwood .AUD audio stream."
                    return
                }
                playableData = decoded
            } else {
                playableData = entry.payload
            }
            let player = try AVAudioPlayer(data: playableData)
            player.play()
            audioPlayer = player
            isPlayingAudio = true
        } catch {
            errorMessage = "Audio playback failed: \(error.localizedDescription)"
        }
    }

    private func stopAudio() {
        audioPlayer?.stop()
        audioPlayer = nil
        isPlayingAudio = false
    }

    private func exportDecodedWAV(for entry: MixEntry) {
        guard let wavData = WestwoodAudioDecoder.decodeAUDToWAV(entry.payload) else {
            errorMessage = "Could not decode .AUD stream to .WAV."
            return
        }
        let baseName = (entry.knownName as NSString?)?.deletingPathExtension ?? entry.hexID
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(baseName).WAV"
        if panel.runModal() == .OK, let url = panel.url {
            do {
                try wavData.write(to: url, options: .atomic)
                statusBanner = "Exported decoded WAV: \(url.lastPathComponent) (\(ByteCountFormatter.string(fromByteCount: Int64(wavData.count), countStyle: .file)))."
            } catch {
                errorMessage = "WAV export failed: \(error.localizedDescription)"
            }
        }
    }

    private func expandNestedMix(_ entry: MixEntry) {
        guard !isNestedArchiveExpanded(entry) else { return }
        errorMessage = nil
        isLoading = true
        let archiveLabel = entry.knownName ?? "\(entry.hexID).MIX"
        let payload = entry.payload
        let crc = entry.crcID

        Task.detached(priority: .userInitiated) {
            do {
                let parsed = try WestwoodMixEngine.parse(
                    data: payload,
                    name: archiveLabel,
                    isExpandedChild: true,
                    sourceCRC: crc
                )
                await MainActor.run {
                    archives.append(parsed)
                    dictionaryRevision += 1
                    statusBanner = "Expanded \(archiveLabel) (\(parsed.entries.count) inner files)."
                    isLoading = false
                }
            } catch {
                await MainActor.run {
                    errorMessage = "Could not expand \(archiveLabel): \(error.localizedDescription)"
                    isLoading = false
                }
            }
        }
    }

    private func extractSingleEntry(_ entry: MixEntry) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = entry.suggestedFilename
        if panel.runModal() == .OK, let url = panel.url {
            do {
                try entry.payload.write(to: url, options: .atomic)
                statusBanner = "Extracted \(url.lastPathComponent) (\(ByteCountFormatter.string(fromByteCount: Int64(entry.size), countStyle: .file)))."
            } catch {
                errorMessage = "Extraction failed: \(error.localizedDescription)"
            }
        }
    }

    private func batchExtractAll() {
        let entriesToExtract = filteredEntries
        guard !entriesToExtract.isEmpty else { return }

        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Extract \(entriesToExtract.count) Files Here"

        if panel.runModal() == .OK, let folderURL = panel.url {
            isLoading = true
            Task.detached(priority: .userInitiated) {
                do {
                    let count = try WestwoodMixEngine.batchExtract(entries: entriesToExtract, to: folderURL)
                    await MainActor.run {
                        statusBanner = "Extracted \(count) files to \(folderURL.lastPathComponent)/."
                        isLoading = false
                    }
                } catch {
                    await MainActor.run {
                        errorMessage = "Batch extraction failed: \(error.localizedDescription)"
                        isLoading = false
                    }
                }
            }
        }
    }

    private func addMixFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [UTType(filenameExtension: "mix") ?? .data]
        if panel.runModal() == .OK {
            loadURLs(panel.urls)
        }
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        for provider in providers {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                guard let data = item as? Data,
                      let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                DispatchQueue.main.async {
                    loadURLs([url])
                }
            }
        }
        return true
    }

    private func loadURLs(_ urls: [URL]) {
        errorMessage = nil
        isLoading = true
        Task.detached(priority: .userInitiated) {
            var loaded: [LoadedMixArchive] = []
            var firstError: String?

            for url in urls {
                do {
                    let parsed = try WestwoodMixEngine.parse(url: url)
                    loaded.append(parsed)
                } catch {
                    firstError = error.localizedDescription
                }
            }

            await MainActor.run {
                for item in loaded {
                    archives.append(item)
                    if (item.variant == .redAlertTS || item.variant == .redAlertTSEncrypted) && archives.count == 1 {
                        useRAHeaderFlag = true
                    }
                }
                dictionaryRevision += 1
                if let err = firstError {
                    errorMessage = err
                }
                isLoading = false
            }
        }
    }

    private func exportMergedMix() {
        let merged = previewMerge
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "COMBINED.MIX"
        panel.allowedContentTypes = [UTType(filenameExtension: "mix") ?? .data]
        if panel.runModal() == .OK, let url = panel.url {
            do {
                try merged.data.write(to: url, options: .atomic)
                statusBanner = "Exported \(url.lastPathComponent) (\(merged.mergedEntries.count) files, \(ByteCountFormatter.string(fromByteCount: Int64(merged.data.count), countStyle: .file)))."
            } catch {
                errorMessage = "Failed to export: \(error.localizedDescription)"
            }
        }
    }

// MARK: - Bottom Inspector Preview Pane

struct EntryPreviewInspector: View {
    let entry: MixEntry
    let isExpanded: Bool
    let availablePalettes: [(name: String, data: Data)]
    @Binding var isPlayingAudio: Bool
    let onToggleAudio: () -> Void
    let onExportDecodedWAV: () -> Void
    let onToggleExpand: () -> Void
    let onExtract: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Inspector: \(entry.displayLabel)", systemImage: "eye")
                    .font(.caption)
                    .fontWeight(.bold)
                Text("• \(entry.detectedType) • \(ByteCountFormatter.string(fromByteCount: Int64(entry.size), countStyle: .file))")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                if entry.isPlayableAudio {
                    Button {
                        onToggleAudio()
                    } label: {
                        Label(isPlayingAudio ? "Stop Audio" : "Play Audio", systemImage: isPlayingAudio ? "stop.fill" : "play.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)

                    if entry.detectedType == "AUD Audio" {
                        Button("Export WAV...") {
                            onExportDecodedWAV()
                        }
                        .controlSize(.small)
                    }
                }
                if entry.isNestedMix {
                    Button(isExpanded ? "Unexpand Nested .MIX" : "Expand Nested .MIX") {
                        onToggleExpand()
                    }
                    .controlSize(.small)
                }
                Button("Extract Raw...") {
                    onExtract()
                }
                .controlSize(.small)
            }

            Divider()

            if entry.detectedType == "VQA Video" {
                VQAVideoPreview(entry: entry)
            } else if entry.isSHPSprite {
                SHPSpritePreview(entry: entry, availablePalettes: availablePalettes)
            } else if entry.detectedType == "INI / Text" {
                let text = String(data: entry.payload.prefix(65_536), encoding: .windowsCP1252)
                    ?? String(decoding: entry.payload.prefix(65_536), as: UTF8.self)
                ScrollView {
                    Text(text)
                        .font(.system(.caption, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding(6)
                }
                .background(Color(nsColor: .textBackgroundColor))
                .cornerRadius(6)
            } else if entry.detectedType == "PAL (256-Color)" && entry.payload.count == 768 {
                PaletteSwatchGrid(palData: entry.payload)
            } else {
                ScrollView {
                    Text(hexDump(data: entry.payload.prefix(512)))
                        .font(.system(.caption2, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding(6)
                }
                .background(Color(nsColor: .textBackgroundColor))
                .cornerRadius(6)
            }
        }
        .padding(10)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func hexDump(data: Data) -> String {
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
}

// MARK: - Interactive .SHP Sprite Viewer

struct SHPSpritePreview: View {
    let entry: MixEntry
    let availablePalettes: [(name: String, data: Data)]

    @State private var decodedSprite: DecodedSHPSprite?
    @State private var frameIndex: Int = 0
    @State private var selectedPaletteIndex: Int = 0
    @State private var zoomScale: CGFloat = 3.0
    @State private var isAnimating: Bool = false
    private let animTimer = Timer.publish(every: 0.12, on: .main, in: .common).autoconnect()

    var activePaletteData: Data {
        if selectedPaletteIndex >= 0 && selectedPaletteIndex < availablePalettes.count {
            return availablePalettes[selectedPaletteIndex].data
        }
        return WestwoodSHPDecoder.defaultFallbackPalette
    }

    var body: some View {
        VStack(spacing: 8) {
            if let sprite = decodedSprite {
                HStack(spacing: 12) {
                    Text("\(sprite.width)×\(sprite.height) px • Frame \(frameIndex + 1) / \(sprite.frameCount)")
                        .font(.caption)
                        .fontWeight(.semibold)

                    Button {
                        frameIndex = (frameIndex - 1 + sprite.frameCount) % sprite.frameCount
                    } label: {
                        Image(systemName: "backward.frame.fill")
                    }
                    .controlSize(.small)
                    .disabled(sprite.frameCount <= 1)

                    Button {
                        isAnimating.toggle()
                    } label: {
                        Image(systemName: isAnimating ? "pause.fill" : "play.fill")
                    }
                    .controlSize(.small)
                    .disabled(sprite.frameCount <= 1)

                    Button {
                        frameIndex = (frameIndex + 1) % sprite.frameCount
                    } label: {
                        Image(systemName: "forward.frame.fill")
                    }
                    .controlSize(.small)
                    .disabled(sprite.frameCount <= 1)

                    Picker("Palette", selection: $selectedPaletteIndex) {
                        ForEach(0..<availablePalettes.count, id: \.self) { idx in
                            Text(availablePalettes[idx].name).tag(idx)
                        }
                    }
                    .frame(maxWidth: 190)
                    .controlSize(.small)

                    Picker("Zoom", selection: $zoomScale) {
                        Text("1×").tag(CGFloat(1.0))
                        Text("2×").tag(CGFloat(2.0))
                        Text("3×").tag(CGFloat(3.0))
                        Text("4×").tag(CGFloat(4.0))
                    }
                    .frame(maxWidth: 75)
                    .controlSize(.small)

                    Spacer()

                    Button("Export PNG...") {
                        exportCurrentFramePNG(sprite: sprite)
                    }
                    .controlSize(.small)

                    if sprite.frameCount > 1 {
                        Button("Export Sheet...") {
                            exportSpriteSheetPNG(sprite: sprite)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .help("Export all \(sprite.frameCount) frames stitched into a single PNG sprite sheet")
                    }
                }
                

                ScrollView([.horizontal, .vertical]) {
                    if let nsImage = sprite.renderFrame(frameIndex, palette768: activePaletteData) {
                        Image(nsImage: nsImage)
                            .interpolation(.none)
                            .resizable()
                            .frame(
                                width: CGFloat(sprite.width) * zoomScale,
                                height: CGFloat(sprite.height) * zoomScale
                            )
                            .background(Color.black.opacity(0.65))
                            .cornerRadius(4)
                            .padding(6)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .textBackgroundColor))
                .cornerRadius(6)
            } else {
                Text("Decoding .SHP sprite frames...")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .onAppear {
            frameIndex = 0
            isAnimating = false
            decodedSprite = WestwoodSHPDecoder.decodeSHP(entry.payload)
        }
        .onChange(of: entry.id) { _, _ in
            frameIndex = 0
            isAnimating = false
            decodedSprite = WestwoodSHPDecoder.decodeSHP(entry.payload)
        }
        .onReceive(animTimer) { _ in
            guard isAnimating, let sprite = decodedSprite, sprite.frameCount > 1 else { return }
            frameIndex = (frameIndex + 1) % sprite.frameCount
        }
    }
    
    private func exportSpriteSheetPNG(sprite: DecodedSHPSprite) {
        guard let nsImage = sprite.renderSpriteSheet(palette768: activePaletteData),
              let tiffData = nsImage.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let pngData = bitmap.representation(using: .png, properties: [:]) else {
            return
        }
        let baseName = (entry.knownName as NSString?)?.deletingPathExtension ?? entry.hexID
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(baseName)_sheet_\(sprite.frameCount)frames.png"
        if panel.runModal() == .OK, let url = panel.url {
            try? pngData.write(to: url, options: .atomic)
        }
    }

    private func exportCurrentFramePNG(sprite: DecodedSHPSprite) {
        guard let nsImage = sprite.renderFrame(frameIndex, palette768: activePaletteData),
              let tiffData = nsImage.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let pngData = bitmap.representation(using: .png, properties: [:]) else {
            return
        }
        let baseName = (entry.knownName as NSString?)?.deletingPathExtension ?? entry.hexID
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(baseName)_frame\(frameIndex + 1).png"
        if panel.runModal() == .OK, let url = panel.url {
            try? pngData.write(to: url, options: .atomic)
        }
    }
}

struct PaletteSwatchGrid: View {
    let palData: Data

    var body: some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: 2), count: 32)
        ScrollView {
            LazyVGrid(columns: columns, spacing: 2) {
                ForEach(0..<256, id: \.self) { idx in
                    let base = idx * 3
                    let r = Double(min(palData[base], 63)) / 63.0
                    let g = Double(min(palData[base + 1], 63)) / 63.0
                    let b = Double(min(palData[base + 2], 63)) / 63.0
                    Rectangle()
                        .fill(Color(red: r, green: g, blue: b))
                        .frame(height: 14)
                        .help("Index \(idx): RGB(\(palData[base]), \(palData[base + 1]), \(palData[base + 2]))")
                }
            }
            .padding(4)
        }
    }
}

    struct VQAVideoPreview: View {
        let entry: MixEntry
        @State private var decodedVQA: WestwoodAudioDecoder.DecodedVQAVideo?
        @State private var frameIndex: Int = 0
        @State private var isPlaying: Bool = false
        @State private var audioPlayer: AVAudioPlayer?
        @State private var isPlayingAudio: Bool = false
        private let timer = Timer.publish(every: 0.08, on: .main, in: .common).autoconnect()

        var body: some View {
            VStack(spacing: 8) {
                if let vqa = decodedVQA {
                    let totalFrames = max(1, vqa.frameOffsets.count)
                    HStack(spacing: 12) {
                        Text("\(vqa.width)×\(vqa.height) • \(vqa.fps) FPS • Frame \(min(frameIndex + 1, totalFrames)) / \(totalFrames)")
                            .font(.caption)
                            .fontWeight(.semibold)

                        Button {
                            frameIndex = (frameIndex - 1 + totalFrames) % totalFrames
                        } label: {
                            Image(systemName: "backward.frame.fill")
                        }
                        .controlSize(.small)

                        Button {
                            isPlaying.toggle()
                        } label: {
                            Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                        }
                        .controlSize(.small)

                        Button {
                            frameIndex = (frameIndex + 1) % totalFrames
                        } label: {
                            Image(systemName: "forward.frame.fill")
                        }
                        .controlSize(.small)

                        if let wavData = vqa.wavAudioData {
                            Button {
                                toggleVQAAudio(wavData: wavData)
                            } label: {
                                Label(isPlayingAudio ? "Stop Audio" : "Play Audio", systemImage: isPlayingAudio ? "stop.fill" : "speaker.wave.2.fill")
                            }
                            .controlSize(.small)

                            Button("Export Audio WAV...") {
                                exportVQAAudioWAV(wavData: wavData)
                            }
                            .controlSize(.small)
                        }

                        Spacer()
                    }

                    ScrollView([.horizontal, .vertical]) {
                        if let nsImage = vqa.renderFrame(frameIndex, vqaData: entry.payload) {
                            Image(nsImage: nsImage)
                                .interpolation(.none)
                                .resizable()
                                .frame(
                                    width: CGFloat(min(vqa.width, 320)),
                                    height: CGFloat(min(vqa.height, 200))
                                )
                                .background(Color.black.opacity(0.65))
                                .cornerRadius(4)
                                .padding(6)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(nsColor: .textBackgroundColor))
                    .cornerRadius(6)
                } else {
                    Text("Parsing .VQA video stream...")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .onAppear {
                resetVQA()
            }
            .onChange(of: entry.id) { _, _ in
                resetVQA()
            }
            .onDisappear {
                stopVQAAudio()
            }
            .onReceive(timer) { _ in
                guard isPlaying, let vqa = decodedVQA else { return }
                let total = max(1, vqa.frameOffsets.count)
                frameIndex = (frameIndex + 1) % total
            }
        }

        private func resetVQA() {
            stopVQAAudio()
            frameIndex = 0
            isPlaying = false
            decodedVQA = WestwoodAudioDecoder.WestwoodVQADecoder.decodeVQA(entry.payload)
        }

        private func toggleVQAAudio(wavData: Data) {
            if isPlayingAudio {
                stopVQAAudio()
                return
            }
            do {
                let player = try AVAudioPlayer(data: wavData)
                player.play()
                audioPlayer = player
                isPlayingAudio = true
            } catch {
                isPlayingAudio = false
            }
        }

        private func stopVQAAudio() {
            audioPlayer?.stop()
            audioPlayer = nil
            isPlayingAudio = false
        }

        private func exportVQAAudioWAV(wavData: Data) {
            let baseName = (entry.knownName as NSString?)?.deletingPathExtension ?? entry.hexID
            let panel = NSSavePanel()
            panel.nameFieldStringValue = "\(baseName).WAV"
            if panel.runModal() == .OK, let url = panel.url {
                try? wavData.write(to: url, options: .atomic)
            }
        }
    }
    }
