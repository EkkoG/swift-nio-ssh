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

import NIOCore
import NIOSSH

public final class SFTPClient: @unchecked Sendable {
    public let channel: Channel

    private let handler: SFTPClientHandler

    private init(channel: Channel, handler: SFTPClientHandler) {
        self.channel = channel
        self.handler = handler
    }

    public static func start(on channel: Channel) -> EventLoopFuture<SFTPClient> {
        let handler = SFTPClientHandler(loop: channel.eventLoop, allocator: channel.allocator)
        return channel.pipeline.addHandler(handler).flatMap {
            handler.startupFuture.map {
                SFTPClient(channel: channel, handler: handler)
            }
        }
    }

    public static func openChannel(with sshHandler: NIOSSHHandler, on channel: Channel) -> EventLoopFuture<SFTPClient> {
        let sftpPromise = channel.eventLoop.makePromise(of: SFTPClient.self)

        channel.eventLoop.execute {
            sshHandler.createChannel(nil, channelType: .session) { childChannel, channelType in
                guard channelType == .session else {
                    return childChannel.eventLoop.makeFailedFuture(SFTPError.invalidChannelType)
                }

                let handler = SFTPClientHandler(loop: childChannel.eventLoop, allocator: childChannel.allocator)
                let client = SFTPClient(channel: childChannel, handler: handler)
                sftpPromise.completeWith(handler.startupFuture.map { client })

                return childChannel.pipeline.addHandler(handler).flatMapError { error in
                    sftpPromise.fail(error)
                    return childChannel.eventLoop.makeFailedFuture(error)
                }
            }
        }

        return sftpPromise.futureResult
    }

    public func send(_ message: SFTPRequestMessage) -> EventLoopFuture<SFTPResponseMessage> {
        let promise = self.channel.eventLoop.makePromise(of: SFTPResponseMessage.self)
        self.channel.eventLoop.execute {
            promise.completeWith(self.handler.send(message))
        }
        return promise.futureResult
    }

    public func openFile(
        path: String,
        flags: SFTPOpenFlags,
        attributes: SFTPAttributes = .init()
    ) -> EventLoopFuture<SFTPFileHandle> {
        self.send(.open(path: path, pflags: flags, attributes: attributes)).flatMapThrowing { response in
            switch response {
            case .handle(let handle):
                return .init(bytes: handle)
            case .status(let status):
                throw SFTPError.status(status)
            default:
                throw SFTPError.unexpectedResponse("OPEN expected HANDLE or STATUS")
            }
        }
    }

    public func closeFile(_ handle: SFTPFileHandle) -> EventLoopFuture<Void> {
        self.closeHandle(handle.bytes)
    }

    public func closeDirectory(_ handle: SFTPDirectoryHandle) -> EventLoopFuture<Void> {
        self.closeHandle(handle.bytes)
    }

    public func read(file: SFTPFileHandle, offset: UInt64, length: UInt32) -> EventLoopFuture<ByteBuffer?> {
        self.send(.read(handle: file.bytes, offset: offset, length: length)).flatMapThrowing { response in
            switch response {
            case .data(let bytes):
                var buffer = self.channel.allocator.buffer(capacity: bytes.count)
                buffer.writeBytes(bytes)
                return buffer
            case .status(let status) where status.code == .eof:
                return nil
            case .status(let status):
                throw SFTPError.status(status)
            default:
                throw SFTPError.unexpectedResponse("READ expected DATA or STATUS")
            }
        }
    }

    public func write(file: SFTPFileHandle, offset: UInt64, data: ByteBuffer) -> EventLoopFuture<Void> {
        self.writeHandle(file.bytes, offset: offset, data: Array(data.readableBytesView))
    }

    public func openDirectory(path: String) -> EventLoopFuture<SFTPDirectoryHandle> {
        self.send(.opendir(path: path)).flatMapThrowing { response in
            switch response {
            case .handle(let handle):
                return .init(bytes: handle)
            case .status(let status):
                throw SFTPError.status(status)
            default:
                throw SFTPError.unexpectedResponse("OPENDIR expected HANDLE or STATUS")
            }
        }
    }

