//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2026 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import Foundation
import NIOCore
import NIOPosix
import NIOSFTP
import NIOSSH

enum DemoError: Error, CustomStringConvertible {
    case missingEnv(String)
    case invalidPort(String)
    case assertionFailed(String)

    var description: String {
        switch self {
        case .missingEnv(let name):
            return "Missing required environment variable \(name)"
        case .invalidPort(let value):
            return "Invalid SFTP_TEST_PORT value \(value)"
        case .assertionFailed(let message):
            return "Assertion failed: \(message)"
        }
    }
}

final class AcceptAllHostKeysDelegate: NIOSSHClientServerAuthenticationDelegate {
    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        validationCompletePromise.succeed(())
    }
}

final class PasswordAuthDelegate: NIOSSHClientUserAuthenticationDelegate {
    private let username: String
    private let password: String
    private var attempted = false

    init(username: String, password: String) {
        self.username = username
        self.password = password
    }

    func nextAuthenticationType(
        availableMethods: NIOSSHAvailableUserAuthenticationMethods,
        nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
    ) {
        guard !self.attempted, availableMethods.contains(.password) else {
            nextChallengePromise.succeed(nil)
            return
        }

        self.attempted = true
        nextChallengePromise.succeed(
            .init(
                username: self.username,
                serviceName: "ssh-connection",
                offer: .password(.init(password: self.password))
            )
        )
    }
}

struct DemoConfig {
    let host: String
    let port: Int
    let user: String
    let password: String
    let root: String
    let keyPath: String?
}

struct OperationResult {
    let name: String
    let detail: String
}

func requireEnv(_ name: String) throws -> String {
    guard let value = ProcessInfo.processInfo.environment[name], !value.isEmpty else {
        throw DemoError.missingEnv(name)
    }
    return value
}

func loadConfig() throws -> DemoConfig {
    let host = try requireEnv("SFTP_TEST_HOST")
    let user = try requireEnv("SFTP_TEST_USER")
    let password = try requireEnv("SFTP_TEST_PASSWORD")
    let root = try requireEnv("SFTP_TEST_ROOT")
    let portString = ProcessInfo.processInfo.environment["SFTP_TEST_PORT"] ?? "22"

    guard let port = Int(portString) else {
        throw DemoError.invalidPort(portString)
    }

    let keyPath = ProcessInfo.processInfo.environment["SFTP_TEST_KEY_PATH"]

    return .init(host: host, port: port, user: user, password: password, root: root, keyPath: keyPath)
}

func assertCondition(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else {
        throw DemoError.assertionFailed(message)
    }
}

func permissionBits(_ value: UInt32?) -> UInt32? {
    value.map { $0 & 0o7777 }
}

func fileTypeBits(_ value: UInt32?) -> UInt32? {
    value.map { $0 & 0o170000 }
}

func string(from buffer: ByteBuffer?) -> String? {
    buffer.map(String.init(buffer:))
}

func exactBuffer(_ string: String) -> ByteBuffer {
    ByteBuffer(string: string)
}

func status(from error: Error) -> SFTPStatus? {
    guard case .status(let status) = error as? SFTPError else {
        return nil
    }
    return status
}

func isMissingStatus(_ status: SFTPStatus) -> Bool {
    switch status.code {
    case .noSuchFile:
        return true
    case .failure:
        let lowercased = status.message.lowercased()
        return lowercased.contains("no such file") || lowercased.contains("not found")
    default:
        return false
    }
}

func expectFailure(
    _ name: String,
    matching description: String,
    operation: () throws -> Void
) throws -> String {
    do {
        try operation()
        throw DemoError.assertionFailed("\(name) unexpectedly succeeded")
    } catch let demoError as DemoError {
        throw demoError
    } catch {
        try assertCondition(description.isEmpty || String(describing: error).lowercased().contains(description.lowercased()), "\(name) failed with unexpected error: \(error)")
        return String(describing: error)
    }
}

