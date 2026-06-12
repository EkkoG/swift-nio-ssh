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

enum SFTPPacketType {
    static let `init`: UInt8 = 1
    static let version: UInt8 = 2
    static let open: UInt8 = 3
    static let close: UInt8 = 4
    static let read: UInt8 = 5
    static let write: UInt8 = 6
    static let lstat: UInt8 = 7
    static let fstat: UInt8 = 8
    static let setstat: UInt8 = 9
    static let fsetstat: UInt8 = 10
    static let opendir: UInt8 = 11
    static let readdir: UInt8 = 12
    static let remove: UInt8 = 13
    static let mkdir: UInt8 = 14
    static let rmdir: UInt8 = 15
    static let realpath: UInt8 = 16
    static let stat: UInt8 = 17
    static let rename: UInt8 = 18
    static let readlink: UInt8 = 19
    static let symlink: UInt8 = 20
    static let status: UInt8 = 101
    static let handle: UInt8 = 102
    static let data: UInt8 = 103
    static let name: UInt8 = 104
    static let attrs: UInt8 = 105
    static let extended: UInt8 = 200
    static let extendedReply: UInt8 = 201
}

enum SFTPInboundPacket: Equatable {
    case version(SFTPVersion, [SFTPExtension])
    case response(id: UInt32, SFTPResponseMessage)
}

enum SFTPInboundPacketParser {
    static func parse(type: UInt8, payload: ByteBuffer) throws -> SFTPInboundPacket {
        var payload = payload

        switch type {
        case SFTPPacketType.version:
            guard let version = payload.readInteger(as: UInt32.self) else {
                throw SFTPError.protocolViolation("Missing SFTP version field")
            }
            var extensions: [SFTPExtension] = []
            while payload.readableBytes > 0 {
                guard let name = payload.readSFTPString(), let data = payload.readSFTPStringBuffer() else {
                    throw SFTPError.protocolViolation("Invalid SFTP extension payload")
                }
                extensions.append(.init(name: name, data: Array(data.readableBytesView)))
            }
            return .version(.init(version), extensions)
        case SFTPPacketType.status:
            guard let id = payload.readInteger(as: UInt32.self),
                let codeRaw = payload.readInteger(as: UInt32.self),
                let message = payload.readSFTPString(),
                let languageTag = payload.readSFTPString()
            else {
                throw SFTPError.protocolViolation("Invalid STATUS packet")
            }
            return .response(id: id, .status(.init(code: .init(rawValue: codeRaw), message: message, languageTag: languageTag)))
        case SFTPPacketType.handle:
            guard let id = payload.readInteger(as: UInt32.self),
                let handle = payload.readSFTPStringBuffer()
            else {
                throw SFTPError.protocolViolation("Invalid HANDLE packet")
            }
            return .response(id: id, .handle(Array(handle.readableBytesView)))
        case SFTPPacketType.data:
            guard let id = payload.readInteger(as: UInt32.self),
                let data = payload.readSFTPStringBuffer()
            else {
                throw SFTPError.protocolViolation("Invalid DATA packet")
            }
            return .response(id: id, .data(Array(data.readableBytesView)))
        case SFTPPacketType.name:
            guard let id = payload.readInteger(as: UInt32.self),
                let count = payload.readInteger(as: UInt32.self)
            else {
                throw SFTPError.protocolViolation("Invalid NAME packet")
            }
            var entries: [SFTPNameEntry] = []
            entries.reserveCapacity(Int(count))
            for _ in 0..<count {
                guard let filename = payload.readSFTPString(),
                    let longname = payload.readSFTPString()
                else {
                    throw SFTPError.protocolViolation("Invalid NAME entry")
                }
                let attributes = try payload.readSFTPAttributes()
                entries.append(.init(filename: filename, longname: longname, attributes: attributes))
            }
            return .response(id: id, .name(entries))
        case SFTPPacketType.attrs:
            guard let id = payload.readInteger(as: UInt32.self) else {
                throw SFTPError.protocolViolation("Invalid ATTRS packet")
            }
            let attributes = try payload.readSFTPAttributes()
            return .response(id: id, .attributes(attributes))
        case SFTPPacketType.extendedReply:
            guard let id = payload.readInteger(as: UInt32.self) else {
                throw SFTPError.protocolViolation("Invalid EXTENDED_REPLY packet")
            }
            return .response(id: id, .extendedReply(Array(payload.readableBytesView)))
        default:
            throw SFTPError.protocolViolation("Unsupported SFTP packet type \(type)")
        }
    }
}

