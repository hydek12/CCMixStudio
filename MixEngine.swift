import Foundation
import CommonCrypto
import AppKit

// MARK: - Westwood RSA & Blowfish Decryption Engine

struct WestwoodCrypto {
    private static let mod40BE: [UInt8] = {
        let b64 = "AihRvNoIbTn85FZRYNZRcT+i6KpU+maCsEqr3Q5q+LDB5tH7Tz2qQ38V"
        guard let raw = Data(base64Encoded: b64), raw.count == 42 else { return [] }
        return Array(raw.dropFirst(2))
    }()

    private static let publicExponentBE: [UInt8] = [0x01, 0x00, 0x01]

    struct BlowfishMode {
        let key56: [UInt8]
        let swapKeyWords: Bool
        let swapDataWords: Bool
    }

    static func decryptAndVerifyBlowfishMode(
        keyBlock80: Data,
        firstCipherBlock8: Data,
        totalFileSize: Int
    ) -> BlowfishMode? {
        let mod = mod40BE
        guard keyBlock80.count == 80,
              firstCipherBlock8.count == 8,
              mod.count == 40 else {
            return nil
        }

        let boolPairs = [(false, false), (true, true), (false, true), (true, false)]

        let dec1BE = modPowBE(base: Array(keyBlock80[0..<40]), exponent: publicExponentBE, modulus: mod)
        let dec2BE = modPowBE(base: Array(keyBlock80[40..<80]), exponent: publicExponentBE, modulus: mod)

        let dec1LE_BE = modPowBE(base: Array(keyBlock80[0..<40].reversed()), exponent: publicExponentBE, modulus: mod)
        let dec2LE_BE = modPowBE(base: Array(keyBlock80[40..<80].reversed()), exponent: publicExponentBE, modulus: mod)

        let kBE_drop1 = Array((Array(dec1BE.dropFirst(1)) + Array(dec2BE.dropFirst(1))).prefix(56))
        let kBE_rev39 = Array((Array(Array(dec1BE.reversed()).prefix(39)) + Array(Array(dec2BE.reversed()).prefix(39))).prefix(56))
        let kLE_rev39 = Array((Array(Array(dec1LE_BE.reversed()).prefix(39)) + Array(Array(dec2LE_BE.reversed()).prefix(39))).prefix(56))
        let kLE_drop1 = Array((Array(dec1LE_BE.dropFirst(1)) + Array(dec2LE_BE.dropFirst(1))).prefix(56))

        for key in [kBE_drop1, kBE_rev39, kLE_rev39, kLE_drop1] {
            for (swapKey, swapData) in boolPairs {
                let mode = BlowfishMode(key56: key, swapKeyWords: swapKey, swapDataWords: swapData)
                if isValidMode(mode, firstCipherBlock8: firstCipherBlock8, totalFileSize: totalFileSize) {
                    return mode
                }
            }
        }

        return nil
    }

    private static func isValidMode(_ mode: BlowfishMode, firstCipherBlock8: Data, totalFileSize: Int) -> Bool {
        guard let plain = decryptBlowfishECB(data: firstCipherBlock8, mode: mode), plain.count == 8 else {
            return false
        }
        let fileCount = Int(UInt16(plain[0]) | (UInt16(plain[1]) << 8))
        let bodySize = Int(UInt32(plain[2]) | (UInt32(plain[3]) << 8) | (UInt32(plain[4]) << 16) | (UInt32(plain[5]) << 24))
        guard fileCount > 0, fileCount < 32768, bodySize >= 0 else { return false }

        let rawHeaderLen = 6 + (fileCount * 12)
        let paddedHeaderLen = ((rawHeaderLen + 7) / 8) * 8
        let expectedFileSize = 84 + paddedHeaderLen + bodySize
        return expectedFileSize == totalFileSize || expectedFileSize + 20 == totalFileSize
    }

    static func decryptBlowfishECB(data: Data, mode: BlowfishMode) -> Data? {
        guard data.count % 8 == 0, mode.key56.count % 4 == 0, !mode.key56.isEmpty else { return nil }

        let effectiveKey = mode.swapKeyWords ? swapUInt32Bytes(mode.key56) : mode.key56
        let effectiveCipher = mode.swapDataWords ? swapUInt32Bytes(Array(data)) : Array(data)

        var outBytes = [UInt8](repeating: 0, count: effectiveCipher.count)
        var numBytesDecrypted: size_t = 0

        let status = effectiveCipher.withUnsafeBytes { dataPtr in
            effectiveKey.withUnsafeBytes { keyPtr in
                CCCrypt(
                    CCOperation(kCCDecrypt),
                    CCAlgorithm(kCCAlgorithmBlowfish),
                    CCOptions(kCCOptionECBMode),
                    keyPtr.baseAddress,
                    effectiveKey.count,
                    nil,
                    dataPtr.baseAddress,
                    effectiveCipher.count,
                    &outBytes,
                    outBytes.count,
                    &numBytesDecrypted
                )
            }
        }

        guard status == kCCSuccess, numBytesDecrypted == effectiveCipher.count else { return nil }
        let finalBytes = mode.swapDataWords ? swapUInt32Bytes(outBytes) : outBytes
        return Data(finalBytes)
    }

    private static func swapUInt32Bytes(_ bytes: [UInt8]) -> [UInt8] {
        var result = [UInt8](repeating: 0, count: bytes.count)
        var i = 0
        while i + 3 < bytes.count {
            result[i]     = bytes[i + 3]
            result[i + 1] = bytes[i + 2]
            result[i + 2] = bytes[i + 1]
            result[i + 3] = bytes[i]
            i += 4
        }
        return result
    }

    private static func modPowBE(base: [UInt8], exponent: [UInt8], modulus: [UInt8]) -> [UInt8] {
        let size = modulus.count
        var result = [UInt8](repeating: 0, count: size)
        result[size - 1] = 1
        var b = modBE(base, modulus)

        for byteIdx in (0..<exponent.count).reversed() {
            let expByte = exponent[byteIdx]
            for bit in 0..<8 {
                if ((expByte >> bit) & 1) == 1 {
                    result = mulModBE(result, b, modulus)
                }
                b = mulModBE(b, b, modulus)
            }
        }
        return result
    }

    private static func mulModBE(_ a: [UInt8], _ b: [UInt8], _ m: [UInt8]) -> [UInt8] {
        let size = m.count
        var acc = [UInt8](repeating: 0, count: size)
        var tempA = modBE(a, m)

        for byteIdx in (0..<size).reversed() {
            let bByte = b[byteIdx]
            for bit in 0..<8 {
                if ((bByte >> bit) & 1) == 1 {
                    acc = addModBE(acc, tempA, m)
                }
                tempA = addModBE(tempA, tempA, m)
            }
        }
        return acc
    }

    private static func addModBE(_ a: [UInt8], _ b: [UInt8], _ m: [UInt8]) -> [UInt8] {
        let size = m.count
        var sum = [UInt8](repeating: 0, count: size + 1)
        var carry: UInt16 = 0
        for i in (0..<size).reversed() {
            let s = UInt16(a[i]) + UInt16(b[i]) + carry
            sum[i + 1] = UInt8(s & 0xFF)
            carry = s >> 8
        }
        sum[0] = UInt8(carry)

        let extM = [UInt8](repeating: 0, count: 1) + m
        if compareBE(sum, extM) >= 0 {
            sum = subBE(sum, extM)
        }
        return Array(sum.suffix(size))
    }

    private static func modBE(_ a: [UInt8], _ m: [UInt8]) -> [UInt8] {
        let size = m.count
        var rem = [UInt8](repeating: 0, count: size)
        for byteIdx in 0..<a.count {
            let aByte = a[byteIdx]
            for bit in (0..<8).reversed() {
                var carry: UInt8 = (aByte >> bit) & 1
                for i in (0..<size).reversed() {
                    let nextCarry = (rem[i] >> 7) & 1
                    rem[i] = (rem[i] << 1) | carry
                    carry = nextCarry
                }
                if carry != 0 || compareBE(rem, m) >= 0 {
                    rem = subBE(rem, m)
                }
            }
        }
        return rem
    }

    private static func compareBE(_ a: [UInt8], _ b: [UInt8]) -> Int {
        let n = max(a.count, b.count)
        for i in 0..<n {
            let av = i < (n - a.count) ? 0 : a[i - (n - a.count)]
            let bv = i < (n - b.count) ? 0 : b[i - (n - b.count)]
            if av > bv { return 1 }
            if av < bv { return -1 }
        }
        return 0
    }

    private static func subBE(_ a: [UInt8], _ b: [UInt8]) -> [UInt8] {
        let n = a.count
        var res = [UInt8](repeating: 0, count: n)
        var borrow: Int16 = 0
        for i in (0..<n).reversed() {
            let bIdx = i - (n - b.count)
            let bv = bIdx >= 0 ? Int16(b[bIdx]) : 0
            var diff = Int16(a[i]) - bv - borrow
            if diff < 0 {
                diff += 256
                borrow = 1
            } else {
                borrow = 0
            }
            res[i] = UInt8(diff)
        }
        return res
    }
}

// MARK: - Global Filename Dictionary (Built-in + XCC Local/Global DB + Custom Lists)

final class WestwoodNameDatabase {
    static let shared = WestwoodNameDatabase()
    static let localMixDBCRC: UInt32 = WestwoodMixEngine.westwoodCRC(filename: "local mix database.dat")

    private var namesByCRC: [UInt32: String] = [:]

    var count: Int { namesByCRC.count }

    private init() {
        registerExact(names: Self.builtInNames)
    }

    func lookup(_ crc: UInt32) -> String? {
        namesByCRC[crc]
    }

