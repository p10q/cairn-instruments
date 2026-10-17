import CryptoKit
import Foundation

public enum InstrumentFailure: Error, LocalizedError {
    case invalidBank
    case invalidPreset
    case audio(Int32)
    case download

    public var errorDescription: String? {
        switch self {
        case .invalidBank: "Use a valid SoundFont (.sf2) file smaller than 512 MiB."
        case .invalidPreset: "This SoundFont preset is not supported."
        case .audio(let status): "The instrument could not be rendered (audio error \(status))."
        case .download: "The sound pack download could not be verified. Please retry."
        }
    }
}

public struct SoundFontPreset: Codable, Equatable, Hashable, Identifiable, Sendable {
    public let name: String
    public let program: UInt8
    public let bank: UInt16

    public var id: String { "\(bank):\(program)" }
    public var isDrumKit: Bool { bank == 128 }
    public var category: String {
        if isDrumKit { return "Drums" }
        let families = ["Piano", "Chromatic Percussion", "Organ", "Guitar", "Bass", "Strings",
                        "Ensemble", "Brass", "Reed", "Pipe", "Synth Lead", "Synth Pad",
                        "Synth Effects", "World", "Percussion", "Sound Effects"]
        return families[Int(program) / 8]
    }

    public init(name: String, program: UInt8, bank: UInt16) throws {
        guard !name.isEmpty, name.utf8.count <= 256, program < 128, bank <= 128 else {
            throw InstrumentFailure.invalidPreset
        }
        self.name = name
        self.program = program
        self.bank = bank
    }

    public func validate() throws {
        _ = try Self(name: name, program: program, bank: bank)
    }

    private enum CodingKeys: String, CodingKey {
        case name, program, bank
    }

    public init(from decoder: Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(name: fields.decode(String.self, forKey: .name),
                      program: fields.decode(UInt8.self, forKey: .program),
                      bank: fields.decode(UInt16.self, forKey: .bank))
    }
}

public struct SoundFontBank: Sendable {
    public let presets: [SoundFontPreset]
    public let name: String
    public static let maximumBytes = 512 * 1024 * 1024

    public init(url: URL) throws {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true, let size = values.fileSize,
              size >= 12, size <= Self.maximumBytes else { throw InstrumentFailure.invalidBank }
        try self.init(data: Data(contentsOf: url, options: .mappedIfSafe))
    }

    public static func cache(_ url: URL, directory: URL) throws -> URL {
        _ = try Self(url: url)
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let destination = directory.appendingPathComponent("\(hash).sf2")
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        let existing = try? Data(contentsOf: destination, options: .mappedIfSafe)
        if existing != data {
            try Task.checkCancellation()
            try data.write(to: destination, options: .atomic)
        }
        return destination
    }

    public init(data bytes: Data) throws {
        let data = Data(bytes)
        guard data.count >= 12, data.count <= Self.maximumBytes,
              Self.tag(data, at: 0) == "RIFF", Self.tag(data, at: 8) == "sfbk",
              Int(Self.uint32(data, at: 4)) + 8 == data.count else { throw InstrumentFailure.invalidBank }
        var header: Range<Int>?
        var bankName = "SoundFont"
        var cursor = 12
        while cursor < data.count {
            let chunk = try Self.chunk(data, at: cursor, end: data.count)
            if Self.tag(data, at: cursor) == "LIST", chunk.count >= 4,
               Self.tag(data, at: chunk.lowerBound) == "INFO" {
                var child = chunk.lowerBound + 4
                while child < chunk.upperBound {
                    let content = try Self.chunk(data, at: child, end: chunk.upperBound)
                    if Self.tag(data, at: child) == "INAM", content.count <= 256 {
                        let value = String(decoding: data[content].prefix { $0 != 0 }, as: UTF8.self)
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        if !value.isEmpty { bankName = value }
                    }
                    child = content.upperBound + content.count % 2
                }
            }
            if Self.tag(data, at: cursor) == "LIST", chunk.count >= 4,
               Self.tag(data, at: chunk.lowerBound) == "pdta" {
                var child = chunk.lowerBound + 4
                while child < chunk.upperBound {
                    let content = try Self.chunk(data, at: child, end: chunk.upperBound)
                    if Self.tag(data, at: child) == "phdr" {
                        guard header == nil else { throw InstrumentFailure.invalidBank }
                        header = content
                    }
                    child = content.upperBound + content.count % 2
                }
            }
            cursor = chunk.upperBound + chunk.count % 2
        }
        guard let header, header.count >= 76, header.count % 38 == 0,
              header.count / 38 <= 16_385,
              Self.name(data, at: header.upperBound - 38) == "EOP" else {
            throw InstrumentFailure.invalidBank
        }
        var presets: [SoundFontPreset] = []
        var identities = Set<String>()
        for offset in stride(from: header.lowerBound, to: header.upperBound - 38, by: 38) {
            let program = Self.uint16(data, at: offset + 20)
            let bank = Self.uint16(data, at: offset + 22)
            guard program < 128, bank <= 128 else { continue }
            let preset = try SoundFontPreset(name: Self.name(data, at: offset), program: UInt8(program), bank: bank)
            guard identities.insert(preset.id).inserted else { throw InstrumentFailure.invalidBank }
            presets.append(preset)
        }
        guard !presets.isEmpty else { throw InstrumentFailure.invalidBank }
        self.presets = presets.sorted {
            if $0.bank == $1.bank { return $0.program < $1.program }
            return $0.bank < $1.bank
        }
        name = bankName
    }

    private static func chunk(_ data: Data, at offset: Int, end: Int) throws -> Range<Int> {
        guard offset <= end - 8 else { throw InstrumentFailure.invalidBank }
        let start = offset + 8
        let size = Int(uint32(data, at: offset + 4))
        guard size <= end - start, start + size + size % 2 <= end else {
            throw InstrumentFailure.invalidBank
        }
        return start..<(start + size)
    }

    private static func tag(_ data: Data, at offset: Int) -> String {
        String(decoding: data[offset..<(offset + 4)], as: UTF8.self)
    }

    private static func name(_ data: Data, at offset: Int) -> String {
        String(decoding: data[offset..<(offset + 20)].prefix { $0 != 0 }, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func uint16(_ data: Data, at offset: Int) -> UInt16 {
        UInt16(data[offset]) | UInt16(data[offset + 1]) << 8
    }

    private static func uint32(_ data: Data, at offset: Int) -> UInt32 {
        UInt32(data[offset]) | UInt32(data[offset + 1]) << 8 |
            UInt32(data[offset + 2]) << 16 | UInt32(data[offset + 3]) << 24
    }
}
