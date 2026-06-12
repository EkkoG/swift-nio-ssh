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

final class SFTPClientHandler: ChannelDuplexHandler, @unchecked Sendable {
    typealias InboundIn = SSHChannelData
    typealias OutboundIn = Never
    typealias OutboundOut = SSHChannelData

    enum Phase {
        case idle
        case waitingForSubsystemReply
        case waitingForVersion
        case ready
        case closed
    }

    private struct PendingRequest {
        var message: SFTPRequestMessage
        var promise: EventLoopPromise<SFTPResponseMessage>
    }

    private(set) var startupFuture: EventLoopFuture<Void>

    private let startupPromise: EventLoopPromise<Void>
    private var phase: Phase = .idle
    private var context: ChannelHandlerContext?
    private var inboundBuffer: ByteBuffer
    private var nextRequestID: UInt32 = 0
    private var pendingRequests: [UInt32: PendingRequest] = [:]
    private var isFailing = false
    private var startupResolved = false

    init(loop: EventLoop, allocator: ByteBufferAllocator) {
        self.startupPromise = loop.makePromise(of: Void.self)
        self.startupFuture = self.startupPromise.futureResult
        self.inboundBuffer = allocator.buffer(capacity: 0)
    }

    func handlerAdded(context: ChannelHandlerContext) {
        self.context = context
        context.channel.setOption(ChannelOptions.allowRemoteHalfClosure, value: true).whenFailure { _ in }
        self.beginStartupIfNeeded(context: context)
    }

    func channelActive(context: ChannelHandlerContext) {
        self.beginStartupIfNeeded(context: context)
        context.fireChannelActive()
    }

    func channelInactive(context: ChannelHandlerContext) {
        self.failAll(error: SFTPError.channelClosed, context: context)
        context.fireChannelInactive()
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        switch event {
        case is ChannelSuccessEvent:
            guard self.phase == .waitingForSubsystemReply else {
                context.fireUserInboundEventTriggered(event)
                return
            }
            self.phase = .waitingForVersion
            self.writeAndFlush(buffer: SFTPRequestEncoder.encodeInit(version: .v3, allocator: context.channel.allocator), context: context, promise: nil)
        case is ChannelFailureEvent:
            if self.phase == .waitingForSubsystemReply {
                self.failAll(error: SFTPError.subsystemRejected, context: context)
                return
            }
            context.fireUserInboundEventTriggered(event)
        default:
            context.fireUserInboundEventTriggered(event)
        }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let data = self.unwrapInboundIn(data)
        guard case .byteBuffer(let bytes) = data.data else {
            self.failAll(error: SFTPError.protocolViolation("Unsupported SSH IOData payload"), context: context)
            return
        }

        switch data.type {
        case .channel:
            var bytes = bytes
            self.inboundBuffer.writeBuffer(&bytes)
            do {
                try self.processInbound(context: context)
            } catch {
                self.failAll(error: error, context: context)
            }
        case .stdErr:
            context.fireUserInboundEventTriggered(SFTPClientEvent(standardError: bytes))
        default:
            self.failAll(error: SFTPError.protocolViolation("Unsupported SSH extended data stream"), context: context)
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        self.failAll(error: error, context: context)
        context.fireErrorCaught(error)
    }

    func send(_ message: SFTPRequestMessage) -> EventLoopFuture<SFTPResponseMessage> {
        guard let context = self.context else {
            return self.startupPromise.futureResult.eventLoop.makeFailedFuture(SFTPError.sessionNotReady)
        }
        guard self.phase == .ready else {
            return context.eventLoop.makeFailedFuture(SFTPError.sessionNotReady)
        }

        let requestID = self.allocateRequestID()
        let promise = context.eventLoop.makePromise(of: SFTPResponseMessage.self)
        self.pendingRequests[requestID] = .init(message: message, promise: promise)
        let buffer = SFTPRequestEncoder.encode(message, requestID: requestID, allocator: context.channel.allocator)
        self.writeAndFlush(buffer: buffer, context: context, promise: promise)
        return promise.futureResult
    }

    private func writeAndFlush(
        buffer: ByteBuffer,
        context: ChannelHandlerContext,
        promise: EventLoopPromise<SFTPResponseMessage>?
    ) {
        let loopBoundContext = NIOLoopBound(context, eventLoop: context.eventLoop)
        let wrapped = self.wrapOutboundOut(.init(type: .channel, data: .byteBuffer(buffer)))
        context.writeAndFlush(wrapped).whenFailure { error in
            if let promise {
                promise.fail(error)
            }
            self.failAll(error: error, context: loopBoundContext.value)
        }
    }

    private func processInbound(context: ChannelHandlerContext) throws {
        while let packet = try self.inboundBuffer.readSFTPFrame() {
            switch packet {
            case .version(let version, _):
                guard self.phase == .waitingForVersion else {
                    throw SFTPError.unexpectedResponse("Received VERSION outside startup")
                }
                guard version == .v3 else {
                    throw SFTPError.unsupportedVersion(version.rawValue)
                }
                self.phase = .ready
                self.startupResolved = true
                self.startupPromise.succeed(())
            case .response(let requestID, let response):
                guard let pending = self.pendingRequests.removeValue(forKey: requestID) else {
                    throw SFTPError.unexpectedResponse("Received response for unknown request id \(requestID)")
                }
                pending.promise.succeed(response)
            }
        }
    }

    private func allocateRequestID() -> UInt32 {
        while self.pendingRequests[self.nextRequestID] != nil {
            self.nextRequestID &+= 1
        }
        defer {
            self.nextRequestID &+= 1
        }
        return self.nextRequestID
    }

    private func beginStartupIfNeeded(context: ChannelHandlerContext) {
        guard self.phase == .idle, context.channel.isActive else {
            return
        }
        self.phase = .waitingForSubsystemReply
        let loopBoundContext = NIOLoopBound(context, eventLoop: context.eventLoop)
        context.triggerUserOutboundEvent(
            SSHChannelRequestEvent.SubsystemRequest(subsystem: "sftp", wantReply: true)
        ).whenFailure { error in
            self.failAll(error: error, context: loopBoundContext.value)
        }
    }

    private func failAll(error: Error, context: ChannelHandlerContext) {
        guard !self.isFailing else {
            return
        }
        self.isFailing = true
        self.phase = .closed
        if !self.startupResolved {
            self.startupResolved = true
            self.startupPromise.fail(error)
        }
        let pending = self.pendingRequests.values
        self.pendingRequests.removeAll()
        pending.forEach { $0.promise.fail(error) }
        context.close(promise: nil)
    }
}
