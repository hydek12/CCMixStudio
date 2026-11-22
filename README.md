CCMixStudio is a native macOS SwiftUI utility and headless CLI for inspecting, extracting, merging, packing, verifying, and exporting assets from Westwood Studios .MIX archives.

Archive Handling: Parses unencrypted and RSA/Blowfish-encrypted .MIX archives, expands and unexpands nested .MIX sub-archives in place, deduplicates or overwrites colliding CRC IDs during archive merges, packs loose files into new archives, and exports or verifies OpenRA-compatible combined .MIX files.

Filename Resolution: Combines a built-in Command & Conquer / Red Alert filename dictionary with automatic ingestion and merging of embedded local mix database.dat chunks and external XCC global mix database.dat or .txt/.ini lists.

Asset Inspection & Export:

Sprites (.SHP): Decodes LCW (Format80) and XOR delta (Format40/Format20) frames with palette switching (including built-in Snow and Temperate presets and imported 768-byte .PAL palettes), animation playback, single-frame PNG export, and multi-frame PNG sprite sheet stitching.

Audio (.AUD & .VQA SND2): Decodes IMA ADPCM and Westwood ADPCM streams to PCM WAV for in-app playback and .WAV export.

Video (.VQA): Parses VQHD metadata (dimensions, frame count, FPS, audio presence), CPAL/CPLZ palettes, and CBF/CBFZ/VPT/VPTZ frame data with frame stepping and playback controls.

## Command-Line Interface (CLI)

The standard `CCMixStudio.app` executable supports headless command-line invocation directly without launching a GUI window. You can invoke it directly via its app bundle binary or create a symlink/alias:

```bash
# Direct invocation
/Applications/CCMixStudio.app/Contents/MacOS/CCMixStudio --help

# Optional convenience symlink
ln -s /Applications/CCMixStudio.app/Contents/MacOS/CCMixStudio /usr/local/bin/ccmixstudio
```

### Combining Multiple `.MIX` Files for OpenRA Clients

```bash
# Combine multiple .MIX files (including encrypted archives and nested sub-archives)
# into a single unencrypted, CRC-sorted, deduplicated .MIX compatible with OpenRA:
CCMixStudio combine MAIN.MIX EXPAND.MIX MOD.MIX -o COMBINED.MIX --expand-nested

# Keep first occurrence on duplicate CRC IDs, add loose files, and import an external name list:
CCMixStudio combine CONQUER.MIX GENERAL.MIX --add-file RULES.INI -o CUSTOM.MIX \
  --format openra --duplicates keep-first --names "global mix database.dat"

# Verify OpenRA compatibility on an existing .MIX archive:
CCMixStudio verify COMBINED.MIX --strict-openra

# Pack loose assets or extract / export assets from the command line:
CCMixStudio pack ./mod_assets -r -o MOD_PACK.MIX --format openra
CCMixStudio extract COMBINED.MIX -o ./extracted --expand-nested
CCMixStudio export-shp COMBINED.MIX --entry 1TNK.SHP --sheet --palette temperate -o 1TNK_sheet.png
CCMixStudio export-aud COMBINED.MIX --entry AWAIT1.AUD -o await1.wav

# Open the desktop GUI preloaded with archives and options:
CCMixStudio --gui CONQUER.MIX EXPAND.MIX --ra-header --expand-nested
```

#### OpenRA Compatibility Behavior (`--format openra`, default for `combine` & `pack`)

- Emits unencrypted archives with an ascending `UInt32` CRC-sorted index and validated entry count (`<= 65,535`) and payload size (`<= 4 GiB`).
- Enforces unique CRC IDs (rejects `--duplicates keep-all` in `openra` mode) so OpenRA package indexes do not collide.
- Flattens nested `.MIX` archives recursively when `--expand-nested` (`--flatten`) is passed, removing redundant nested container blobs by default (override with `--keep-nested-containers`, `--expand <name-or-crc>`, or `--expand-depth <n>`).
- Merges embedded `local mix database.dat` tables across combined archives by default (`--local-db merge|keep|strip|generate`) and verifies the generated archive (`--verify`).

### All Supported CLI Subcommands

- `combine` (`merge`): Combine multiple `.MIX` archives (and optional `--add-file` / `--add-dir` loose files) into a single `.MIX` archive (`--format openra|auto|ra|classic`, `--duplicates overwrite-later|keep-first|keep-all`, `--expand-nested`, `--local-db merge|keep|strip|generate`, `--filter`, `--include`, `--exclude`, `--verify`, `--dry-run`, `--json`).
- `pack`: Pack loose files and directories into a `.MIX` archive.
- `inspect` (`info`): Display archive metadata, format variant, encryption status, nested archive counts, and merge summary.
- `list` (`ls`): List and filter entries by name, CRC (`0x...`), detected type, or source archive.
- `extract`: Batch-extract entries to a folder or extract specific `--entry` items.
- `cat` (`preview`): Print `INI / Text` payloads, palette values, hex dumps (`--hex`), or raw bytes (`--raw`).
- `export-shp`: Export a `.SHP` sprite frame (`--frame N`) or stitched PNG sprite sheet (`--sheet`) or all frames (`--all-frames`) with Snow, Temperate, archive `.PAL`, or external `.PAL` palette selection.
- `export-aud`: Decode `.AUD` audio streams to `.WAV`.
- `export-vqa`: Inspect `.VQA` metadata (`--info`), export decoded `SND2` audio (`--audio-out`), or render `.VQA` frames (`-o` / `--frames-dir`).
- `crc`: Compute Westwood CRC IDs for filenames.
- `dict`: Inspect or query the Global Filename Dictionary (`stats`, `lookup`, `check`) with `--names`.
- `verify`: Validate `.MIX` structure, CRC sorting, uniqueness, and OpenRA compatibility.
- `gui` / `--gui`: Launch the standard CCMixStudio desktop GUI optionally preloaded with `.MIX` files and merge options.
