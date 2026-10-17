import CairnInstruments
import Foundation
import XCTest

final class SoundFontTests: XCTestCase {
    func testListsPresetsAndGroupsDrumKits() throws {
        let bank = try SoundFontBank(data: fixture([("Piano", 0, 0), ("Violin", 40, 0), ("Kit", 0, 128)]))
        XCTAssertEqual(bank.presets.map(\.name), ["Piano", "Violin", "Kit"])
        XCTAssertEqual(bank.presets.map(\.category), ["Piano", "Strings", "Drums"])
        XCTAssertEqual(bank.presets.map(\.id), ["0:0", "0:40", "128:0"])
    }

    func testBankCanBeReadFromANonzeroBasedDataSlice() throws {
        let data = fixture([("Piano", 0, 0)])
        let prefixed = Data([255]) + data
        let bank = try SoundFontBank(data: prefixed.dropFirst())
        XCTAssertEqual(bank.presets.map(\.name), ["Piano"])
    }

    func testRejectsTruncatedChunksAndDuplicatePresets() throws {
        let valid = fixture([("Piano", 0, 0)])
        for count in 0..<valid.count {
            XCTAssertThrowsError(try SoundFontBank(data: valid.prefix(count)))
        }
        XCTAssertThrowsError(try SoundFontBank(data: fixture([("Piano", 0, 0), ("Other", 0, 0)])))
        XCTAssertThrowsError(try SoundFontBank(data: Data("not a soundfont".utf8)))
    }

    func testDecodingRejectsInvalidProgramBeforeCategoryAccess() throws {
        let data = Data(#"{"name":"Invalid","program":255,"bank":0}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(SoundFontPreset.self, from: data))
    }

    func testRealPackAndFrameAccurateRendering() throws {
        guard let path = ProcessInfo.processInfo.environment["CAIRN_TEST_SOUNDFONT"] else {
            throw XCTSkip("Set CAIRN_TEST_SOUNDFONT to GeneralUser-GS.sf2 to test native rendering.")
        }
        let url = URL(fileURLWithPath: path)
        try SoundPack.generalUserGS.verify(url)
        let bank = try SoundFontBank(url: url)
        XCTAssertEqual(bank.presets.count, 287)
        XCTAssertEqual(bank.presets.filter(\.isDrumKit).count, 13)
        let piano = try XCTUnwrap(bank.presets.first { $0.bank == 0 && $0.program == 0 })
        let violin = try XCTUnwrap(bank.presets.first { $0.bank == 0 && $0.program == 40 })
        let first = try render(url, preset: piano, quantum: 128)
        let second = try render(url, preset: piano, quantum: 512)
        let third = try render(url, preset: piano, quantum: 4096)
        XCTAssertEqual(first.prefix(512).max(), 0)
        XCTAssertGreaterThan(first.dropFirst(512).map { abs($0) }.max() ?? 0, 0.1)
        for rendered in [second, third] {
            XCTAssertEqual(rendered.firstIndex { abs($0) > 0.0001 }, first.firstIndex { abs($0) > 0.0001 })
            XCTAssertLessThan(zip(first, rendered).map { abs($0 - $1) }.max() ?? 1, 0.005)
        }
        let strings = try render(url, preset: violin, quantum: 512)
        XCTAssertGreaterThan(zip(first, strings).map { abs($0 - $1) }.max() ?? 0, 0.1)
        let kit = try XCTUnwrap(bank.presets.first(where: \.isDrumKit))
        XCTAssertGreaterThan(try render(url, preset: kit, quantum: 512).map { abs($0) }.max() ?? 0, 0.001)
    }

    func testDownloadVerifiesAndReusesThePack() async throws {
        guard ProcessInfo.processInfo.environment["CAIRN_TEST_DOWNLOAD"] == "1" else {
            throw XCTSkip("Set CAIRN_TEST_DOWNLOAD=1 to exercise the optional pack download.")
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let downloaded = try await SoundPack.generalUserGS.download(to: directory)
        XCTAssertEqual(try SoundFontBank(url: downloaded).presets.count, 287)
        let date = try downloaded.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        let reused = try await SoundPack.generalUserGS.download(to: directory)
        XCTAssertEqual(reused, downloaded)
        XCTAssertEqual(try downloaded.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, date)
        try Data("corrupt".utf8).write(to: downloaded)
        XCTAssertThrowsError(try SoundPack.generalUserGS.verify(downloaded))
    }

    private func render(_ url: URL, preset: SoundFontPreset, quantum: Int) throws -> [Float] {
        let renderer = try SoundFontRenderer(url: url, preset: preset)
        let left = UnsafeMutablePointer<Float>.allocate(capacity: quantum)
        let right = UnsafeMutablePointer<Float>.allocate(capacity: quantum)
        defer { left.deallocate(); right.deallocate() }
        var output: [Float] = []
        for frame in stride(from: 0, to: 8192, by: quantum) {
            if frame <= 512, frame + quantum > 512 {
                XCTAssertEqual(renderer.noteOn(pitch: 60, velocity: 100, offset: UInt32(512 - frame)), 0)
            }
            if frame <= 4096, frame + quantum > 4096 {
                XCTAssertEqual(renderer.noteOff(pitch: 60, offset: UInt32(4096 - frame)), 0)
            }
            XCTAssertEqual(renderer.render(left: left, right: right, count: UInt32(quantum)), 0)
            output.append(contentsOf: UnsafeBufferPointer(start: left, count: quantum))
        }
        return output
    }

    private func fixture(_ presets: [(String, UInt16, UInt16)]) -> Data {
        var headers = Data()
        for (name, program, bank) in presets + [("EOP", 0, 0)] {
            var bytes = Array(name.utf8.prefix(20))
            bytes.append(contentsOf: repeatElement(0, count: 20 - bytes.count))
            headers.append(contentsOf: bytes)
            headers.append(contentsOf: [UInt8(program & 255), UInt8(program >> 8), UInt8(bank & 255), UInt8(bank >> 8)])
            headers.append(contentsOf: repeatElement(0, count: 14))
        }
        let list = chunk("LIST", Data("pdta".utf8) + chunk("phdr", headers))
        return chunk("RIFF", Data("sfbk".utf8) + list)
    }

    private func chunk(_ tag: String, _ content: Data) -> Data {
        let size = UInt32(content.count)
        var output = Data(tag.utf8)
        output.append(contentsOf: [UInt8(size & 255), UInt8((size >> 8) & 255),
                                   UInt8((size >> 16) & 255), UInt8(size >> 24)])
        output.append(content)
        if content.count % 2 != 0 { output.append(0) }
        return output
    }
}
