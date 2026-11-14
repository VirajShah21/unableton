import Foundation

/// A self-contained SoundFont built from an original sine wave. It exercises the
/// production AVAudioUnitSampler path without a download or third-party assets.
enum SoundFontFixture {
    static func write(to url: URL, program: UInt16 = 0, bank: UInt16 = 0) throws {
        func u16(_ value: UInt16) -> Data { Data([UInt8(truncatingIfNeeded: value), UInt8(truncatingIfNeeded: value >> 8)]) }
        func u32(_ value: UInt32) -> Data { u16(UInt16(truncatingIfNeeded: value)) + u16(UInt16(truncatingIfNeeded: value >> 16)) }
        func name(_ value: String) -> Data { let bytes = Data(value.utf8.prefix(19)); return bytes + Data(repeating: 0, count: 20 - bytes.count) }
        func chunk(_ id: String, _ body: Data) -> Data {
            Data(id.utf8) + u32(UInt32(body.count)) + body + (body.count.isMultiple(of: 2) ? Data() : Data([0]))
        }
        func list(_ id: String, _ body: Data) -> Data { chunk("LIST", Data(id.utf8) + body) }
        func phdr(_ label: String, _ preset: UInt16, _ bankNumber: UInt16, _ bag: UInt16) -> Data {
            name(label) + u16(preset) + u16(bankNumber) + u16(bag) + Data(repeating: 0, count: 12)
        }
        func generator(_ operation: UInt16, _ amount: Int16) -> Data { u16(operation) + u16(UInt16(bitPattern: amount)) }
        func shdr(_ label: String, start: UInt32, end: UInt32, loopStart: UInt32, loopEnd: UInt32) -> Data {
            name(label) + u32(start) + u32(end) + u32(loopStart) + u32(loopEnd) + u32(48_000) + Data([69, 0]) + u16(0) + u16(1)
        }
        let count = 4800
        var samples = Data()
        for frame in 0..<count {
            let sample = Int16((sin(Double(frame) * 2 * .pi * 440 / 48_000) * 16_000).rounded())
            samples += u16(UInt16(bitPattern: sample))
        }
        samples += Data(repeating: 0, count: 46 * 2)
        let info = list("INFO", chunk("ifil", u16(2) + u16(1)) + chunk("isng", Data("EMU8000\0".utf8)) + chunk("INAM", Data("Unableton test fixture\0".utf8)))
        let sampleData = list("sdta", chunk("smpl", samples))
        let headers = chunk("phdr", phdr("Fixture", program, bank, 0) + phdr("EOP", 0, 0, 1))
        let presetBags = chunk("pbag", u16(0) + u16(0) + u16(1) + u16(0))
        let presetMods = chunk("pmod", Data(repeating: 0, count: 10))
        let presetGenerators = chunk("pgen", generator(41, 0) + generator(0, 0))
        let instruments = chunk("inst", name("Fixture oscillator") + u16(0) + name("EOI") + u16(1))
        let instrumentBags = chunk("ibag", u16(0) + u16(0) + u16(5) + u16(0))
        let instrumentMods = chunk("imod", Data(repeating: 0, count: 10))
        // sampleID is the final generator in its zone, as required by SF2.
        let instrumentGenerators = chunk("igen", generator(34, -12_000) + generator(38, -12_000) + generator(54, 1) + generator(58, 69) + generator(53, 0) + generator(0, 0))
        let sampleHeaders = chunk("shdr", shdr("Sine", start: 0, end: UInt32(count), loopStart: 0, loopEnd: UInt32(count)) + shdr("EOS", start: UInt32(count), end: UInt32(count), loopStart: UInt32(count), loopEnd: UInt32(count)))
        let presetData = list("pdta", headers + presetBags + presetMods + presetGenerators + instruments + instrumentBags + instrumentMods + instrumentGenerators + sampleHeaders)
        try chunk("RIFF", Data("sfbk".utf8) + info + sampleData + presetData).write(to: url)
    }
}
