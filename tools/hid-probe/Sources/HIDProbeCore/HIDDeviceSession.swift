import Foundation
import IOKit
import IOKit.hid

public enum ReportIDMode: String, Sendable, CaseIterable {
    /// 按 Apple 文档：reportID 单独传入，buffer 不含 ID。协议帧首字节 0 被去掉，发送 32 字节。
    case strip
    /// 原样发送 33 字节（首字节 0 仍在 buffer 中）。
    case keep
}

public struct ExchangeResult: Sendable {
    public var writeReturn: IOReturn
    public var wireBytes: [UInt8]
    public var responses: [[UInt8]]
    public var ackIndex: Int?
    public var ackOffset: Int?

    public var wrote: Bool { writeReturn == kIOReturnSuccess }
    public var acked: Bool { ackIndex != nil }
    public var ackResponse: [UInt8]? { ackIndex.map { responses[$0] } }

    /// 返回去掉 report ID 后的响应（若 ACK 在偏移 1）。
    public var normalizedAckResponse: [UInt8]? {
        guard let ackResponse, let ackOffset else { return nil }
        return Array(ackResponse.dropFirst(ackOffset))
    }
}

/// 一个已打开的 HID 接口。所有调用必须在同一个线程（runloop 线程）上。
public final class HIDDeviceSession {
    public let info: HIDDeviceInfo
    private let device: IOHIDDevice
    private var buffer: UnsafeMutablePointer<UInt8>?
    private let bufferLength: Int
    private var opened = false
    private var scheduled = false
    private var inbox: [[UInt8]] = []

    public init(device: IOHIDDevice, info: HIDDeviceInfo) {
        self.device = device
        self.info = info
        self.bufferLength = max(64, info.maxInputReportSize + 1)
    }

    deinit { close() }

    public func open() -> IOReturn {
        guard !opened else { return kIOReturnSuccess }
        let result = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
        guard result == kIOReturnSuccess else { return result }
        opened = true

        let ptr = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferLength)
        ptr.initialize(repeating: 0, count: bufferLength)
        buffer = ptr
        IOHIDDeviceRegisterInputReportCallback(
            device, ptr, bufferLength, inputReportCallback,
            Unmanaged.passUnretained(self).toOpaque()
        )
        IOHIDDeviceScheduleWithRunLoop(device, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
        scheduled = true
        return result
    }

    public func close() {
        guard opened else { return }
        if scheduled {
            IOHIDDeviceUnscheduleFromRunLoop(device, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
            scheduled = false
        }
        if let buffer {
            IOHIDDeviceRegisterInputReportCallback(device, buffer, bufferLength, nil, nil)
        }
        IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
        opened = false
        buffer?.deallocate()
        buffer = nil
        inbox.removeAll()
    }

    /// 下发一帧。返回实际写入的字节（用于日志/复现）。
    public func write(_ frame: [UInt8], mode: ReportIDMode) -> (return: IOReturn, wire: [UInt8]) {
        let wire: [UInt8]
        if mode == .strip, frame.first == 0 {
            wire = Array(frame.dropFirst())
        } else {
            wire = frame
        }
        guard !wire.isEmpty else { return (kIOReturnBadArgument, wire) }
        var result: IOReturn = kIOReturnNotOpen
        wire.withUnsafeBufferPointer { pointer in
            guard let base = pointer.baseAddress else { return }
            result = IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, 0, base, pointer.count)
        }
        return (result, wire)
    }

    /// 在截止时间前等待一个输入报告。
    public func waitForReport(until deadline: Date) -> [UInt8]? {
        if !inbox.isEmpty { return inbox.removeFirst() }
        let mode = CFRunLoopMode.defaultMode
        while Date() < deadline {
            if !inbox.isEmpty { return inbox.removeFirst() }
            let slice = min(0.01, deadline.timeIntervalSinceNow)
            if slice <= 0 { break }
            CFRunLoopRunInMode(mode, slice, true)
        }
        return inbox.isEmpty ? nil : inbox.removeFirst()
    }

    /// 写 + 等待 ACK。语义与上游一致：ACK = 剥掉 report ID 后 `resp[1] == 0`。
    public func exchange(
        frame: [UInt8],
        mode: ReportIDMode,
        timeout: TimeInterval = 1.0,
        maxReads: Int = 12
    ) -> ExchangeResult {
        let (result, wire) = write(frame, mode: mode)
        var out = ExchangeResult(
            writeReturn: result, wireBytes: wire,
            responses: [], ackIndex: nil, ackOffset: nil
        )
        guard result == kIOReturnSuccess else { return out }

        let deadline = Date().addingTimeInterval(timeout)
        while out.responses.count < maxReads, Date() < deadline {
            let sliceDeadline = min(deadline, Date().addingTimeInterval(0.15))
            guard let response = waitForReport(until: sliceDeadline) else { continue }
            out.responses.append(response)
            if let offset = Self.ackOffset(in: response) {
                out.ackIndex = out.responses.count - 1
                out.ackOffset = offset
                break
            }
        }
        return out
    }

    /// 判定响应是否 ACK，并返回 report ID 偏移（0 = 不含 ID，1 = 含 ID）。
    public static func ackOffset(in bytes: [UInt8]) -> Int? {
        if bytes.count > 2, bytes[0] != 0, bytes[1] == 0 { return 0 }
        if bytes.count > 3, bytes[1] != 0, bytes[2] == 0 { return 1 }
        return nil
    }

    fileprivate func append(report: UnsafePointer<UInt8>, length: Int, reportID: UInt32) {
        guard inbox.count < 64 else { return }
        let start = report
        inbox.append(Array(UnsafeBufferPointer(start: start, count: length)))
    }
}

private let inputReportCallback: IOHIDReportCallback = {
    context, result, _, _, _, report, reportLength in
    guard result == kIOReturnSuccess, let context, reportLength > 0 else { return }
    let session = Unmanaged<HIDDeviceSession>.fromOpaque(context).takeUnretainedValue()
    session.append(report: report, length: Int(reportLength), reportID: 0)
}