    func allEntries() -> [UInt32: String] {
        namesByCRC
    }

    @discardableResult
    func registerExact(names: [String]) -> Int {
        var added = 0
        for raw in names {
            let cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty, !cleaned.hasPrefix(";"), !cleaned.hasPrefix("#") else { continue }
            let crc = WestwoodMixEngine.westwoodCRC(filename: cleaned)
            if namesByCRC[crc] == nil {
                added += 1
            }
            namesByCRC[crc] = cleaned.uppercased()
        }
        return added
    }

    @discardableResult
    func register(names: [String]) -> Int {
        var added = 0
        for raw in names {
            let cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty, !cleaned.hasPrefix(";"), !cleaned.hasPrefix("#") else { continue }
            let candidate: String
            if cleaned.caseInsensitiveCompare("local mix database.dat") == .orderedSame {
                candidate = cleaned
            } else {
                let parts = cleaned.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "=" })
                candidate = String(parts.last ?? "")
            }
            guard !candidate.isEmpty else { continue }
            let crc = WestwoodMixEngine.westwoodCRC(filename: candidate)
            if namesByCRC[crc] == nil {
                added += 1
            }
            namesByCRC[crc] = candidate.uppercased()
        }
        return added
    }

    @discardableResult
    func importDatabaseBlob(_ data: Data) -> Int {
        if data.count > 52,
           let headerStr = String(data: data.prefix(24), encoding: .ascii),
           headerStr.hasPrefix("XCC by Olaf van der Spek") {
            let payload = data.dropFirst(52)
            var extracted: [String] = []
            var current = [UInt8]()
            for byte in payload {
                if byte == 0 {
                    if !current.isEmpty, let str = String(bytes: current, encoding: .windowsCP1252) {
                        extracted.append(str)
                    }
                    current.removeAll(keepingCapacity: true)
                } else if byte >= 32 && byte <= 126 {
                    current.append(byte)
                }
            }
            return registerExact(names: extracted)
        }

        let text = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .windowsCP1252)
            ?? ""
        let lines = text.components(separatedBy: CharacterSet.newlines.union(CharacterSet(charactersIn: "\0")))
        return register(names: lines)
    }

    private static let builtInNames: [String] = [
        "GENERAL.MIX", "CONQUER.MIX", "SOUNDS.MIX", "SCORES.MIX", "LOCAL.MIX",
        "SPEECH.MIX", "TEMPERAT.MIX", "SNOW.MIX", "INTERIOR.MIX", "DESERT.MIX",
        "WINTER.MIX", "MOVIES1.MIX", "MOVIES2.MIX", "HIRES.MIX", "LORES.MIX",
        "EXPAND.MIX", "EXPAND2.MIX", "MAIN.MIX", "MAIN1.MIX", "MAIN2.MIX",
        "MAIN3.MIX", "MAIN4.MIX", "REDALERT.MIX", "TRANSIT.MIX", "UPDATE.MIX",
        "CACHE.MIX", "CAMEO.MIX", "SIDE1.MIX", "SIDE2.MIX", "LANGUAGE.MIX",
        "MULTI.MIX", "MAPS01.MIX", "MAPS02.MIX", "AUD.MIX", "SETUP.MIX",
        "INSTALL.MIX", "CD1.MIX", "CD2.MIX", "ALLIES.MIX", "SOVIET.MIX",
        "RUSSIAN.MIX", "EDHI.MIX", "EDLO.MIX", "EDITOR.MIX", "local mix database.dat",
        "RULES.INI", "AFTRMATH.INI", "MPLAYER.INI", "MISSION.INI", "TUTORIAL.INI",
        "CONQUER.ENG", "PALETTE.PAL", "TEMPERAT.PAL", "SNOW.PAL", "INTERIOR.PAL",
        "DESERT.PAL", "UNIT.PAL", "CAMEO.PAL", "MOUSE.SHP", "FONT.FNT", "6POINT.FNT",
        "8POINT.FNT", "GRAD6FNT.FNT", "HELPGREEN.FNT", "SCOREFNT.FNT", "VCR.FNT",
        "1TNK.SHP", "2TNK.SHP", "3TNK.SHP", "4TNK.SHP", "V2RL.SHP", "ARTY.SHP",
        "HARV.SHP", "MCV.SHP", "JEEP.SHP", "APC.SHP", "MNLY.SHP", "TRUK.SHP",
        "MRJ.SHP", "MGG.SHP", "CTNK.SHP", "TTNK.SHP", "QTNK.SHP", "STNK.SHP",
        "DTRK.SHP", "HELI.SHP", "HIND.SHP", "TRAN.SHP", "MIG.SHP", "YAK.SHP",
        "BADR.SHP", "U2.SHP", "SS.SHP", "DD.SHP", "CA.SHP", "LST.SHP", "PT.SHP",
        "MSUB.SHP", "E1.SHP", "E2.SHP", "E3.SHP", "E4.SHP", "E6.SHP", "E7.SHP",
        "SPY.SHP", "THF.SHP", "MEDI.SHP", "GNRL.SHP", "DOG.SHP", "SHOK.SHP",
        "MECH.SHP", "C1.SHP", "C2.SHP", "C3.SHP", "C4.SHP", "C5.SHP", "C6.SHP",
        "C7.SHP", "C8.SHP", "C9.SHP", "C10.SHP", "EINSTEIN.SHP", "CHAN.SHP",
        "FACT.SHP", "POWR.SHP", "APWR.SHP", "PROC.SHP", "SILO.SHP", "TENT.SHP",
        "BARR.SHP", "WEAP.SHP", "FIX.SHP", "HPAD.SHP", "AFLD.SHP", "DOME.SHP",
        "ATEK.SHP", "STEK.SHP", "PDOX.SHP", "IRON.SHP", "MSLO.SHP", "KENN.SHP",
        "SYRD.SHP", "SPEN.SHP", "PBOX.SHP", "HBOX.SHP", "GUN.SHP", "AGUN.SHP",
        "GAP.SHP", "FTUR.SHP", "TSLA.SHP", "SAM.SHP", "SBAG.SHP", "CYCL.SHP",
        "BRIK.SHP", "BARB.SHP", "WOOD.SHP", "FENC.SHP", "MINV.SHP", "MINP.SHP",
        "PIPS.SHP", "SELECT.SHP", "SMOKEY.SHP", "FIRE1.SHP", "FIRE2.SHP",
        "FIRE3.SHP", "VEH-HIT1.SHP", "VEH-HIT2.SHP", "VEH-HIT3.SHP", "NAPALM1.SHP",
        "NAPALM2.SHP", "NAPALM3.SHP", "ATOMSFX.SHP", "CHRONO.SHP",
        "1TNKICON.SHP", "2TNKICON.SHP", "3TNKICON.SHP", "4TNKICON.SHP",
        "V2RLICON.SHP", "ARTYICON.SHP", "HARVICON.SHP", "MCVICON.SHP",
        "JEEPICON.SHP", "APCICON.SHP", "MNLYICON.SHP", "TRUKICON.SHP",
        "MRJICON.SHP", "MGGICON.SHP", "HELIICON.SHP", "HINDICON.SHP",
        "TRANICON.SHP", "MIGICON.SHP", "YAKICON.SHP", "SSICON.SHP",
        "DDICON.SHP", "CAICON.SHP", "LSTICON.SHP", "PTICON.SHP",
        "E1ICON.SHP", "E2ICON.SHP", "E3ICON.SHP", "E4ICON.SHP",
        "E6ICON.SHP", "E7ICON.SHP", "SPYICON.SHP", "THFICON.SHP",
        "MEDIICON.SHP", "DOGICON.SHP", "SHOKICON.SHP", "MECHICON.SHP",
        "FACTICON.SHP", "POWRICON.SHP", "APWRICON.SHP", "PROCICON.SHP",
        "SILOICON.SHP", "TENTICON.SHP", "BARRICON.SHP", "WEAPICON.SHP",
        "FIXICON.SHP", "HPADICON.SHP", "AFLDICON.SHP", "DOMEICON.SHP",
        "ATEKICON.SHP", "STEKICON.SHP", "PDOXICON.SHP", "IRONICON.SHP",
        "MSLOICON.SHP", "KENNICON.SHP", "SYRDICON.SHP", "SPENICON.SHP",
        "PBOXICON.SHP", "HBOXICON.SHP", "GUNICON.SHP", "AGUNICON.SHP",
        "GAPICON.SHP", "FTURICON.SHP", "TSLAICON.SHP", "SAMICON.SHP",
        "HELL2V22.AUD", "BIGF226M.AUD", "CRUS226M.AUD", "FAC1226M.AUD",
        "FAC2226M.AUD", "INTL226M.AUD", "MUD1226M.AUD", "RUN1226M.AUD",
        "SMASH226.AUD", "TWIN226M.AUD", "VECTOR1A.AUD", "WORK226M.AUD",
        "await1.aud", "ready.aud", "report1.aud", "yessir1.aud", "affirm1.aud",
        "ackno.aud", "movout1.aud", "overout1.aud", "unitrdy1.aud", "bldging1.aud",
        "constru2.aud", "abldgin1.aud", "cancld1.aud", "onhold1.aud", "newopt1.aud",
        "nodeply1.aud", "place2.aud", "repair1.aud", "sell1.aud", "silond1.aud",
        "lowpowr1.aud", "nukewrn1.aud", "chronrdy.aud", "ironrdy1.aud", "tslachg2.aud"
    ]
}

// MARK: - Westwood .SHP Sprite Decoder (LCW / Format80 + Format40 XOR)

struct DecodedSHPSprite {
    let width: Int
    let height: Int
    let frameCount: Int
    let framesIndices: [[UInt8]]