extension ByteBuffer {
    mutating func readSFTPAttributes() throws -> SFTPAttributes {
        guard let rawFlags = self.readInteger(as: UInt32.self) else {
            throw SFTPError.protocolViolation("Missing SFTP attribute flags")
        }
        let flags = SFTPAttributeFlags(rawValue: rawFlags)
        let unsupportedBits = rawFlags & ~SFTPAttributeFlags.supported.rawValue
        guard unsupportedBits == 0 else {
            throw SFTPError.protocolViolation("Unsupported SFTP attribute flags \(unsupportedBits)")
        }

        var attributes = SFTPAttributes()
        if flags.contains(.size) {
            guard let size = self.readInteger(as: UInt64.self) else {
                throw SFTPError.protocolViolation("Missing SFTP attribute size")
            }
            attributes.size = size
        }
        if flags.contains(.uidgid) {
            guard let uid = self.readInteger(as: UInt32.self),
                let gid = self.readInteger(as: UInt32.self)
            else {
                throw SFTPError.protocolViolation("Missing SFTP uid/gid")
            }
            attributes.uid = uid
            attributes.gid = gid
        }
        if flags.contains(.permissions) {
            guard let permissions = self.readInteger(as: UInt32.self) else {
                throw SFTPError.protocolViolation("Missing SFTP permissions")
            }
            attributes.permissions = permissions
        }
        if flags.contains(.acmodtime) {
            guard let accessTime = self.readInteger(as: UInt32.self),
                let modificationTime = self.readInteger(as: UInt32.self)
            else {
                throw SFTPError.protocolViolation("Missing SFTP time attributes")
            }
            attributes.accessTime = accessTime
            attributes.modificationTime = modificationTime
        }
        if flags.contains(.extended) {
            guard let extendedCount = self.readInteger(as: UInt32.self) else {
                throw SFTPError.protocolViolation("Missing SFTP extended attribute count")
            }
            var extensions: [SFTPExtension] = []
            extensions.reserveCapacity(Int(extendedCount))
            for _ in 0..<extendedCount {
                guard let name = self.readSFTPString(), let data = self.readSFTPStringBuffer() else {
                    throw SFTPError.protocolViolation("Invalid SFTP extended attribute")
                }
                extensions.append(.init(name: name, data: Array(data.readableBytesView)))
            }
            attributes.extended = extensions
        }
        return attributes
    }

    @discardableResult
    mutating func writeSFTPAttributes(_ attributes: SFTPAttributes) -> Int {
        var written = self.writeInteger(attributes.flags.rawValue)
        if let size = attributes.size {
            written += self.writeInteger(size)
        }
        if attributes.flags.contains(.uidgid) {
            written += self.writeInteger(attributes.uid ?? 0)
            written += self.writeInteger(attributes.gid ?? 0)
        }
        if let permissions = attributes.permissions {
            written += self.writeInteger(permissions)
        }
        if attributes.flags.contains(.acmodtime) {
            written += self.writeInteger(attributes.accessTime ?? 0)
            written += self.writeInteger(attributes.modificationTime ?? 0)
        }
        if attributes.flags.contains(.extended) {
            written += self.writeInteger(UInt32(attributes.extended.count))
            for extensionData in attributes.extended {
                written += self.writeSFTPString(extensionData.name)
                written += self.writeSFTPString(extensionData.data)
            }
        }
        return written
    }
}

enum SFTPRequestEncoder {
    static func encode(_ message: SFTPRequestMessage, requestID: UInt32, allocator: ByteBufferAllocator) -> ByteBuffer {
        var buffer = allocator.buffer(capacity: 256)
        buffer.writeSFTPFrame(type: type(for: message)) { body in
            body.writeInteger(requestID)
            switch message {
            case .open(let path, let pflags, let attributes):
                body.writeSFTPString(path)
                body.writeInteger(pflags.rawValue)
                body.writeSFTPAttributes(attributes)
            case .close(let handle):
                body.writeSFTPString(handle)
            case .read(let handle, let offset, let length):
                body.writeSFTPString(handle)
                body.writeInteger(offset)
                body.writeInteger(length)
            case .write(let handle, let offset, let data):
                body.writeSFTPString(handle)
                body.writeInteger(offset)
                body.writeSFTPString(data)
            case .lstat(let path), .opendir(let path), .remove(let path), .rmdir(let path), .realpath(let path),
                 .stat(let path), .readlink(let path):
                body.writeSFTPString(path)
            case .fstat(let handle), .readdir(let handle):
                body.writeSFTPString(handle)
            case .setstat(let path, let attributes):
                body.writeSFTPString(path)
                body.writeSFTPAttributes(attributes)
            case .fsetstat(let handle, let attributes):
                body.writeSFTPString(handle)
                body.writeSFTPAttributes(attributes)
            case .mkdir(let path, let attributes):
                body.writeSFTPString(path)
                body.writeSFTPAttributes(attributes)
            case .rename(let oldPath, let newPath):
                body.writeSFTPString(oldPath)
                body.writeSFTPString(newPath)
            case .symlink(let linkPath, let targetPath):
                body.writeSFTPString(targetPath)
                body.writeSFTPString(linkPath)
            case .extended(let name, let data):
                body.writeSFTPString(name)
                body.writeSFTPString(data)
            }
        }
        return buffer
    }

