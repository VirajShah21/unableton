import Foundation

enum SoundFontLocator {
    static func url(named name: String) throws -> URL {
        throw AudioError.missingSoundFont(name)
    }
    static func firstPreset(in url: URL) throws -> (UInt8, UInt16) {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        func u16(_ at: Int) -> UInt16 { UInt16(data[at]) | UInt16(data[at + 1]) << 8 }
        func u32(_ at: Int) -> Int { Int(data[at]) | Int(data[at + 1]) << 8 | Int(data[at + 2]) << 16 | Int(data[at + 3]) << 24 }
        var offset = 12
        while offset + 12 <= data.count {
            let size = u32(offset + 4)
            guard size >= 0, offset + 8 + size <= data.count else { break }
            if String(data: data[offset..<offset + 4], encoding: .ascii) == "LIST", String(data: data[offset + 8..<offset + 12], encoding: .ascii) == "pdta" {
                var child = offset + 12
                while child + 8 <= offset + 8 + size {
                    let length = u32(child + 4)
                    guard length >= 0, child + 8 + length <= data.count else { break }
                    if String(data: data[child..<child + 4], encoding: .ascii) == "phdr", length >= 38 {
                        return (UInt8(clamping: u16(child + 28)), u16(child + 30))
                    }
                    child += 8 + length + length % 2
                }
            }
            offset += 8 + size + size % 2
        }
        throw AudioError.unreadableAudio("\(url.lastPathComponent) is not a readable SoundFont bank.")
    }
}