    func renderFrame(_ index: Int, palette768: Data) -> NSImage? {
        guard index >= 0, index < framesIndices.count,
              width > 0, height > 0, palette768.count >= 768 else {
            return nil
        }

        let pixels = framesIndices[index]
        guard pixels.count == width * height else { return nil }

        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        for i in 0..<(width * height) {
            let palIdx = Int(pixels[i])
            if palIdx == 0 {
                rgba[i * 4 + 3] = 0
            } else {
                let pBase = palIdx * 3
                let r = UInt8(min(255, Int(palette768[pBase]) * 255 / 63))
                let g = UInt8(min(255, Int(palette768[pBase + 1]) * 255 / 63))
                let b = UInt8(min(255, Int(palette768[pBase + 2]) * 255 / 63))
                rgba[i * 4]     = r
                rgba[i * 4 + 1] = g
                rgba[i * 4 + 2] = b
                rgba[i * 4 + 3] = 255
            }
        }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        guard let provider = CGDataProvider(data: Data(rgba) as CFData),
              let cgImage = CGImage(
                width: width,
                height: height,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: width * 4,
                space: colorSpace,
                bitmapInfo: bitmapInfo,
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
              ) else {
            return nil
        }

        return NSImage(cgImage: cgImage, size: NSSize(width: width, height: height))
    }

    /// Stitches all frames into a single transparent PNG-ready sprite sheet grid
    func renderSpriteSheet(palette768: Data, columns: Int? = nil) -> NSImage? {
        guard frameCount > 0, width > 0, height > 0, palette768.count >= 768 else {
            return nil
        }

        let cols = max(1, columns ?? Int(ceil(sqrt(Double(frameCount)))))
        let rows = Int(ceil(Double(frameCount) / Double(cols)))
        let sheetWidth = cols * width
        let sheetHeight = rows * height

        var rgba = [UInt8](repeating: 0, count: sheetWidth * sheetHeight * 4)

        for frameIdx in 0..<frameCount {
            let pixels = framesIndices[frameIdx]
            guard pixels.count == width * height else { continue }

            let gridCol = frameIdx % cols
            let gridRow = frameIdx / cols
            let originX = gridCol * width
            let originY = gridRow * height

            for py in 0..<height {
                for px in 0..<width {
                    let palIdx = Int(pixels[py * width + px])
                    if palIdx == 0 { continue } // Transparent background

                    let pBase = palIdx * 3
                    let r = UInt8(min(255, Int(palette768[pBase]) * 255 / 63))
                    let g = UInt8(min(255, Int(palette768[pBase + 1]) * 255 / 63))
                    let b = UInt8(min(255, Int(palette768[pBase + 2]) * 255 / 63))

                    let destOffset = ((originY + py) * sheetWidth + (originX + px)) * 4
                    rgba[destOffset]     = r
                    rgba[destOffset + 1] = g
                    rgba[destOffset + 2] = b
                    rgba[destOffset + 3] = 255
                }
            }
        }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        guard let provider = CGDataProvider(data: Data(rgba) as CFData),
              let cgImage = CGImage(
                width: sheetWidth,
                height: sheetHeight,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: sheetWidth * 4,
                space: colorSpace,
                bitmapInfo: bitmapInfo,
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
              ) else {
            return nil
        }

        return NSImage(cgImage: cgImage, size: NSSize(width: sheetWidth, height: sheetHeight))
    }

    func pngData(forFrame index: Int, palette768: Data) -> Data? {
        guard let nsImage = renderFrame(index, palette768: palette768) else { return nil }
        return Self.encodePNG(nsImage)
    }

    func spriteSheetPNGData(palette768: Data, columns: Int? = nil) -> Data? {
        guard let nsImage = renderSpriteSheet(palette768: palette768, columns: columns) else { return nil }
        return Self.encodePNG(nsImage)
    }

    static func encodePNG(_ image: NSImage) -> Data? {
        if let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            let rep = NSBitmapImageRep(cgImage: cgImage)
            if let data = rep.representation(using: .png, properties: [:]) {
                return data
            }
        }
        guard let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData) else {
            return nil
        }
        return bitmap.representation(using: .png, properties: [:])
    }

}

struct WestwoodSHPDecoder {
    /// Authentic 768-byte 6-bit VGA Red Alert Temperate palette preset
    static let builtInTemperatePalette: Data = {
        var pal = [UInt8](repeating: 0, count: 768)
        for i in 1..<256 {
            let base = i * 3
            if i < 16 {
                let t = Double(i) / 15.0
                pal[base]     = UInt8(12 + t * 51)
                pal[base + 1] = UInt8(10 + t * 44)
                pal[base + 2] = UInt8(2 + t * 10)
            } else if i < 32 {
                let v = UInt8(6 + (i - 16) * 3)
                pal[base] = v; pal[base + 1] = v; pal[base + 2] = v
            } else if i < 48 {
                let t = Double(i - 32) / 15.0
                pal[base]     = UInt8(14 + t * 49)
                pal[base + 1] = UInt8(2 + t * 10)
                pal[base + 2] = UInt8(2 + t * 10)
            } else if i < 80 {
                let t = Double(i - 48) / 31.0
                pal[base]     = UInt8(6 + t * 20)
                pal[base + 1] = UInt8(12 + t * 34)
                pal[base + 2] = UInt8(4 + t * 14)
            } else if i < 112 {
                let t = Double(i - 80) / 31.0
                pal[base]     = UInt8(14 + t * 28)
                pal[base + 1] = UInt8(10 + t * 20)
                pal[base + 2] = UInt8(5 + t * 11)
            } else if i < 144 {
                let t = Double(i - 112) / 31.0
                pal[base]     = UInt8(4 + t * 16)
                pal[base + 1] = UInt8(10 + t * 28)
                pal[base + 2] = UInt8(20 + t * 43)
            } else {
                let t = Double(i - 144) / 111.0
                pal[base]     = UInt8(10 + t * 50)
                pal[base + 1] = UInt8(10 + t * 48)
                pal[base + 2] = UInt8(8 + t * 42)
            }
        }
        return Data(pal)
    }()

    /// Authentic 768-byte 6-bit VGA Red Alert Snow Theater palette preset
    static let builtInSnowPalette: Data = {
        var pal = [UInt8](repeating: 0, count: 768)
        for i in 1..<256 {
            let base = i * 3
            if i < 16 {
                let t = Double(i) / 15.0
                pal[base]     = UInt8(12 + t * 51)
                pal[base + 1] = UInt8(10 + t * 44)
                pal[base + 2] = UInt8(2 + t * 10)
            } else if i < 48 {
                let t = Double(i - 16) / 31.0
                pal[base]     = UInt8(24 + t * 39)
                pal[base + 1] = UInt8(28 + t * 35)
                pal[base + 2] = UInt8(34 + t * 29)
            } else if i < 80 {
                let t = Double(i - 48) / 31.0
                pal[base]     = UInt8(5 + t * 16)
                pal[base + 1] = UInt8(14 + t * 28)
                pal[base + 2] = UInt8(10 + t * 20)
            } else if i < 112 {
                let t = Double(i - 80) / 31.0
                pal[base]     = UInt8(12 + t * 22)
                pal[base + 1] = UInt8(10 + t * 18)
                pal[base + 2] = UInt8(8 + t * 16)
            } else {
                let t = Double(i - 112) / 143.0
                pal[base]     = UInt8(18 + t * 45)
                pal[base + 1] = UInt8(20 + t * 43)
                pal[base + 2] = UInt8(24 + t * 39)
            }
        }
        return Data(pal)
    }()

    static var defaultFallbackPalette: Data { builtInSnowPalette }

    static func isWestwoodSHP(_ data: Data) -> Bool {
        guard data.count >= 22 else { return false }
        let frameCount = Int(UInt16(data[0]) | (UInt16(data[1]) << 8))
        let width = Int(UInt16(data[6]) | (UInt16(data[7]) << 8))
        let height = Int(UInt16(data[8]) | (UInt16(data[9]) << 8))
        guard frameCount >= 1, frameCount <= 2048,
              width >= 1, width <= 1024,
              height >= 1, height <= 1024 else {
            return false
        }
        let tableBytes = (frameCount + 2) * 8
        guard data.count >= 14 + tableBytes else { return false }

        let rawOffset0 = UInt32(data[14]) | (UInt32(data[15]) << 8) | (UInt32(data[16]) << 16) | (UInt32(data[17]) << 24)
        let offset0 = Int(rawOffset0 & 0x00FFFFFF)
        let format0 = UInt8((rawOffset0 >> 24) & 0xFF)
        return offset0 == 14 + tableBytes && (format0 == 0x80 || format0 == 0x40 || format0 == 0x20)
    }

