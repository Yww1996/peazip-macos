import Foundation

/// Recovering filenames from ZIPs written on Chinese Windows.
///
/// Those zips store names in GBK while leaving the UTF-8 flag (0x800) clear. 7-Zip then
/// decodes them with the local code page, so the list shows mojibake ("Ҫǩҳ") and extracted
/// files land on disk with garbage names. The bytes themselves are intact in the central
/// directory, so the names are recoverable: parse the CD here and decode as GB18030 (a
/// superset of GBK) whenever an unflagged name is not valid UTF-8.
///
/// Only ZIP needs this. 7z and RAR store names as UTF-16 internally.
enum LegacyZipNames {

    /// Corrected names in central-directory order, or nil when nothing needed correcting.
    ///
    /// Order matters: the caller pairs these with the entries 7-Zip listed, and 7-Zip walks
    /// the CD in the same order. Pairing by name is impossible — the whole point is that
    /// 7-Zip's name is the broken one.
    static func correctedNames(in url: URL) -> [String]? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }

        // End of central directory: scan back over the (possibly long) archive comment.
        var eocd = -1
        var i = data.count - 22
        let floor = max(0, data.count - 65_558)
        while i >= floor {
            if u32(data, i) == 0x0605_4B50 { eocd = i; break }
            i -= 1
        }
        guard eocd >= 0 else { return nil }

        let count = Int(u16(data, eocd + 10))
        var off = Int(u32(data, eocd + 16))
        var names: [String] = []
        var corrected = false

        for _ in 0..<count {
            guard off + 46 <= data.count, u32(data, off) == 0x0201_4B50 else { return nil }
            let flag  = u16(data, off + 8)
            let nlen  = Int(u16(data, off + 28))
            let xlen  = Int(u16(data, off + 30))
            let clen  = Int(u16(data, off + 32))
            guard off + 46 + nlen <= data.count else { return nil }
            let raw = data.subdata(in: (off + 46)..<(off + 46 + nlen))

            let name: String
            if flag & 0x800 != 0 {
                name = String(data: raw, encoding: .utf8) ?? ""
            } else if let utf8 = String(data: raw, encoding: .utf8) {
                name = utf8                       // unflagged, but genuinely UTF-8 already
            } else {
                name = decodeGB18030(raw)
                corrected = true
            }
            names.append(name)
            off += 46 + nlen + xlen + clen
        }
        return corrected ? names : nil
    }

    /// CoreFoundation is the only Foundation route to GBK/GB18030.
    static func decodeGB18030(_ data: Data) -> String {
        let ns = CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))
        return String(data: data, encoding: String.Encoding(rawValue: ns))
            ?? String(decoding: data, as: UTF8.self)
    }

    private static func u16(_ d: Data, _ at: Int) -> UInt16 {
        guard at >= 0, at + 2 <= d.count else { return 0 }
        return d.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: at, as: UInt16.self) }
    }

    private static func u32(_ d: Data, _ at: Int) -> UInt32 {
        guard at >= 0, at + 4 <= d.count else { return 0 }
        return d.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: at, as: UInt32.self) }
    }
}