    static func encodeInit(version: SFTPVersion, allocator: ByteBufferAllocator) -> ByteBuffer {
        var buffer = allocator.buffer(capacity: 16)
        buffer.writeSFTPFrame(type: SFTPPacketType.`init`) { body in
            body.writeInteger(version.rawValue)
        }
        return buffer
    }

    private static func type(for message: SFTPRequestMessage) -> UInt8 {
        switch message {
        case .open: return SFTPPacketType.open
        case .close: return SFTPPacketType.close
        case .read: return SFTPPacketType.read
        case .write: return SFTPPacketType.write
        case .lstat: return SFTPPacketType.lstat
        case .fstat: return SFTPPacketType.fstat
        case .setstat: return SFTPPacketType.setstat
        case .fsetstat: return SFTPPacketType.fsetstat
        case .opendir: return SFTPPacketType.opendir
        case .readdir: return SFTPPacketType.readdir
        case .remove: return SFTPPacketType.remove
        case .mkdir: return SFTPPacketType.mkdir
        case .rmdir: return SFTPPacketType.rmdir
        case .realpath: return SFTPPacketType.realpath
        case .stat: return SFTPPacketType.stat
        case .rename: return SFTPPacketType.rename
        case .readlink: return SFTPPacketType.readlink
        case .symlink: return SFTPPacketType.symlink
        case .extended: return SFTPPacketType.extended
        }
    }
}

enum SFTPRequestDecoder {
    static func decode(type: UInt8, payload: ByteBuffer) throws -> (UInt32, SFTPRequestMessage) {
        var payload = payload
        guard let requestID = payload.readInteger(as: UInt32.self) else {
            throw SFTPError.protocolViolation("Missing SFTP request id")
        }
        switch type {
        case SFTPPacketType.open:
            guard let path = payload.readSFTPString(),
                let flags = payload.readInteger(as: UInt32.self)
            else {
                throw SFTPError.protocolViolation("Invalid OPEN request")
            }
            let attributes = try payload.readSFTPAttributes()
            return (requestID, .open(path: path, pflags: .init(rawValue: flags), attributes: attributes))
        case SFTPPacketType.close:
            guard let handle = payload.readSFTPStringBuffer() else {
                throw SFTPError.protocolViolation("Invalid CLOSE request")
            }
            return (requestID, .close(handle: Array(handle.readableBytesView)))
        case SFTPPacketType.read:
            guard let handle = payload.readSFTPStringBuffer(),
                let offset = payload.readInteger(as: UInt64.self),
                let length = payload.readInteger(as: UInt32.self)
            else {
                throw SFTPError.protocolViolation("Invalid READ request")
            }
            return (requestID, .read(handle: Array(handle.readableBytesView), offset: offset, length: length))
        case SFTPPacketType.write:
            guard let handle = payload.readSFTPStringBuffer(),
                let offset = payload.readInteger(as: UInt64.self),
                let data = payload.readSFTPStringBuffer()
            else {
                throw SFTPError.protocolViolation("Invalid WRITE request")
            }
            return (requestID, .write(handle: Array(handle.readableBytesView), offset: offset, data: Array(data.readableBytesView)))
        case SFTPPacketType.lstat:
            guard let path = payload.readSFTPString() else {
                throw SFTPError.protocolViolation("Invalid LSTAT request")
            }
            return (requestID, .lstat(path: path))
        case SFTPPacketType.fstat:
            guard let handle = payload.readSFTPStringBuffer() else {
                throw SFTPError.protocolViolation("Invalid FSTAT request")
            }
            return (requestID, .fstat(handle: Array(handle.readableBytesView)))
        case SFTPPacketType.setstat:
            guard let path = payload.readSFTPString() else {
                throw SFTPError.protocolViolation("Invalid SETSTAT request")
            }
            return (requestID, .setstat(path: path, attributes: try payload.readSFTPAttributes()))
        case SFTPPacketType.fsetstat:
            guard let handle = payload.readSFTPStringBuffer() else {
                throw SFTPError.protocolViolation("Invalid FSETSTAT request")
            }
            return (requestID, .fsetstat(handle: Array(handle.readableBytesView), attributes: try payload.readSFTPAttributes()))
        case SFTPPacketType.opendir:
            guard let path = payload.readSFTPString() else {
                throw SFTPError.protocolViolation("Invalid OPENDIR request")
            }
            return (requestID, .opendir(path: path))
        case SFTPPacketType.readdir:
            guard let handle = payload.readSFTPStringBuffer() else {
                throw SFTPError.protocolViolation("Invalid READDIR request")
            }
            return (requestID, .readdir(handle: Array(handle.readableBytesView)))
        case SFTPPacketType.remove:
            guard let path = payload.readSFTPString() else {
                throw SFTPError.protocolViolation("Invalid REMOVE request")
            }
            return (requestID, .remove(path: path))
        case SFTPPacketType.mkdir:
            guard let path = payload.readSFTPString() else {
                throw SFTPError.protocolViolation("Invalid MKDIR request")
            }
            return (requestID, .mkdir(path: path, attributes: try payload.readSFTPAttributes()))
        case SFTPPacketType.rmdir:
            guard let path = payload.readSFTPString() else {
                throw SFTPError.protocolViolation("Invalid RMDIR request")
            }
            return (requestID, .rmdir(path: path))
        case SFTPPacketType.realpath:
            guard let path = payload.readSFTPString() else {
                throw SFTPError.protocolViolation("Invalid REALPATH request")
            }
            return (requestID, .realpath(path: path))
        case SFTPPacketType.stat:
            guard let path = payload.readSFTPString() else {
                throw SFTPError.protocolViolation("Invalid STAT request")
            }
            return (requestID, .stat(path: path))
        case SFTPPacketType.rename:
            guard let oldPath = payload.readSFTPString(),
                let newPath = payload.readSFTPString()
            else {
                throw SFTPError.protocolViolation("Invalid RENAME request")
            }
            return (requestID, .rename(oldPath: oldPath, newPath: newPath))
        case SFTPPacketType.readlink:
            guard let path = payload.readSFTPString() else {
                throw SFTPError.protocolViolation("Invalid READLINK request")
            }
            return (requestID, .readlink(path: path))
        case SFTPPacketType.symlink:
            guard let targetPath = payload.readSFTPString(),
                let linkPath = payload.readSFTPString()
            else {
                throw SFTPError.protocolViolation("Invalid SYMLINK request")
            }
            return (requestID, .symlink(linkPath: linkPath, targetPath: targetPath))
        case SFTPPacketType.extended:
            guard let name = payload.readSFTPString(), let data = payload.readSFTPStringBuffer() else {
                throw SFTPError.protocolViolation("Invalid EXTENDED request")
            }
            return (requestID, .extended(name: name, data: Array(data.readableBytesView)))
        default:
            throw SFTPError.protocolViolation("Unsupported SFTP request type \(type)")
        }
    }
}