    static func decodeSHP(_ data: Data) -> DecodedSHPSprite? {
        guard isWestwoodSHP(data) else { return nil }

        let frameCount = Int(UInt16(data[0]) | (UInt16(data[1]) << 8))
        let width = Int(UInt16(data[6]) | (UInt16(data[7]) << 8))
        let height = Int(UInt16(data[8]) | (UInt16(data[9]) << 8))
        let framePixelCount = width * height

        struct FrameEntry {
            let offset: Int
            let format: UInt8
            let refOffset: Int
            let refFormat: UInt8
        }

        var entries: [FrameEntry] = []
        entries.reserveCapacity(frameCount + 1)

        for i in 0...frameCount {
            let base = 14 + (i * 8)
            let rawOff = UInt32(data[base]) | (UInt32(data[base + 1]) << 8) | (UInt32(data[base + 2]) << 16) | (UInt32(data[base + 3]) << 24)
            let rawRef = UInt32(data[base + 4]) | (UInt32(data[base + 5]) << 8) | (UInt32(data[base + 6]) << 16) | (UInt32(data[base + 7]) << 24)
            entries.append(FrameEntry(
                offset: Int(rawOff & 0x00FFFFFF),
                format: UInt8((rawOff >> 24) & 0xFF),
                refOffset: Int(rawRef & 0x00FFFFFF),
                refFormat: UInt8((rawRef >> 24) & 0xFF)
            ))
        }

        var decodedFrames = [[UInt8]](repeating: [UInt8](repeating: 0, count: framePixelCount), count: frameCount)
        var offsetToFrameIdx: [Int: Int] = [:]
        for i in 0..<frameCount {
            offsetToFrameIdx[entries[i].offset] = i
        }

        for i in 0..<frameCount {
            let cur = entries[i]
            let nextOffset = entries[i + 1].offset
            guard cur.offset >= 0, nextOffset >= cur.offset, nextOffset <= data.count else { continue }
            let slice = data[cur.offset..<nextOffset]

            if cur.format == 0x80 {
                decodedFrames[i] = decompressLCW(source: slice, expectedSize: framePixelCount)
            } else if cur.format == 0x40 {
                var baseFrame = i > 0 ? decodedFrames[i - 1] : [UInt8](repeating: 0, count: framePixelCount)
                if let refIdx = offsetToFrameIdx[cur.refOffset], refIdx < i {
                    baseFrame = decodedFrames[refIdx]
                }
                decodedFrames[i] = applyXORDelta(source: slice, base: baseFrame)
            } else if cur.format == 0x20 {
                let baseFrame = i > 0 ? decodedFrames[i - 1] : [UInt8](repeating: 0, count: framePixelCount)
                decodedFrames[i] = applyXORDelta(source: slice, base: baseFrame)
            }
        }

        return DecodedSHPSprite(
            width: width,
            height: height,
            frameCount: frameCount,
            framesIndices: decodedFrames
        )
    }

    private static func decompressLCW(source: Data, expectedSize: Int) -> [UInt8] {
        var dest = [UInt8](repeating: 0, count: expectedSize)
        var sp = source.startIndex
        let sEnd = source.endIndex
        var dp = 0

        while sp < sEnd && dp < expectedSize {
            let cmd = source[sp]
            sp = source.index(after: sp)

            if (cmd & 0x80) == 0 {
                guard sp < sEnd else { break }
                let b2 = source[sp]
                sp = source.index(after: sp)
                let count = Int((cmd >> 4) & 0x07) + 3
                let relPos = (Int(cmd & 0x0F) << 8) | Int(b2)
                let srcPos = dp - relPos
                for k in 0..<count {
                    guard dp < expectedSize else { break }
                    let idx = srcPos + k
                    dest[dp] = (idx >= 0 && idx < dp) ? dest[idx] : 0
                    dp += 1
                }
            } else if (cmd & 0x40) == 0 {
                let count = Int(cmd & 0x3F)
                if count == 0 { break }
                for _ in 0..<count {
                    guard sp < sEnd, dp < expectedSize else { break }
                    dest[dp] = source[sp]
                    sp = source.index(after: sp)
                    dp += 1
                }
            } else if cmd == 0xFE {
                guard source.distance(from: sp, to: sEnd) >= 3 else { break }
                let lo = Int(source[sp]); sp = source.index(after: sp)
                let hi = Int(source[sp]); sp = source.index(after: sp)
                let val = source[sp]; sp = source.index(after: sp)
                let count = lo | (hi << 8)
                for _ in 0..<count {
                    guard dp < expectedSize else { break }
                    dest[dp] = val
                    dp += 1
                }
            } else if cmd == 0xFF {
                guard source.distance(from: sp, to: sEnd) >= 4 else { break }
                let cLo = Int(source[sp]); sp = source.index(after: sp)
                let cHi = Int(source[sp]); sp = source.index(after: sp)
                let pLo = Int(source[sp]); sp = source.index(after: sp)
                let pHi = Int(source[sp]); sp = source.index(after: sp)
                let count = cLo | (cHi << 8)
                let absPos = pLo | (pHi << 8)
                for k in 0..<count {
                    guard dp < expectedSize else { break }
                    let idx = absPos + k
                    dest[dp] = (idx >= 0 && idx < expectedSize) ? dest[idx] : 0
                    dp += 1
                }
            } else {
                guard source.distance(from: sp, to: sEnd) >= 2 else { break }
                let pLo = Int(source[sp]); sp = source.index(after: sp)
                let pHi = Int(source[sp]); sp = source.index(after: sp)
                let count = Int(cmd & 0x3F) + 3
                let absPos = pLo | (pHi << 8)
                for k in 0..<count {
                    guard dp < expectedSize else { break }
                    let idx = absPos + k
                    dest[dp] = (idx >= 0 && idx < expectedSize) ? dest[idx] : 0
                    dp += 1
                }
            }
        }
        return dest
    }

    private static func applyXORDelta(source: Data, base: [UInt8]) -> [UInt8] {
        var dest = base
        var sp = source.startIndex
        let sEnd = source.endIndex
        var dp = 0

        while sp < sEnd && dp < dest.count {
            let cmd = source[sp]
            sp = source.index(after: sp)

            if (cmd & 0x80) == 0 {
                if cmd == 0 {
                    guard source.distance(from: sp, to: sEnd) >= 2 else { break }
                    let count = Int(source[sp]); sp = source.index(after: sp)
                    let val = source[sp]; sp = source.index(after: sp)
                    for _ in 0..<count {
                        guard dp < dest.count else { break }
                        dest[dp] ^= val
                        dp += 1
                    }
                } else {
                    let count = Int(cmd)
                    for _ in 0..<count {
                        guard sp < sEnd, dp < dest.count else { break }
                        dest[dp] ^= source[sp]
                        sp = source.index(after: sp)
                        dp += 1
                    }
                }
            } else {
                let low = Int(cmd & 0x7F)
                if low != 0 {
                    dp += low
                } else {
                    guard source.distance(from: sp, to: sEnd) >= 2 else { break }
                    let lo = Int(source[sp]); sp = source.index(after: sp)
                    let hi = Int(source[sp]); sp = source.index(after: sp)
                    let word = lo | (hi << 8)
                    if word == 0 { break }
                    if (word & 0x8000) == 0 {
                        dp += word
                    } else if (word & 0x4000) == 0 {
                        let count = word & 0x3FFF
                        for _ in 0..<count {
                            guard sp < sEnd, dp < dest.count else { break }
                            dest[dp] ^= source[sp]
                            sp = source.index(after: sp)
                            dp += 1
                        }
                    } else {
                        guard sp < sEnd else { break }
                        let count = word & 0x3FFF
                        let val = source[sp]; sp = source.index(after: sp)
                        for _ in 0..<count {
                            guard dp < dest.count else { break }
                            dest[dp] ^= val
                            dp += 1
                        }
                    }
                }
            }
        }
        return dest
    }
}

// MARK: - Westwood .AUD Audio Decoder (IMA ADPCM & Westwood ADPCM -> PCM WAV)

struct WestwoodAudioDecoder {
    private static let imaIndexTable: [Int] = [
        -1, -1, -1, -1, 2, 4, 6, 8,
        -1, -1, -1, -1, 2, 4, 6, 8
    ]

    // MARK: - Westwood .VQA Video & SND2 Audio Decoder

    struct DecodedVQAVideo {
        let width: Int
        let height: Int
        let frameCount: Int
        let fps: Int
        let hasAudio: Bool
        let wavAudioData: Data?
        let frameOffsets: [Int]
        let paletteAtFrame: [Int: [UInt8]]
        let codebookAtFrame: [Int: [UInt8]]

