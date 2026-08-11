import Darwin
import Foundation

public enum SecureFileIO {
    public static let maximumConfigurationSize = 64 * 1024

    public static func readConfiguration(
        at url: URL,
        expectedOwner: uid_t? = nil
    ) throws -> RoasterConfiguration {
        let data = try readRegularFile(
            at: url,
            expectedOwner: expectedOwner,
            rejectGroupOrOtherWritable: true,
            maximumSize: maximumConfigurationSize
        )
        return try JSONDecoder.roaster.decode(RoasterConfiguration.self, from: data).validated()
    }

    public static func readState(at url: URL) throws -> EnforcementState? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try readRegularFile(
            at: url,
            expectedOwner: 0,
            rejectGroupOrOtherWritable: true,
            maximumSize: maximumConfigurationSize
        )
        return try JSONDecoder.roaster.decode(EnforcementState.self, from: data)
    }

    public static func writeConfiguration(_ configuration: RoasterConfiguration, to url: URL) throws {
        let validated = try configuration.validated()
        let data = try JSONEncoder.roaster.encode(validated)
        try writeAtomically(data: data, to: url, mode: 0o600, owner: getuid(), group: getgid())
    }

    public static func readAdultBlocklist(
        at url: URL,
        expectedOwner: uid_t
    ) throws -> [String] {
        let data = try readRegularFile(
            at: url,
            expectedOwner: expectedOwner,
            rejectGroupOrOtherWritable: true,
            maximumSize: 16 * 1024 * 1024
        )
        return try AdultBlocklistParser.parseSerialized(data)
    }

    public static func writeSystemAdultBlocklist(_ domains: [String], to url: URL) throws {
        guard geteuid() == 0 else {
            throw RoasterError.unsafeFile("Writing the system blocklist requires root.")
        }
        let data = try AdultBlocklistParser.serialize(domains)
        try writeAtomically(data: data, to: url, mode: 0o600, owner: 0, group: 0)
    }

    public static func writeAdultBlocklist(_ domains: [String], to url: URL) throws {
        let data = try AdultBlocklistParser.serialize(domains)
        try writeAtomically(data: data, to: url, mode: 0o600, owner: getuid(), group: getgid())
    }

    public static func writeAdultBlocklistMetadata(_ metadata: AdultBlocklistMetadata, to url: URL) throws {
        let data = try JSONEncoder.roaster.encode(metadata)
        try writeAtomically(data: data, to: url, mode: 0o600, owner: getuid(), group: getgid())
    }

    public static func readAdultBlocklistMetadata(at url: URL) throws -> AdultBlocklistMetadata? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try readRegularFile(
            at: url,
            expectedOwner: getuid(),
            rejectGroupOrOtherWritable: true,
            maximumSize: maximumConfigurationSize
        )
        return try JSONDecoder.roaster.decode(AdultBlocklistMetadata.self, from: data)
    }

    public static func writeState(_ state: EnforcementState, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o755]
        )
        guard chmod(url.deletingLastPathComponent().path, 0o755) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let data = try JSONEncoder.roaster.encode(state)
        try writeAtomically(data: data, to: url, mode: 0o600, owner: 0, group: 0)
    }

    public static func removeState(at url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        var fileStat = stat()
        guard lstat(url.path, &fileStat) == 0,
              (fileStat.st_mode & S_IFMT) == S_IFREG,
              fileStat.st_uid == 0 else {
            throw RoasterError.unsafeFile("Refusing to remove an unsafe state path: \(url.path)")
        }
        guard unlink(url.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    public static func removeRegularFile(at url: URL, expectedOwner: uid_t) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        var fileStat = stat()
        guard lstat(url.path, &fileStat) == 0,
              (fileStat.st_mode & S_IFMT) == S_IFREG,
              fileStat.st_uid == expectedOwner else {
            throw RoasterError.unsafeFile("Refusing to remove an unsafe path: \(url.path)")
        }
        guard unlink(url.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    public static func managedHostsDomains(at url: URL, expectedOwner: uid_t = 0) throws -> [String] {
        let existingData = try readRegularFile(
            at: url,
            expectedOwner: expectedOwner,
            rejectGroupOrOtherWritable: true,
            maximumSize: 16 * 1024 * 1024
        )
        guard let existing = String(data: existingData, encoding: .utf8) else {
            throw RoasterError.unsafeFile("The hosts file is not valid UTF-8; refusing to edit it.")
        }
        return try HostsFileEditor.managedDomains(in: existing)
    }

    public static func rewriteHosts(
        at url: URL,
        blockedDomains: [String],
        expectedOwner: uid_t = 0
    ) throws {
        let existingData = try readRegularFile(
            at: url,
            expectedOwner: expectedOwner,
            rejectGroupOrOtherWritable: true,
            maximumSize: 16 * 1024 * 1024
        )
        guard let existing = String(data: existingData, encoding: .utf8) else {
            throw RoasterError.unsafeFile("The hosts file is not valid UTF-8; refusing to edit it.")
        }
        let rendered = try HostsFileEditor.render(existing: existing, blockedDomains: blockedDomains)

        var fileStat = stat()
        guard lstat(url.path, &fileStat) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        try writeAtomically(
            data: Data(rendered.utf8),
            to: url,
            mode: mode_t(fileStat.st_mode & 0o777),
            owner: fileStat.st_uid,
            group: fileStat.st_gid
        )
    }

    private static func readRegularFile(
        at url: URL,
        expectedOwner: uid_t?,
        rejectGroupOrOtherWritable: Bool,
        maximumSize: Int
    ) throws -> Data {
        var fileStat = stat()
        guard lstat(url.path, &fileStat) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .ENOENT)
        }
        guard (fileStat.st_mode & S_IFMT) == S_IFREG else {
            throw RoasterError.unsafeFile("Refusing a non-regular file: \(url.path)")
        }
        if let expectedOwner, fileStat.st_uid != expectedOwner {
            throw RoasterError.unsafeFile("Unexpected owner for \(url.path).")
        }
        if rejectGroupOrOtherWritable, (fileStat.st_mode & 0o022) != 0 {
            throw RoasterError.unsafeFile("Refusing a group- or world-writable file: \(url.path)")
        }
        guard fileStat.st_size <= maximumSize else {
            throw RoasterError.configurationTooLarge
        }

        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { close(descriptor) }

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 8192)
        while true {
            let count = read(descriptor, &buffer, buffer.count)
            if count == 0 { break }
            guard count > 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            guard data.count + count <= maximumSize else {
                throw RoasterError.configurationTooLarge
            }
            data.append(buffer, count: count)
        }
        return data
    }

    private static func writeAtomically(
        data: Data,
        to url: URL,
        mode: mode_t,
        owner: uid_t,
        group: gid_t
    ) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        let temporaryURL = directory.appendingPathComponent(".\(url.lastPathComponent).roaster.\(getpid())")
        let descriptor = open(
            temporaryURL.path,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            mode
        )
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }

        do {
            try data.withUnsafeBytes { bytes in
                guard let baseAddress = bytes.baseAddress else { return }
                var written = 0
                while written < bytes.count {
                    let count = Darwin.write(
                        descriptor,
                        baseAddress.advanced(by: written),
                        bytes.count - written
                    )
                    guard count > 0 else {
                        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                    }
                    written += count
                }
            }
            guard fchmod(descriptor, mode) == 0,
                  fchown(descriptor, owner, group) == 0,
                  fsync(descriptor) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            guard close(descriptor) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            guard rename(temporaryURL.path, url.path) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        } catch {
            close(descriptor)
            unlink(temporaryURL.path)
            throw error
        }
    }
}

extension JSONEncoder {
    static var roaster: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}

extension JSONDecoder {
    static var roaster: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