    public func readDirectoryBatch(_ handle: SFTPDirectoryHandle) -> EventLoopFuture<[SFTPNameEntry]?> {
        self.send(.readdir(handle: handle.bytes)).flatMapThrowing { response in
            switch response {
            case .name(let entries):
                return entries
            case .status(let status) where status.code == .eof:
                return nil
            case .status(let status):
                throw SFTPError.status(status)
            default:
                throw SFTPError.unexpectedResponse("READDIR expected NAME or STATUS")
            }
        }
    }

    public func stat(path: String) -> EventLoopFuture<SFTPAttributes> {
        self.attributes(for: .stat(path: path), operation: "STAT")
    }

    public func lstat(path: String) -> EventLoopFuture<SFTPAttributes> {
        self.attributes(for: .lstat(path: path), operation: "LSTAT")
    }

    public func fstat(file: SFTPFileHandle) -> EventLoopFuture<SFTPAttributes> {
        self.attributes(for: .fstat(handle: file.bytes), operation: "FSTAT")
    }

    public func setstat(path: String, attributes: SFTPAttributes) -> EventLoopFuture<Void> {
        self.statusOnly(.setstat(path: path, attributes: attributes), operation: "SETSTAT")
    }

    public func fsetstat(file: SFTPFileHandle, attributes: SFTPAttributes) -> EventLoopFuture<Void> {
        self.statusOnly(.fsetstat(handle: file.bytes, attributes: attributes), operation: "FSETSTAT")
    }

    public func remove(path: String) -> EventLoopFuture<Void> {
        self.statusOnly(.remove(path: path), operation: "REMOVE")
    }

    public func mkdir(path: String, attributes: SFTPAttributes = .init()) -> EventLoopFuture<Void> {
        self.statusOnly(.mkdir(path: path, attributes: attributes), operation: "MKDIR")
    }

    public func rmdir(path: String) -> EventLoopFuture<Void> {
        self.statusOnly(.rmdir(path: path), operation: "RMDIR")
    }

    public func realpath(_ path: String) -> EventLoopFuture<String> {
        self.send(.realpath(path: path)).flatMapThrowing { response in
            switch response {
            case .name(let entries):
                guard let first = entries.first else {
                    throw SFTPError.unexpectedResponse("REALPATH returned no entries")
                }
                return first.filename
            case .status(let status):
                throw SFTPError.status(status)
            default:
                throw SFTPError.unexpectedResponse("REALPATH expected NAME or STATUS")
            }
        }
    }

    public func rename(from oldPath: String, to newPath: String) -> EventLoopFuture<Void> {
        self.statusOnly(.rename(oldPath: oldPath, newPath: newPath), operation: "RENAME")
    }

    public func readlink(path: String) -> EventLoopFuture<String> {
        self.send(.readlink(path: path)).flatMapThrowing { response in
            switch response {
            case .name(let entries):
                guard let first = entries.first else {
                    throw SFTPError.unexpectedResponse("READLINK returned no entries")
                }
                return first.filename
            case .status(let status):
                throw SFTPError.status(status)
            default:
                throw SFTPError.unexpectedResponse("READLINK expected NAME or STATUS")
            }
        }
    }

    public func symlink(linkPath: String, targetPath: String) -> EventLoopFuture<Void> {
        self.statusOnly(.symlink(linkPath: linkPath, targetPath: targetPath), operation: "SYMLINK")
    }

    private func closeHandle(_ handle: [UInt8]) -> EventLoopFuture<Void> {
        self.statusOnly(.close(handle: handle), operation: "CLOSE")
    }

    private func writeHandle(_ handle: [UInt8], offset: UInt64, data: [UInt8]) -> EventLoopFuture<Void> {
        self.statusOnly(.write(handle: handle, offset: offset, data: data), operation: "WRITE")
    }

    private func attributes(for request: SFTPRequestMessage, operation: String) -> EventLoopFuture<SFTPAttributes> {
        self.send(request).flatMapThrowing { response in
            switch response {
            case .attributes(let attributes):
                return attributes
            case .status(let status):
                throw SFTPError.status(status)
            default:
                throw SFTPError.unexpectedResponse("\(operation) expected ATTRS or STATUS")
            }
        }
    }

    private func statusOnly(_ request: SFTPRequestMessage, operation: String) -> EventLoopFuture<Void> {
        self.send(request).flatMapThrowing { response in
            switch response {
            case .status(let status) where status.code == .ok:
                return ()
            case .status(let status):
                throw SFTPError.status(status)
            default:
                throw SFTPError.unexpectedResponse("\(operation) expected STATUS")
            }
        }
    }
}