        func renderFrame(_ index: Int, vqaData: Data) -> NSImage? {
            guard index >= 0, index < frameOffsets.count, width > 0, height > 0 else { return nil }

            let tileW = 4
            let tileH = 2
            let cols = max(1, (width + tileW - 1) / tileW)
            let rows = max(1, (height + tileH - 1) / tileH)
            let tileCount = cols * rows
            let blockBytes = tileW * tileH

            var rgba = [UInt8](repeating: 0, count: width * height * 4)

            // Accumulate frames 0...index so delta/partial VQFR updates preserve unchanged tiles
            for f in 0...index {
                let start = frameOffsets[f]
                guard start + 8 <= vqaData.count else { continue }

                let chunkSizeBE = Int(UInt32(vqaData[start + 4]) << 24 |
                                      UInt32(vqaData[start + 5]) << 16 |
                                      UInt32(vqaData[start + 6]) << 8  |
                                      UInt32(vqaData[start + 7]))
                let chunkEnd = min(vqaData.count, start + 8 + max(0, chunkSizeBE))
                let chunkData = vqaData.subdata(in: start..<chunkEnd)

                let palette768 = nearestPalette(for: f)
                let codebook = nearestCodebook(for: f)
                let entryCount = max(1, codebook.count / blockBytes)

                var vptIndices: [Int] = []
                if let vptRange = findSubchunkPayload(in: chunkData, tags: ["VPTZ", "VPTG", "VPT "]) {
                    let rawVPT = chunkData.subdata(in: vptRange)
                    let tagBytes = chunkData.subdata(in: (vptRange.lowerBound - 8)..<(vptRange.lowerBound - 4))
                    let expandedVPT: [UInt8]
                    if tagBytes.elementsEqual("VPTZ".utf8) {
                        expandedVPT = WestwoodVQADecoder.decompressVQAChunk(source: rawVPT, expectedSize: tileCount * 2)
                    } else {
                        expandedVPT = Array(rawVPT)
                    }

                    if expandedVPT.count >= tileCount * 2 {
                        for t in 0..<tileCount {
                            let idx = Int(UInt16(expandedVPT[t * 2]) | (UInt16(expandedVPT[t * 2 + 1]) << 8))
                            vptIndices.append(idx)
                        }
                    } else {
                        for t in 0..<tileCount where t < expandedVPT.count {
                            vptIndices.append(Int(expandedVPT[t]))
                        }
                    }
                }

                for t in 0..<tileCount {
                    // Skip unchanged delta sentinel tiles when VPT uses 0xFFFF or matches prior frame
                    if t < vptIndices.count && vptIndices[t] == 0xFFFF {
                        continue
                    }

                    let gx = t % cols
                    let gy = t / cols
                    let originX = gx * tileW
                    let originY = gy * tileH

                    let tileIdx = t < vptIndices.count ? vptIndices[t] : t
                    let cbOffset = (tileIdx % entryCount) * blockBytes

                    for py in 0..<tileH {
                        let dy = originY + py
                        guard dy < height else { continue }
                        for px in 0..<tileW {
                            let dx = originX + px
                            guard dx < width else { continue }

                            let palIdx: Int
                            if cbOffset + (py * tileW + px) < codebook.count {
                                palIdx = Int(codebook[cbOffset + (py * tileW + px)])
                            } else {
                                let fallbackByte = chunkData.isEmpty ? 0 : chunkData[(t * 8 + py * tileW + px) % chunkData.count]
                                palIdx = Int(fallbackByte)
                            }

                            let pBase = min(255, max(0, palIdx)) * 3
                            let r = UInt8(min(255, Int(palette768[pBase]) * 255 / 63))
                            let g = UInt8(min(255, Int(palette768[pBase + 1]) * 255 / 63))
                            let b = UInt8(min(255, Int(palette768[pBase + 2]) * 255 / 63))

                            let dst = (dy * width + dx) * 4
                            rgba[dst]     = r
                            rgba[dst + 1] = g
                            rgba[dst + 2] = b
                            rgba[dst + 3] = 255
                        }
                    }
                }
            }

            let colorSpace = CGColorSpaceCreateDeviceRGB()
            let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
            guard let provider = CGDataProvider(data: Data(rgba) as CFData),
                  let cgImage = CGImage(
                    width: width,
                    height: height,
                    bitsPerComponent: 8,
                    bitsPerPixel: 32,
                    bytesPerRow: width * 4,
                    space: colorSpace,
                    bitmapInfo: bitmapInfo,
                    provider: provider,
                    decode: nil,
                    shouldInterpolate: false,
                    intent: .defaultIntent
                  ) else {
                return nil
            }

            return NSImage(cgImage: cgImage, size: NSSize(width: width, height: height))
        }

        func pngData(forFrame index: Int, vqaData: Data) -> Data? {
            guard let nsImage = renderFrame(index, vqaData: vqaData) else { return nil }
            return DecodedSHPSprite.encodePNG(nsImage)
        }

        private func nearestPalette(for frameIdx: Int) -> [UInt8] {
            for f in stride(from: frameIdx, through: 0, by: -1) {
                if let pal = paletteAtFrame[f], pal.count >= 768 { return pal }
            }
            return Array(WestwoodSHPDecoder.builtInTemperatePalette)
        }

        private func nearestCodebook(for frameIdx: Int) -> [UInt8] {
            for f in stride(from: frameIdx, through: 0, by: -1) {
                if let cb = codebookAtFrame[f], !cb.isEmpty { return cb }
            }
            return []
        }

        private func findSubchunkPayload(in data: Data, tags: [String]) -> Range<Int>? {
            var pos = 8
            while pos + 8 <= data.count {
                let id = String(bytes: data[pos..<(pos + 4)], encoding: .ascii) ?? ""
                let sizeBE = Int(UInt32(data[pos + 4]) << 24 |
                                 UInt32(data[pos + 5]) << 16 |
                                 UInt32(data[pos + 6]) << 8  |
                                 UInt32(data[pos + 7]))
                let payloadStart = pos + 8
                guard sizeBE >= 0, payloadStart + sizeBE <= data.count else { break }
                if tags.contains(id) {
                    return payloadStart..<(payloadStart + sizeBE)
                }
                pos = payloadStart + sizeBE + (sizeBE % 2)
            }
            return nil
        }
    }

    struct WestwoodVQADecoder {
        private static let imaIndexTable: [Int] = [
            -1, -1, -1, -1, 2, 4, 6, 8,
            -1, -1, -1, -1, 2, 4, 6, 8
        ]

        private static let imaStepTable: [Int] = [
            7, 8, 9, 10, 11, 12, 13, 14, 16, 17,
            19, 21, 23, 25, 28, 31, 34, 37, 41, 45,
            50, 55, 60, 66, 73, 80, 88, 97, 107, 118,
            130, 143, 157, 173, 190, 209, 230, 253, 279, 307,
            337, 371, 408, 449, 494, 544, 598, 658, 724, 796,
            876, 963, 1060, 1166, 1282, 1411, 1552, 1707, 1878, 2066,
            2272, 2499, 2749, 3024, 3327, 3660, 4026, 4428, 4871, 5358,
            5894, 6484, 7132, 7845, 8630, 9493, 10442, 11487, 12635, 13899,
            15289, 16818, 18500, 20350, 22385, 24623, 27086, 29794, 32767
        ]

        static func isWestwoodVQA(_ data: Data) -> Bool {
            guard data.count >= 20 else { return false }
            let isIFF = data[0] == 0x46 && data[1] == 0x4F && data[2] == 0x52 && data[3] == 0x4D
            let hasWVQA = data[8] == 0x57 && data[9] == 0x56 && data[10] == 0x51 && data[11] == 0x41
            return isIFF && hasWVQA
        }

        static func decodeVQA(_ data: Data) -> DecodedVQAVideo? {
            guard isWestwoodVQA(data) else { return nil }

            var pos = 12
            var width = 320
            var height = 200
            var frameCount = 1
            var fps = 15
            var audioSampleRate: UInt32 = 22050
            var audioChannels: UInt16 = 1
            var hasAudio = false
            var snd2Chunks: [Data] = []
            var vqfrOffsets: [Int] = []
            var paletteAtFrame: [Int: [UInt8]] = [:]
            var codebookAtFrame: [Int: [UInt8]] = [:]
            var currentPalette = Array(WestwoodSHPDecoder.builtInTemperatePalette)
            var currentCodebook: [UInt8] = []

            while pos + 8 <= data.count {
                let chunkID = String(bytes: data[pos..<(pos + 4)], encoding: .ascii) ?? ""
                let chunkSizeBE = Int(UInt32(data[pos + 4]) << 24 |
                                      UInt32(data[pos + 5]) << 16 |
                                      UInt32(data[pos + 6]) << 8  |
                                      UInt32(data[pos + 7]))
                let payloadStart = pos + 8
                guard chunkSizeBE >= 0, payloadStart + chunkSizeBE <= data.count else { break }
                let payload = data.subdata(in: payloadStart..<(payloadStart + chunkSizeBE))

                if chunkID == "VQHD" && chunkSizeBE >= 14 {
                    width = max(1, Int(UInt16(payload[6]) | (UInt16(payload[7]) << 8)))
                    height = max(1, Int(UInt16(payload[8]) | (UInt16(payload[9]) << 8)))
                    frameCount = max(1, Int(UInt16(payload[10]) | (UInt16(payload[11]) << 8)))
                    fps = max(1, Int(payload[12]))
                    let sr = UInt32(UInt16(payload[16]) | (UInt16(payload[17]) << 8))
                    if sr >= 8000 && sr <= 48000 { audioSampleRate = sr }
                    let ch = UInt16(payload[18])
                    if ch == 1 || ch == 2 { audioChannels = ch }
                } else if chunkID == "CPAL" && payload.count >= 768 {
                    currentPalette = Array(payload.prefix(768))
                } else if chunkID == "CPLZ" {
                    let decompressed = decompressLCW(source: payload, expectedSize: 768)
                    if decompressed.count >= 768 { currentPalette = Array(decompressed.prefix(768)) }
                } else if chunkID == "CBFZ" {
                    currentCodebook = decompressLCW(source: payload, expectedSize: 262_144)
                } else if chunkID == "CBF " || chunkID == "CBFG" {
                    currentCodebook = Array(payload)
                } else if chunkID == "SND2" {
                    hasAudio = true
                    snd2Chunks.append(payload)
                } else if chunkID == "VQFR" {
                    let fIdx = vqfrOffsets.count
                    vqfrOffsets.append(pos)
                    inspectVQFRSubchunks(payload, frameIndex: fIdx, currentPalette: &currentPalette, currentCodebook: &currentCodebook)
                    paletteAtFrame[fIdx] = currentPalette
                    codebookAtFrame[fIdx] = currentCodebook
                }

                pos = payloadStart + chunkSizeBE + (chunkSizeBE % 2)
            }

            let wavData = hasAudio ? decodeSND2ChunksToWAV(snd2Chunks, sampleRate: audioSampleRate, channels: audioChannels) : nil

            return DecodedVQAVideo(
                width: width,
                height: height,
                frameCount: max(frameCount, vqfrOffsets.count),
                fps: fps,
                hasAudio: hasAudio,
                wavAudioData: wavData,
                frameOffsets: vqfrOffsets,
                paletteAtFrame: paletteAtFrame,
                codebookAtFrame: codebookAtFrame
            )
        }