func expectMissing(
    _ sftp: SFTPClient,
    path: String,
    operationName: String
) throws -> String {
    do {
        _ = try sftp.stat(path: path).wait()
        throw DemoError.assertionFailed("\(operationName) expected missing path at \(path)")
    } catch let demoError as DemoError {
        throw demoError
    } catch {
        guard let sftpStatus = status(from: error), isMissingStatus(sftpStatus) else {
            throw DemoError.assertionFailed("\(operationName) expected missing-path error, got \(error)")
        }
        _ = try expectFailure("\(operationName) lstat missing", matching: "") {
            _ = try sftp.lstat(path: path).wait()
        }
        return "\(sftpStatus.code): \(sftpStatus.message)"
    }
}

func collectDirectoryEntries(_ sftp: SFTPClient, handle: SFTPDirectoryHandle) throws -> [SFTPNameEntry] {
    var entries: [SFTPNameEntry] = []
    while let batch = try sftp.readDirectoryBatch(handle).wait() {
        entries.append(contentsOf: batch)
    }
    return entries
}

func runSFTPCli(config: DemoConfig, commands: [String]) throws -> String {
    guard let keyPath = config.keyPath, !keyPath.isEmpty else {
        throw DemoError.missingEnv("SFTP_TEST_KEY_PATH")
    }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/sftp")
    process.arguments = [
        "-i", keyPath,
        "-P", String(config.port),
        "-b", "-",
        "\(config.user)@\(config.host)",
    ]

    let outputPipe = Pipe()
    let errorPipe = Pipe()
    let inputPipe = Pipe()
    process.standardOutput = outputPipe
    process.standardError = errorPipe
    process.standardInput = inputPipe

    try process.run()
    let batch = commands.joined(separator: "\n") + "\n"
    inputPipe.fileHandleForWriting.write(Data(batch.utf8))
    try inputPipe.fileHandleForWriting.close()
    process.waitUntilExit()

    let stdout = String(decoding: outputPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    let stderr = String(decoding: errorPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    let combined = [stdout, stderr].filter { !$0.isEmpty }.joined(separator: "\n")

    guard process.terminationStatus == 0 else {
        throw DemoError.assertionFailed("sftp CLI failed for commands \(commands): \(combined)")
    }

    return combined
}

@main
struct NIOSFTPWhiteboxDemo {
    static func main() throws {
        let config = try loadConfig()
        let timestamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let sanitizedRoot = config.root.hasSuffix("/") ? String(config.root.dropLast()) : config.root
        let basePath = "\(sanitizedRoot)/swift-nio-ssh-whitebox-\(timestamp)"
        let nestedDirectory = "\(basePath)/nested"
        let filePath = "\(nestedDirectory)/payload.txt"
        let renamedFilePath = "\(nestedDirectory)/payload-renamed.txt"
        let conflictingFilePath = "\(nestedDirectory)/already-there.txt"
        let symlinkPath = "\(basePath)/payload-link"

        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer {
            try? group.syncShutdownGracefully()
        }

        let bootstrap = ClientBootstrap(group: group)
            .channelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandler(
                        NIOSSHHandler(
                            role: .client(
                                .init(
                                    userAuthDelegate: PasswordAuthDelegate(username: config.user, password: config.password),
                                    serverAuthDelegate: AcceptAllHostKeysDelegate()
                                )
                            ),
                            allocator: channel.allocator,
                            inboundChildChannelInitializer: nil
                        )
                    )
                }
            }
            .channelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
            .channelOption(ChannelOptions.socket(SocketOptionLevel(IPPROTO_TCP), TCP_NODELAY), value: 1)

        let channel = try bootstrap.connect(host: config.host, port: config.port).wait()
        defer {
            try? channel.close().wait()
        }

        let sshHandler = try channel.pipeline.handler(type: NIOSSHHandler.self).wait()
        let sftp = try SFTPClient.openChannel(with: sshHandler, on: channel).wait()

        var results: [OperationResult] = []
        var createdBaseDirectory = false
        var createdNestedDirectory = false
        var createdFile = false
        var createdSymlink = false

        defer {
            if createdSymlink {
                try? sftp.remove(path: symlinkPath).wait()
            }
            if createdFile {
                try? sftp.remove(path: renamedFilePath).wait()
                try? sftp.remove(path: filePath).wait()
            }
            if createdNestedDirectory {
                try? sftp.rmdir(path: nestedDirectory).wait()
            }
            if createdBaseDirectory {
                try? sftp.rmdir(path: basePath).wait()
            }
        }

        let canonicalRoot = try sftp.realpath(config.root).wait()
        results.append(.init(name: "REALPATH", detail: canonicalRoot))

        try sftp.mkdir(path: basePath).wait()
        createdBaseDirectory = true
        results.append(.init(name: "MKDIR", detail: basePath))

        try sftp.mkdir(path: nestedDirectory, attributes: .init(permissions: 0o755)).wait()
        createdNestedDirectory = true
        results.append(.init(name: "MKDIR nested", detail: nestedDirectory))

        let baseAttributes = try sftp.stat(path: basePath).wait()
        results.append(.init(name: "STAT dir", detail: "perms=\(baseAttributes.permissions.map { String($0, radix: 8) } ?? "nil")"))
        let nestedLstat = try sftp.lstat(path: nestedDirectory).wait()
        results.append(.init(name: "LSTAT dir", detail: "perms=\(nestedLstat.permissions.map { String($0, radix: 8) } ?? "nil")"))

        let initialPrefix = "hello "
        let suffixPayload = "nio sftp"
        let finalPayload = initialPrefix + suffixPayload
        let fileHandle = try sftp.openFile(path: filePath, flags: [.create, .write, .read, .truncate]).wait()
        createdFile = true
        results.append(.init(name: "OPEN create", detail: filePath))

        try sftp.write(file: fileHandle, offset: 0, data: exactBuffer(initialPrefix)).wait()
        try sftp.write(file: fileHandle, offset: UInt64(initialPrefix.utf8.count), data: exactBuffer(suffixPayload)).wait()
        results.append(.init(name: "WRITE", detail: finalPayload))

        let fileAttributes = try sftp.fstat(file: fileHandle).wait()
        try assertCondition(fileAttributes.size == UInt64(finalPayload.utf8.count), "FSTAT size mismatch after write")
        results.append(.init(name: "FSTAT", detail: "size=\(fileAttributes.size.map(String.init) ?? "nil")"))

        try sftp.fsetstat(file: fileHandle, attributes: .init(permissions: 0o640)).wait()
        results.append(.init(name: "FSETSTAT", detail: "perms=640"))

        let readPrefix = try sftp.read(file: fileHandle, offset: 0, length: 5).wait()
        try assertCondition(string(from: readPrefix) == "hello", "READ prefix mismatch")
        results.append(.init(name: "READ prefix", detail: string(from: readPrefix) ?? "nil"))

        let readCrossBoundary = try sftp.read(file: fileHandle, offset: 4, length: 6).wait()
        try assertCondition(string(from: readCrossBoundary) == "o nio ", "READ cross-boundary mismatch")
        results.append(.init(name: "READ cross", detail: string(from: readCrossBoundary) ?? "nil"))

        let readFull = try sftp.read(file: fileHandle, offset: 0, length: 64).wait()
        try assertCondition(string(from: readFull) == finalPayload, "READ full mismatch")
        results.append(.init(name: "READ full", detail: string(from: readFull) ?? "nil"))

        let readEOF = try sftp.read(file: fileHandle, offset: 1024, length: 8).wait()
        try assertCondition(readEOF == nil, "READ EOF should be nil")
        results.append(.init(name: "READ EOF", detail: "nil"))

        try sftp.closeFile(fileHandle).wait()
        results.append(.init(name: "CLOSE file", detail: filePath))

        let pathStat = try sftp.stat(path: filePath).wait()
        try assertCondition(permissionBits(pathStat.permissions) == 0o640, "STAT permissions mismatch after FSETSTAT")
        try assertCondition(fileTypeBits(pathStat.permissions) == 0o100000, "STAT file type mismatch")
        results.append(.init(name: "STAT file", detail: "size=\(pathStat.size.map(String.init) ?? "nil") perms=\(pathStat.permissions.map { String($0, radix: 8) } ?? "nil")"))

        try sftp.setstat(path: filePath, attributes: .init(permissions: 0o600)).wait()
        let updatedLstat = try sftp.lstat(path: filePath).wait()
        try assertCondition(permissionBits(updatedLstat.permissions) == 0o600, "LSTAT permissions mismatch after SETSTAT")
        try assertCondition(fileTypeBits(updatedLstat.permissions) == 0o100000, "LSTAT file type mismatch")
        results.append(.init(name: "SETSTAT/LSTAT file", detail: "perms=\(updatedLstat.permissions.map { String($0, radix: 8) } ?? "nil")"))

        let duplicateMkdirError = try expectFailure("MKDIR duplicate", matching: "") {
            try sftp.mkdir(path: nestedDirectory).wait()
        }
        results.append(.init(name: "MKDIR duplicate", detail: duplicateMkdirError))

        let missingOpenError = try expectFailure("OPEN missing", matching: "") {
            _ = try sftp.openFile(path: "\(nestedDirectory)/missing.txt", flags: [.read]).wait()
        }
        results.append(.init(name: "OPEN missing", detail: missingOpenError))

        let nonEmptyRmdirError = try expectFailure("RMDIR non-empty", matching: "") {
            try sftp.rmdir(path: nestedDirectory).wait()
        }
        results.append(.init(name: "RMDIR non-empty", detail: nonEmptyRmdirError))

        let directoryHandle = try sftp.openDirectory(path: nestedDirectory).wait()
        results.append(.init(name: "OPENDIR", detail: nestedDirectory))
        let directoryEntries = try collectDirectoryEntries(sftp, handle: directoryHandle)
        let payloadMatches = directoryEntries.filter { $0.filename == "payload.txt" }
        try assertCondition(payloadMatches.count == 1, "READDIR expected payload.txt exactly once")
        results.append(.init(name: "READDIR", detail: directoryEntries.map(\.filename).sorted().joined(separator: ",")))
        let directoryEOF = try sftp.readDirectoryBatch(directoryHandle).wait()
        try assertCondition(directoryEOF == nil, "READDIR extra batch after EOF should be nil")
        results.append(.init(name: "READDIR EOF", detail: "nil"))
        try sftp.closeDirectory(directoryHandle).wait()
        results.append(.init(name: "CLOSE dir", detail: nestedDirectory))

        try sftp.rename(from: filePath, to: renamedFilePath).wait()
        let renameOldMissing = try expectMissing(sftp, path: filePath, operationName: "RENAME old path")
        let renamedPathStat = try sftp.stat(path: renamedFilePath).wait()
        try assertCondition(permissionBits(renamedPathStat.permissions) == 0o600, "Renamed file permissions mismatch")
        results.append(.init(name: "RENAME", detail: "\(filePath) -> \(renamedFilePath)"))
        results.append(.init(name: "RENAME old path", detail: renameOldMissing))

        let renamedHandle = try sftp.openFile(path: renamedFilePath, flags: [.read]).wait()
        let renamedContents = try sftp.read(file: renamedHandle, offset: 0, length: 64).wait()
        try assertCondition(string(from: renamedContents) == finalPayload, "Renamed file content mismatch")
        results.append(.init(name: "OPEN renamed", detail: string(from: renamedContents) ?? "nil"))
        try sftp.closeFile(renamedHandle).wait()

        let conflictingHandle = try sftp.openFile(path: conflictingFilePath, flags: [.create, .write, .read, .truncate, .exclusive]).wait()
        try sftp.write(file: conflictingHandle, offset: 0, data: exactBuffer("occupied")).wait()
        try sftp.closeFile(conflictingHandle).wait()
        results.append(.init(name: "OPEN conflict", detail: conflictingFilePath))

        let renameConflictError = try expectFailure("RENAME existing destination", matching: "") {
            try sftp.rename(from: renamedFilePath, to: conflictingFilePath).wait()
        }
        let conflictContentsHandle = try sftp.openFile(path: conflictingFilePath, flags: [.read]).wait()
        let conflictContents = try sftp.read(file: conflictContentsHandle, offset: 0, length: 64).wait()
        try assertCondition(string(from: conflictContents) == "occupied", "Conflict file content changed after failed rename")
        try sftp.closeFile(conflictContentsHandle).wait()
        results.append(.init(name: "RENAME existing destination", detail: renameConflictError))

        do {
            try sftp.symlink(linkPath: symlinkPath, targetPath: renamedFilePath).wait()
            createdSymlink = true
            results.append(.init(name: "SYMLINK", detail: "\(symlinkPath) -> \(renamedFilePath)"))

            let linkTarget = try sftp.readlink(path: symlinkPath).wait()
            try assertCondition(linkTarget == renamedFilePath, "READLINK target mismatch")
            results.append(.init(name: "READLINK", detail: linkTarget))

            let symlinkStat = try sftp.lstat(path: symlinkPath).wait()
            try assertCondition(fileTypeBits(symlinkStat.permissions) == 0o120000, "LSTAT symlink type mismatch")
            results.append(
                .init(
                    name: "LSTAT symlink",
                    detail: "perms=\(symlinkStat.permissions.map { String($0, radix: 8) } ?? "nil")"
                )
            )

            let symlinkHandle = try sftp.openFile(path: symlinkPath, flags: [.read]).wait()
            let symlinkReadback = try sftp.read(file: symlinkHandle, offset: 0, length: 64).wait()
            try assertCondition(string(from: symlinkReadback) == finalPayload, "Opening symlink did not resolve target content")
            try sftp.closeFile(symlinkHandle).wait()
            results.append(.init(name: "OPEN symlink", detail: string(from: symlinkReadback) ?? "nil"))

            if config.keyPath != nil {
                let cliNestedListing = try runSFTPCli(
                    config: config,
                    commands: ["ls -la \(nestedDirectory)"]
                )
                try assertCondition(cliNestedListing.contains("payload-renamed.txt"), "CLI nested listing missing renamed file")
                results.append(.init(name: "CLI nested listing", detail: cliNestedListing.trimmingCharacters(in: .whitespacesAndNewlines)))
            }
        } catch {
            results.append(.init(name: "SYMLINK/READLINK", detail: "unsupported or failed: \(error)"))
        }

        try sftp.remove(path: renamedFilePath).wait()
        let removedFileCheck = try expectMissing(sftp, path: renamedFilePath, operationName: "REMOVE file")
        createdFile = false
        results.append(.init(name: "REMOVE file", detail: renamedFilePath))
        results.append(.init(name: "REMOVE file verify", detail: removedFileCheck))

        let removeMissingError = try expectFailure("REMOVE missing", matching: "") {
            try sftp.remove(path: renamedFilePath).wait()
        }
        results.append(.init(name: "REMOVE missing", detail: removeMissingError))

        try sftp.remove(path: conflictingFilePath).wait()
        results.append(.init(name: "REMOVE conflict", detail: conflictingFilePath))
        let removedConflictCheck = try expectMissing(sftp, path: conflictingFilePath, operationName: "REMOVE conflict")
        results.append(.init(name: "REMOVE conflict verify", detail: removedConflictCheck))

        if createdSymlink {
            try sftp.remove(path: symlinkPath).wait()
            let removedSymlinkCheck = try expectMissing(sftp, path: symlinkPath, operationName: "REMOVE symlink")
            createdSymlink = false
            results.append(.init(name: "REMOVE symlink", detail: symlinkPath))
            results.append(.init(name: "REMOVE symlink verify", detail: removedSymlinkCheck))
        }

        try sftp.rmdir(path: nestedDirectory).wait()
        let removedNestedCheck = try expectMissing(sftp, path: nestedDirectory, operationName: "RMDIR nested")
        createdNestedDirectory = false
        results.append(.init(name: "RMDIR nested", detail: nestedDirectory))
        results.append(.init(name: "RMDIR nested verify", detail: removedNestedCheck))

        try sftp.rmdir(path: basePath).wait()
        let removedBaseCheck = try expectMissing(sftp, path: basePath, operationName: "RMDIR base")
        createdBaseDirectory = false
        results.append(.init(name: "RMDIR base", detail: basePath))
        results.append(.init(name: "RMDIR base verify", detail: removedBaseCheck))

        if config.keyPath != nil {
            let cliRootListing = try runSFTPCli(
                config: config,
                commands: ["ls -la \(sanitizedRoot)"]
            )
            try assertCondition(!cliRootListing.contains("swift-nio-ssh-whitebox-\(timestamp)"), "CLI listing still shows cleaned test root")
            results.append(.init(name: "CLI cleanup listing", detail: "verified absence under \(sanitizedRoot)"))
        } else {
            results.append(.init(name: "CLI cross-check", detail: "skipped: SFTP_TEST_KEY_PATH not set"))
        }

        print("connected to \(config.host):\(config.port) as \(config.user)")
        print("root \(config.root) resolved to \(canonicalRoot)")
        for result in results {
            print("[\(result.name)] \(result.detail)")
        }
    }
}
