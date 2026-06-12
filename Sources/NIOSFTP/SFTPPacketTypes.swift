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