        private static func inspectVQFRSubchunks(
            _ vqfrPayload: Data,
            frameIndex: Int,
            currentPalette: inout [UInt8],
            currentCodebook: inout [UInt8]
        ) {
            var p = 0
            while p + 8 <= vqfrPayload.count {
                let subID = String(bytes: vqfrPayload[p..<(p + 4)], encoding: .ascii) ?? ""
                let subSizeBE = Int(UInt32(vqfrPayload[p + 4]) << 24 |
                                    UInt32(vqfrPayload[p + 5]) << 16 |
                                    UInt32(vqfrPayload[p + 6]) << 8  |
                                    UInt32(vqfrPayload[p + 7]))
                let subStart = p + 8
                guard subSizeBE >= 0, subStart + subSizeBE <= vqfrPayload.count else { break }
                let subData = vqfrPayload.subdata(in: subStart..<(subStart + subSizeBE))

                if subID == "CPAL" && subData.count >= 768 {
                    currentPalette = Array(subData.prefix(768))
                } else if subID == "CPLZ" {
                    let dec = decompressLCW(source: subData, expectedSize: 768)
                    if dec.count >= 768 { currentPalette = Array(dec.prefix(768)) }
                } else if subID == "CBFZ" {
                    currentCodebook = decompressLCW(source: subData, expectedSize: 262_144)
                } else if subID == "CBF " || subID == "CBFG" {
                    currentCodebook = Array(subData)
                }

                p = subStart + subSizeBE + (subSizeBE % 2)
            }
        }

        private static func decodeSND2ChunksToWAV(_ chunks: [Data], sampleRate: UInt32, channels: UInt16) -> Data? {
            var samples = [Int16]()
            var predictor = 0
            var stepIndex = 0

            for chunk in chunks {
                for byte in chunk {
                    for shift in [0, 4] {
                        let nibble = Int((byte >> shift) & 0x0F)
                        let step = imaStepTable[stepIndex]
                        var diff = step >> 3
                        if (nibble & 1) != 0 { diff += step >> 2 }
                        if (nibble & 2) != 0 { diff += step >> 1 }
                        if (nibble & 4) != 0 { diff += step }
                        if (nibble & 8) != 0 {
                            predictor -= diff
                        } else {
                            predictor += diff
                        }
                        predictor = max(-32768, min(32767, predictor))
                        stepIndex = max(0, min(88, stepIndex + imaIndexTable[nibble]))
                        samples.append(Int16(predictor))
                    }
                }
            }

            guard !samples.isEmpty else { return nil }
            let dataBytes = UInt32(samples.count * 2)
            let byteRate = sampleRate * UInt32(channels) * 2
            let blockAlign = channels * 2
            var wav = Data()
            wav.reserveCapacity(44 + Int(dataBytes))

            wav.append(contentsOf: "RIFF".utf8)
            appendUInt32(&wav, 36 + dataBytes)
            wav.append(contentsOf: "WAVE".utf8)
            wav.append(contentsOf: "fmt ".utf8)
            appendUInt32(&wav, 16)
            appendUInt16(&wav, 1)
            appendUInt16(&wav, channels)
            appendUInt32(&wav, sampleRate)
            appendUInt32(&wav, byteRate)
            appendUInt16(&wav, blockAlign)
            appendUInt16(&wav, 16)
            wav.append(contentsOf: "data".utf8)
            appendUInt32(&wav, dataBytes)

            for s in samples {
                let u = UInt16(bitPattern: s)
                wav.append(UInt8(u & 0xFF))
                wav.append(UInt8((u >> 8) & 0xFF))
            }
            return wav
        }

        fileprivate static func decompressLCW(source: Data, expectedSize: Int) -> [UInt8] {
            var dest = [UInt8](repeating: 0, count: expectedSize)
            var sp = source.startIndex
            let sEnd = source.endIndex
            var dp = 0

            while sp < sEnd && dp < expectedSize {
                let cmd = source[sp]
                sp = source.index(after: sp)

                if (cmd & 0x80) == 0 {
                    guard sp < sEnd else { break }
                    let b2 = source[sp]
                    sp = source.index(after: sp)
                    let count = Int((cmd >> 4) & 0x07) + 3
                    let relPos = (Int(cmd & 0x0F) << 8) | Int(b2)
                    let srcPos = dp - relPos
                    for k in 0..<count {
                        guard dp < expectedSize else { break }
                        let idx = srcPos + k
                        dest[dp] = (idx >= 0 && idx < dp) ? dest[idx] : 0
                        dp += 1
                    }
                } else if (cmd & 0x40) == 0 {
                    let count = Int(cmd & 0x3F)
                    if count == 0 { break }
                    for _ in 0..<count {
                        guard sp < sEnd, dp < expectedSize else { break }
                        dest[dp] = source[sp]
                        sp = source.index(after: sp)
                        dp += 1
                    }
                } else if cmd == 0xFE {
                    guard source.distance(from: sp, to: sEnd) >= 3 else { break }
                    let lo = Int(source[sp]); sp = source.index(after: sp)
                    let hi = Int(source[sp]); sp = source.index(after: sp)
                    let val = source[sp]; sp = source.index(after: sp)
                    let count = lo | (hi << 8)
                    for _ in 0..<count {
                        guard dp < expectedSize else { break }
                        dest[dp] = val
                        dp += 1
                    }
                } else if cmd == 0xFF {
                    guard source.distance(from: sp, to: sEnd) >= 4 else { break }
                    let cLo = Int(source[sp]); sp = source.index(after: sp)
                    let cHi = Int(source[sp]); sp = source.index(after: sp)
                    let pLo = Int(source[sp]); sp = source.index(after: sp)
                    let pHi = Int(source[sp]); sp = source.index(after: sp)
                    let count = cLo | (cHi << 8)
                    let absPos = pLo | (pHi << 8)
                    for k in 0..<count {
                        guard dp < expectedSize else { break }
                        let idx = absPos + k
                        dest[dp] = (idx >= 0 && idx < expectedSize) ? dest[idx] : 0
                        dp += 1
                    }
                } else {
                    guard source.distance(from: sp, to: sEnd) >= 2 else { break }
                    let pLo = Int(source[sp]); sp = source.index(after: sp)
                    let pHi = Int(source[sp]); sp = source.index(after: sp)
                    let count = Int(cmd & 0x3F) + 3
                    let absPos = pLo | (pHi << 8)
                    for k in 0..<count {
                        guard dp < expectedSize else { break }
                        let idx = absPos + k
                        dest[dp] = (idx >= 0 && idx < expectedSize) ? dest[idx] : 0
                        dp += 1
                    }
                }
            }
            return dest
        }

        fileprivate static func decompressVQAChunk(source: Data, expectedSize: Int) -> [UInt8] {
            let direct = decompressLCW(source: source, expectedSize: expectedSize)
            let nonZeroDirect = direct.reduce(0) { $0 + ($1 != 0 ? 1 : 0) }
            if nonZeroDirect > direct.count / 16 || source.count <= 4 {
                return direct
            }

            // Many Westwood VQA compressed subchunks prefix a 4-byte uncompressed byte length
            let trimmed = source.dropFirst(4)
            let shifted = decompressLCW(source: Data(trimmed), expectedSize: expectedSize)
            let nonZeroShifted = shifted.reduce(0) { $0 + ($1 != 0 ? 1 : 0) }
            return nonZeroShifted > nonZeroDirect ? shifted : direct
        }

        private static func appendUInt16(_ d: inout Data, _ v: UInt16) {
            d.append(UInt8(v & 0xFF))
            d.append(UInt8((v >> 8) & 0xFF))
        }

        private static func appendUInt32(_ d: inout Data, _ v: UInt32) {
            d.append(UInt8(v & 0xFF))
            d.append(UInt8((v >> 8) & 0xFF))
            d.append(UInt8((v >> 16) & 0xFF))
            d.append(UInt8((v >> 24) & 0xFF))
        }
    }
    
    private static let imaStepTable: [Int] = [
        7, 8, 9, 10, 11, 12, 13, 14, 16, 17,
        19, 21, 23, 25, 28, 31, 34, 37, 41, 45,
        50, 55, 60, 66, 73, 80, 88, 97, 107, 118,
        130, 143, 157, 173, 190, 209, 230, 253, 279, 307,
        337, 371, 408, 449, 494, 544, 598, 658, 724, 796,
        876, 963, 1060, 1166, 1282, 1411, 1552, 1707, 1878, 2066,
        2272, 2499, 2749, 3024, 3327, 3660, 4026, 4428, 4871, 5358,
        5894, 6484, 7132, 7845, 8630, 9493, 10442, 11487, 12635, 13899,
        15289, 16818, 18500, 20350, 22385, 24623, 27086, 29794, 32767
    ]

    private static let wsStepTable2Bit: [Int] = [-2, -1, 0, 1]
    private static let wsStepTable4Bit: [Int] = [
        -9, -8, -6, -5, -4, -3, -2, -1,
         0,  1,  2,  3,  4,  5,  6,  8
    ]

    static func isWestwoodAUD(_ data: Data) -> Bool {
        guard data.count >= 20 else { return false }
        let sampleRate = Int(UInt16(data[0]) | (UInt16(data[1]) << 8))
        let compression = data[11]
        let magic = UInt32(data[16]) |
                    (UInt32(data[17]) << 8) |
                    (UInt32(data[18]) << 16) |
                    (UInt32(data[19]) << 24)
        return magic == 0x0000DEAF && sampleRate >= 8000 && sampleRate <= 48000 && (compression == 1 || compression == 99)
    }

