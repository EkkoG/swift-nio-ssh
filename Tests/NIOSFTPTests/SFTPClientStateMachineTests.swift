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
import NIOEmbedded
import XCTest

@testable import NIOSFTP

final class SFTPClientStateMachineTests: XCTestCase {
    func testStartupFlowTransitionsToReady() {
        var stateMachine = SFTPClientStateMachine()

        assertAction(stateMachine.beginStartupIfNeeded(channelIsActive: false), matches: .none)
        assertAction(stateMachine.beginStartupIfNeeded(channelIsActive: true), matches: .sendSubsystemRequest)
        assertAction(stateMachine.receiveSubsystemSuccess(), matches: .sendInit)
        assertAction(stateMachine.receivePacket(.version(.v3, [])), matches: .startupSucceeded)
    }

    func testSubsystemFailureFailsStartup() {
        var stateMachine = SFTPClientStateMachine()
        _ = stateMachine.beginStartupIfNeeded(channelIsActive: true)

        guard case .sessionFailed(let error, let failStartup, let pendingPromises) = stateMachine.receiveSubsystemFailure() else {
            return XCTFail("Expected session failure")
        }

        XCTAssertTrue(failStartup)
        XCTAssertTrue(pendingPromises.isEmpty)
        XCTAssertEqual(error as? SFTPError, .subsystemRejected)
    }

    func testInvalidResponseFamilyFailsSession() {
        let loop = EmbeddedEventLoop()
        defer { XCTAssertNoThrow(try loop.syncShutdownGracefully()) }

        var stateMachine = SFTPClientStateMachine()
        _ = stateMachine.beginStartupIfNeeded(channelIsActive: true)
        _ = stateMachine.receiveSubsystemSuccess()
        _ = stateMachine.receivePacket(.version(.v3, []))

        let promise = loop.makePromise(of: SFTPResponseMessage.self)
        let requestID = try! stateMachine.enqueueRequest(.open(path: "/tmp/file", pflags: [.read], attributes: .init()), promise: promise)

        guard case .sessionFailed(let error, let failStartup, let pendingPromises) = stateMachine.receivePacket(.response(id: requestID, .attributes(.init()))) else {
            return XCTFail("Expected invalid response family to fail the session")
        }

        XCTAssertFalse(failStartup)
        XCTAssertEqual(pendingPromises.count, 1)
        pendingPromises.forEach { $0.fail(error) }
        XCTAssertEqual(
            error as? SFTPError,
            .unexpectedResponse("Received invalid response for OPEN")
        )
    }

    func testUnknownRequestIDFailsSessionAndDrainsPending() {
        let loop = EmbeddedEventLoop()
        defer { XCTAssertNoThrow(try loop.syncShutdownGracefully()) }

        var stateMachine = SFTPClientStateMachine()
        _ = stateMachine.beginStartupIfNeeded(channelIsActive: true)
        _ = stateMachine.receiveSubsystemSuccess()
        _ = stateMachine.receivePacket(.version(.v3, []))

        let promise = loop.makePromise(of: SFTPResponseMessage.self)
        _ = try! stateMachine.enqueueRequest(.stat(path: "/tmp/file"), promise: promise)

        guard case .sessionFailed(let error, let failStartup, let pendingPromises) = stateMachine.receivePacket(.response(id: 999, .status(.init(code: .ok)))) else {
            return XCTFail("Expected unknown request id to fail the session")
        }

        XCTAssertFalse(failStartup)
        XCTAssertEqual(pendingPromises.count, 1)
        pendingPromises.forEach { $0.fail(error) }
        XCTAssertEqual(
            error as? SFTPError,
            .unexpectedResponse("Received response for unknown request id 999")
        )
    }

    func testReadAcceptsDataResponse() {
        let loop = EmbeddedEventLoop()
        defer { XCTAssertNoThrow(try loop.syncShutdownGracefully()) }

        var stateMachine = SFTPClientStateMachine()
        _ = stateMachine.beginStartupIfNeeded(channelIsActive: true)
        _ = stateMachine.receiveSubsystemSuccess()
        _ = stateMachine.receivePacket(.version(.v3, []))

        let promise = loop.makePromise(of: SFTPResponseMessage.self)
        let requestID = try! stateMachine.enqueueRequest(.read(handle: [1, 2, 3], offset: 0, length: 8), promise: promise)

        guard case .requestSucceeded(let promise, let response) = stateMachine.receivePacket(.response(id: requestID, .data([1, 2, 3]))) else {
            return XCTFail("Expected successful read response")
        }

        promise.succeed(response)
        XCTAssertEqual(response, .data([1, 2, 3]))
    }

    private func assertAction(_ action: SFTPClientStateMachine.Action, matches expected: StaticAction) {
        switch (action, expected) {
        case (.none, .none), (.sendSubsystemRequest, .sendSubsystemRequest), (.sendInit, .sendInit), (.startupSucceeded, .startupSucceeded):
            return
        default:
            XCTFail("Unexpected action \(action) for expected \(expected)")
        }
    }
}

private enum StaticAction {
    case none
    case sendSubsystemRequest
    case sendInit
    case startupSucceeded
}
