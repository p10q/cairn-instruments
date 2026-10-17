import CryptoKit
import Foundation

public struct SoundPack: Sendable {
    public let id: String
    public let name: String
    public let author: String
    public let downloadURL: URL
    public let licenseURL: URL
    public let sha256: String
    public let bytes: Int

    public static let generalUserGS = SoundPack(
        id: "generaluser-gs-2.0.3", name: "GeneralUser GS", author: "S. Christian Collins",
        downloadURL: URL(string: "https://raw.githubusercontent.com/mrbumpy409/GeneralUser-GS/684543d5e5efaef08d02be50dcda8d552478fa60/GeneralUser-GS.sf2")!,
        licenseURL: URL(string: "https://github.com/mrbumpy409/GeneralUser-GS/blob/684543d5e5efaef08d02be50dcda8d552478fa60/documentation/LICENSE.txt")!,
        sha256: "9575028c7a1f589f5770fccc8cff2734566af40cd26ed836944e9a5152688cfe",
        bytes: 32_319_396
    )

    public init(id: String, name: String, author: String, downloadURL: URL,
                licenseURL: URL, sha256: String, bytes: Int) {
        self.id = id
        self.name = name
        self.author = author
        self.downloadURL = downloadURL
        self.licenseURL = licenseURL
        self.sha256 = sha256
        self.bytes = bytes
    }

    public func download(to directory: URL) async throws -> URL {
        guard downloadURL.scheme == "https", bytes > 0, bytes <= SoundFontBank.maximumBytes,
              sha256.count == 64, sha256.allSatisfy(\.isHexDigit) else { throw InstrumentFailure.download }
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent("\(sha256).sf2")
        if manager.fileExists(atPath: destination.path), (try? verify(destination)) != nil { return destination }
        var request = URLRequest(url: downloadURL)
        request.timeoutInterval = 90
        let (temporary, response) = try await URLSession.shared.download(for: request)
        defer { try? manager.removeItem(at: temporary) }
        guard let response = response as? HTTPURLResponse, response.statusCode == 200 else {
            throw InstrumentFailure.download
        }
        try Task.checkCancellation()
        try verify(temporary)
        _ = try SoundFontBank(url: temporary)
        let staging = directory.appendingPathComponent(".\(UUID().uuidString).sf2")
        defer { try? manager.removeItem(at: staging) }
        try manager.copyItem(at: temporary, to: staging)
        try Task.checkCancellation()
        if manager.fileExists(atPath: destination.path) {
            _ = try manager.replaceItemAt(destination, withItemAt: staging)
        } else {
            try manager.moveItem(at: staging, to: destination)
        }
        return destination
    }

    public func verify(_ url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true, values.fileSize == bytes else { throw InstrumentFailure.download }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard digest == sha256 else { throw InstrumentFailure.download }
    }
}