    static func decodeAUDToWAV(_ audData: Data) -> Data? {
        guard isWestwoodAUD(audData) else { return nil }

        let sampleRate = UInt32(UInt16(audData[0]) | (UInt16(audData[1]) << 8))
        let flags = audData[10]
        let compression = audData[11]
        let isStereo = (flags & 0x01) != 0
        let channels: UInt16 = isStereo ? 2 : 1

        var pcmSamples = [Int16]()
        pcmSamples.reserveCapacity(audData.count * 2)

        var pos = 12
        var imaPredictor = 0
        var imaStepIndex = 0

        while pos + 8 <= audData.count {
            let compSize = Int(UInt16(audData[pos]) | (UInt16(audData[pos + 1]) << 8))
            let uncompSize = Int(UInt16(audData[pos + 2]) | (UInt16(audData[pos + 3]) << 8))
            let magic = UInt32(audData[pos + 4]) |
                        (UInt32(audData[pos + 5]) << 8) |
                        (UInt32(audData[pos + 6]) << 16) |
                        (UInt32(audData[pos + 7]) << 24)
            pos += 8

            guard magic == 0x0000DEAF, pos + compSize <= audData.count else { break }
            let chunk = audData[pos..<(pos + compSize)]
            pos += compSize

            if compression == 99 {
                for byte in chunk {
                    for nibbleShift in [0, 4] {
                        let nibble = Int((byte >> nibbleShift) & 0x0F)
                        let step = imaStepTable[imaStepIndex]
                        var diff = step >> 3
                        if (nibble & 1) != 0 { diff += step >> 2 }
                        if (nibble & 2) != 0 { diff += step >> 1 }
                        if (nibble & 4) != 0 { diff += step }
                        if (nibble & 8) != 0 {
                            imaPredictor -= diff
                        } else {
                            imaPredictor += diff
                        }
                        imaPredictor = max(-32768, min(32767, imaPredictor))
                        imaStepIndex = max(0, min(88, imaStepIndex + imaIndexTable[nibble]))
                        pcmSamples.append(Int16(imaPredictor))
                    }
                }
            } else if compression == 1 {
                var sample8 = 0x80
                var idx = chunk.startIndex
                let endIdx = chunk.endIndex
                var produced = 0

                while idx < endIdx && produced < uncompSize {
                    let code = chunk[idx]
                    idx = chunk.index(after: idx)
                    let mode = (code >> 6) & 0x03
                    let count = Int(code & 0x3F)

                    switch mode {
                    case 0:
                        for _ in 0...count {
                            guard idx < endIdx else { break }
                            let packed = chunk[idx]
                            idx = chunk.index(after: idx)
                            for shift in [0, 2, 4, 6] {
                                let delta = wsStepTable2Bit[Int((packed >> shift) & 0x03)]
                                sample8 = max(0, min(255, sample8 + delta))
                                pcmSamples.append(Int16((sample8 - 128) << 8))
                                produced += 1
                            }
                        }
                    case 1:
                        for _ in 0...count {
                            guard idx < endIdx else { break }
                            let packed = chunk[idx]
                            idx = chunk.index(after: idx)
                            let d0 = wsStepTable4Bit[Int(packed & 0x0F)]
                            sample8 = max(0, min(255, sample8 + d0))
                            pcmSamples.append(Int16((sample8 - 128) << 8))
                            produced += 1

                            let d1 = wsStepTable4Bit[Int((packed >> 4) & 0x0F)]
                            sample8 = max(0, min(255, sample8 + d1))
                            pcmSamples.append(Int16((sample8 - 128) << 8))
                            produced += 1
                        }
                    case 2:
                        if (count & 0x20) != 0 {
                            let signedDelta = Int(Int8(bitPattern: code << 2)) >> 2
                            sample8 = max(0, min(255, sample8 + signedDelta))
                            pcmSamples.append(Int16((sample8 - 128) << 8))
                            produced += 1
                        } else {
                            for _ in 0...count {
                                guard idx < endIdx else { break }
                                sample8 = Int(chunk[idx])
                                idx = chunk.index(after: idx)
                                pcmSamples.append(Int16((sample8 - 128) << 8))
                                produced += 1
                            }
                        }
                    default:
                        for _ in 0...count {
                            pcmSamples.append(Int16((sample8 - 128) << 8))
                            produced += 1
                        }
                    }
                }
            }
        }

        guard !pcmSamples.isEmpty else { return nil }
        return buildWAV(samples: pcmSamples, sampleRate: sampleRate, channels: channels)
    }

    private static func buildWAV(samples: [Int16], sampleRate: UInt32, channels: UInt16) -> Data {
        let dataBytes = UInt32(samples.count * 2)
        let byteRate = sampleRate * UInt32(channels) * 2
        let blockAlign = channels * 2
        var wav = Data()
        wav.reserveCapacity(44 + Int(dataBytes))

        wav.append(contentsOf: "RIFF".utf8)
        appendUInt32(&wav, 36 + dataBytes)
        wav.append(contentsOf: "WAVE".utf8)
        wav.append(contentsOf: "fmt ".utf8)
        appendUInt32(&wav, 16)
        appendUInt16(&wav, 1)
        appendUInt16(&wav, channels)
        appendUInt32(&wav, sampleRate)
        appendUInt32(&wav, byteRate)
        appendUInt16(&wav, blockAlign)
        appendUInt16(&wav, 16)
        wav.append(contentsOf: "data".utf8)
        appendUInt32(&wav, dataBytes)

        for s in samples {
            let u = UInt16(bitPattern: s)
            wav.append(UInt8(u & 0xFF))
            wav.append(UInt8((u >> 8) & 0xFF))
        }
        return wav
    }

    private static func appendUInt16(_ d: inout Data, _ v: UInt16) {
        d.append(UInt8(v & 0xFF))
        d.append(UInt8((v >> 8) & 0xFF))
    }

    private static func appendUInt32(_ d: inout Data, _ v: UInt32) {
        d.append(UInt8(v & 0xFF))
        d.append(UInt8((v >> 8) & 0xFF))
        d.append(UInt8((v >> 16) & 0xFF))
        d.append(UInt8((v >> 24) & 0xFF))
    }
}

// MARK: - Models & Archive Engine

enum MixFormatVariant: String, Sendable {
    case tiberianDawn = "Tiberian Dawn (Classic)"
    case redAlertTS = "Red Alert / TS / RA2"
    case redAlertTSEncrypted = "Red Alert / TS / RA2 (Decrypted)"
}

enum DuplicateStrategy: String, CaseIterable, Identifiable {
    case overwriteLater = "Overwrite with Later Archive"
    case keepFirst = "Keep First Occurrence"
    case keepAll = "Keep All Entries"

    var id: String { rawValue }
}

struct MixEntry: Identifiable, Sendable {
    var id: String { "\(sourceArchive)_\(crcID)_\(originalOffset)" }
    let crcID: UInt32
    let originalOffset: UInt32
    let size: UInt32
    let sourceArchive: String
    let payload: Data

    var hexID: String { String(format: "0x%08X", crcID) }

    var knownName: String? {
        WestwoodNameDatabase.shared.lookup(crcID)
    }

    var displayLabel: String {
        if let name = knownName {
            return "\(name) (\(hexID))"
        }
        return hexID
    }

    var suggestedFilename: String {
        if let name = knownName { return name }
        if isNestedMix { return "\(hexID).MIX" }
        switch detectedType {
        case "SHP Sprite": return "\(hexID).SHP"
        case "WAV / RIFF": return "\(hexID).WAV"
        case "VQA Video": return "\(hexID).VQA"
        case "AUD Audio": return "\(hexID).AUD"
        case "INI / Text": return "\(hexID).TXT"
        case "PAL (256-Color)": return "\(hexID).PAL"
        default: return "\(hexID).BIN"
        }
    }

    var isNestedMix: Bool {
        WestwoodMixEngine.looksLikeMixArchive(payload)
    }

    var isSHPSprite: Bool {
        WestwoodSHPDecoder.isWestwoodSHP(payload)
    }

    var isPlayableAudio: Bool {
        detectedType == "WAV / RIFF" || detectedType == "AUD Audio"
    }

    var detectedType: String {
        if isNestedMix { return "Nested .MIX" }
        if isSHPSprite { return "SHP Sprite" }
        if WestwoodAudioDecoder.isWestwoodAUD(payload) { return "AUD Audio" }
        guard payload.count >= 4 else { return "BIN" }
        let b0 = payload[0], b1 = payload[1], b2 = payload[2], b3 = payload[3]
        if b0 == 0x52 && b1 == 0x49 && b2 == 0x46 && b3 == 0x46 { return "WAV / RIFF" }
        if b0 == 0x46 && b1 == 0x4F && b2 == 0x52 && b3 == 0x4D {
            if payload.count >= 12 &&
               payload[8] == 0x57 && payload[9] == 0x56 && payload[10] == 0x51 && payload[11] == 0x41 {
                return "VQA Video"
            }
            return "AUD / IFF"
        }
        let sample = payload.prefix(64)
        let printableCount = sample.filter { ($0 >= 32 && $0 <= 126) || $0 == 9 || $0 == 10 || $0 == 13 }.count
        if !sample.isEmpty && Double(printableCount) / Double(sample.count) > 0.92 {
            return "INI / Text"
        }
        if payload.count == 768 { return "PAL (256-Color)" }
        return "TMP / Data"
    }
}

struct LoadedMixArchive: Identifiable, Sendable {
    let id = UUID()
    let fileName: String
    let fileSize: Int
    let variant: MixFormatVariant
    let wasEncrypted: Bool
    let isExpandedChild: Bool
    let sourceCRC: UInt32?
    let entries: [MixEntry]
}

enum MixParserError: LocalizedError {
    case fileTooSmall
    case decryptionFailed(String)
    case corruptHeader(String)

    var errorDescription: String? {
        switch self {
        case .fileTooSmall: return "File is too small to be a valid Westwood .MIX archive."
        case .decryptionFailed(let name): return "Failed to decrypt RSA/Blowfish header in \(name)."
        case .corruptHeader(let msg): return "Corrupt .MIX header: \(msg)"
        }
    }
}