enum SFTPResponseEncoder {
    static func encodeVersion(_ version: SFTPVersion, extensions: [SFTPExtension], allocator: ByteBufferAllocator) -> ByteBuffer {
        var buffer = allocator.buffer(capacity: 64)
        buffer.writeSFTPFrame(type: SFTPPacketType.version) { body in
            body.writeInteger(version.rawValue)
            for extensionData in extensions {
                body.writeSFTPString(extensionData.name)
                body.writeSFTPString(extensionData.data)
            }
        }
        return buffer
    }

    static func encode(_ response: SFTPResponseMessage, requestID: UInt32, allocator: ByteBufferAllocator) -> ByteBuffer {
        var buffer = allocator.buffer(capacity: 256)
        buffer.writeSFTPFrame(type: type(for: response)) { body in
            body.writeInteger(requestID)
            switch response {
            case .status(let status):
                body.writeInteger(status.code.rawValue)
                body.writeSFTPString(status.message)
                body.writeSFTPString(status.languageTag)
            case .handle(let handle):
                body.writeSFTPString(handle)
            case .data(let data):
                body.writeSFTPString(data)
            case .name(let entries):
                body.writeInteger(UInt32(entries.count))
                for entry in entries {
                    body.writeSFTPString(entry.filename)
                    body.writeSFTPString(entry.longname)
                    body.writeSFTPAttributes(entry.attributes)
                }
            case .attributes(let attributes):
                body.writeSFTPAttributes(attributes)
            case .extendedReply(let data):
                body.writeBytes(data)
            }
        }
        return buffer
    }

    private static func type(for response: SFTPResponseMessage) -> UInt8 {
        switch response {
        case .status: return SFTPPacketType.status
        case .handle: return SFTPPacketType.handle
        case .data: return SFTPPacketType.data
        case .name: return SFTPPacketType.name
        case .attributes: return SFTPPacketType.attrs
        case .extendedReply: return SFTPPacketType.extendedReply
        }
    }
}