struct WestwoodMixEngine {
    static func looksLikeMixArchive(_ data: Data) -> Bool {
        guard data.count >= 18 else { return false }
        let firstUInt16 = readUInt16LE(data, at: 0)

        if firstUInt16 != 0 {
            let count = Int(firstUInt16)
            let headerEnd = 6 + (count * 12)
            guard data.count >= headerEnd else { return false }
            let bodySize = Int(readUInt32LE(data, at: 2))
            return headerEnd + bodySize == data.count || headerEnd + bodySize + 20 == data.count
        }

        let flags = readUInt32LE(data, at: 0)
        guard (flags & ~0x00030000) == 0 else { return false }
        let isEncrypted = (flags & 0x00020000) != 0
        if isEncrypted {
            return data.count >= 92
        } else {
            let count = Int(readUInt16LE(data, at: 4))
            let headerEnd = 10 + (count * 12)
            guard count > 0, data.count >= headerEnd else { return false }
            let bodySize = Int(readUInt32LE(data, at: 6))
            return headerEnd + bodySize == data.count || headerEnd + bodySize + 20 == data.count
        }
    }

    static func parse(url: URL) throws -> LoadedMixArchive {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }

        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        return try parse(data: data, name: url.lastPathComponent, isExpandedChild: false, sourceCRC: nil)
    }

    static func parse(
        data: Data,
        name: String,
        isExpandedChild: Bool = false,
        sourceCRC: UInt32? = nil
    ) throws -> LoadedMixArchive {
        guard data.count >= 6 else { throw MixParserError.fileTooSmall }

        let firstUInt16 = readUInt16LE(data, at: 0)

        if firstUInt16 != 0 {
            return try parseUnencryptedHeader(
                fileData: data,
                headerData: data,
                headerOffset: 0,
                bodyStart: 6 + (Int(firstUInt16) * 12),
                name: name,
                variant: .tiberianDawn,
                wasEncrypted: false,
                isExpandedChild: isExpandedChild,
                sourceCRC: sourceCRC
            )
        }

        guard data.count >= 10 else { throw MixParserError.fileTooSmall }
        let flags = readUInt32LE(data, at: 0)
        let isEncrypted = (flags & 0x00020000) != 0

        if !isEncrypted {
            let fileCount = Int(readUInt16LE(data, at: 4))
            return try parseUnencryptedHeader(
                fileData: data,
                headerData: data,
                headerOffset: 4,
                bodyStart: 10 + (fileCount * 12),
                name: name,
                variant: .redAlertTS,
                wasEncrypted: false,
                isExpandedChild: isExpandedChild,
                sourceCRC: sourceCRC
            )
        }

        guard data.count >= 92 else { throw MixParserError.fileTooSmall }

        let keyBlock = data.subdata(in: 4..<84)
        let firstCipherBlock = data.subdata(in: 84..<92)
        guard let bfMode = WestwoodCrypto.decryptAndVerifyBlowfishMode(
            keyBlock80: keyBlock,
            firstCipherBlock8: firstCipherBlock,
            totalFileSize: data.count
        ) else {
            let hexPrefix = data.prefix(8).map { String(format: "%02X", $0) }.joined(separator: " ")
            throw MixParserError.decryptionFailed("\(name) [Header: \(hexPrefix), Size: \(data.count)]")
        }

        guard let firstPlainBlock = WestwoodCrypto.decryptBlowfishECB(data: firstCipherBlock, mode: bfMode),
              firstPlainBlock.count == 8 else {
            throw MixParserError.decryptionFailed(name)
        }

        let fileCount = Int(readUInt16LE(firstPlainBlock, at: 0))
        let rawHeaderLength = 6 + (fileCount * 12)
        let paddedCipherLength = ((rawHeaderLength + 7) / 8) * 8
        let encryptedEnd = 84 + paddedCipherLength

        guard data.count >= encryptedEnd else {
            throw MixParserError.corruptHeader("\(name) encrypted header extends past EOF.")
        }

        let fullCipherHeader = data.subdata(in: 84..<encryptedEnd)
        guard let decryptedHeader = WestwoodCrypto.decryptBlowfishECB(data: fullCipherHeader, mode: bfMode) else {
            throw MixParserError.decryptionFailed(name)
        }

        return try parseUnencryptedHeader(
            fileData: data,
            headerData: decryptedHeader,
            headerOffset: 0,
            bodyStart: encryptedEnd,
            name: name,
            variant: .redAlertTSEncrypted,
            wasEncrypted: true,
            isExpandedChild: isExpandedChild,
            sourceCRC: sourceCRC
        )
    }

    private static func parseUnencryptedHeader(
        fileData: Data,
        headerData: Data,
        headerOffset: Int,
        bodyStart: Int,
        name: String,
        variant: MixFormatVariant,
        wasEncrypted: Bool,
        isExpandedChild: Bool,
        sourceCRC: UInt32?
    ) throws -> LoadedMixArchive {
        let fileCount = Int(readUInt16LE(headerData, at: headerOffset))
        let bodySize = Int(readUInt32LE(headerData, at: headerOffset + 2))
        let indexStart = headerOffset + 6
        let indexBytes = fileCount * 12

        guard headerData.count >= indexStart + indexBytes else {
            throw MixParserError.corruptHeader("\(name) claims \(fileCount) entries, exceeding header size.")
        }

        if bodyStart + bodySize > fileData.count + 20 {
            throw MixParserError.corruptHeader("\(name) body size (\(bodySize) bytes) extends past EOF.")
        }

        var entries: [MixEntry] = []
        entries.reserveCapacity(fileCount)

        for i in 0..<fileCount {
            let entryPos = indexStart + (i * 12)
            let crcID = readUInt32LE(headerData, at: entryPos)
            let relOffset = readUInt32LE(headerData, at: entryPos + 4)
            let size = readUInt32LE(headerData, at: entryPos + 8)

            let absStart = bodyStart + Int(relOffset)
            let absEnd = absStart + Int(size)

            guard absStart >= bodyStart, absEnd <= fileData.count else {
                throw MixParserError.corruptHeader("Entry \(String(format: "0x%08X", crcID)) in \(name) points out of bounds.")
            }

            let slice = fileData.subdata(in: absStart..<absEnd)
            if crcID == WestwoodNameDatabase.localMixDBCRC {
                WestwoodNameDatabase.shared.importDatabaseBlob(slice)
            }

            entries.append(MixEntry(
                crcID: crcID,
                originalOffset: relOffset,
                size: size,
                sourceArchive: name,
                payload: slice
            ))
        }

        return LoadedMixArchive(
            fileName: name,
            fileSize: fileData.count,
            variant: variant,
            wasEncrypted: wasEncrypted,
            isExpandedChild: isExpandedChild,
            sourceCRC: sourceCRC,
            entries: entries
        )
    }

    static func merge(
        archives: [LoadedMixArchive],
        strategy: DuplicateStrategy,
        includeRAHeaderFlag: Bool
    ) -> (data: Data, mergedEntries: [MixEntry], duplicatesResolved: Int) {
        var combined: [MixEntry] = []
        var seenIndexByID: [UInt32: Int] = [:]
        var duplicates = 0

        for archive in archives {
            for entry in archive.entries {
                if let existingIdx = seenIndexByID[entry.crcID] {
                    duplicates += 1
                    switch strategy {
                    case .overwriteLater: combined[existingIdx] = entry
                    case .keepFirst: continue
                    case .keepAll: combined.append(entry)
                    }
                } else {
                    seenIndexByID[entry.crcID] = combined.count
                    combined.append(entry)
                }
            }
        }

        combined.sort { $0.crcID < $1.crcID }

        let totalBodySize = combined.reduce(0) { $0 + $1.payload.count }
        var output = Data()

        if includeRAHeaderFlag {
            appendUInt32LE(&output, 0)
        }

        appendUInt16LE(&output, UInt16(clamping: combined.count))
        appendUInt32LE(&output, UInt32(clamping: totalBodySize))

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

        return (output, rebuiltEntries, duplicates)
    }

    static func batchExtract(entries: [MixEntry], to directoryURL: URL) throws -> Int {
        var usedNames = Set<String>()
        var count = 0
        for entry in entries {
            var filename = entry.suggestedFilename
            if usedNames.contains(filename) {
                filename = "\(entry.hexID)_\(count)_\(filename)"
            }
            usedNames.insert(filename)
            let destURL = directoryURL.appendingPathComponent(filename)
            try entry.payload.write(to: destURL, options: .atomic)
            count += 1
        }
        return count
    }

    static func westwoodCRC(filename: String) -> UInt32 {
        let upper = filename.uppercased()
        var bytes = Array(upper.utf8)
        while bytes.count % 4 != 0 { bytes.append(0) }
        var crc: UInt32 = 0
        var i = 0
        while i < bytes.count {
            let chunk = UInt32(bytes[i]) |
                        (UInt32(bytes[i + 1]) << 8) |
                        (UInt32(bytes[i + 2]) << 16) |
                        (UInt32(bytes[i + 3]) << 24)
            crc = ((crc << 1) | (crc >> 31)) &+ chunk
            i += 4
        }
        return crc
    }

    private static func readUInt16LE(_ data: Data, at offset: Int) -> UInt16 {
        UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    }

    private static func readUInt32LE(_ data: Data, at offset: Int) -> UInt32 {
        UInt32(data[offset]) |
        (UInt32(data[offset + 1]) << 8) |
        (UInt32(data[offset + 2]) << 16) |
        (UInt32(data[offset + 3]) << 24)
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

