import Foundation
import HIDProbeCore
import IOKit
import IOKit.hid

/// 监听 HID 设备插入/移除（IOHIDManager 回调 + runloop）。
public final class HIDMonitor {
    private let manager: IOHIDManager
    private var known: Set<String> = []

    public init() throws {
        manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(manager, nil)
        let result = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        guard result == kIOReturnSuccess else {
            throw HIDEnumeratorError.managerOpenFailed(result)
        }
    }

    deinit {
        stop()
    }

    public func start() {
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, matchingCallback, context)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, removalCallback, context)
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
    }

    public func stop() {
        IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDManagerRegisterDeviceMatchingCallback(manager, nil, nil)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, nil, nil)
        IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
    }

    /// 枚举当前设备并打印快照（不触发插入事件）。
    public func printSnapshot() {
        guard let rawSet = IOHIDManagerCopyDevices(manager) else { return }
        let set = rawSet as NSSet
        guard let devices = set.allObjects as? [IOHIDDevice] else { return }
        for device in devices {
            let info = HIDEnumerator.info(device, index: 0)
            known.insert(info.id)
            if info.isInphic { print("  当前: \(info.oneLine)") }
        }
        if known.isEmpty { print("  当前没有 INPHIC (VID 248A/249A, PID 8266) 设备") }
    }

    fileprivate func didMatch(_ device: IOHIDDevice) {
        let info = HIDEnumerator.info(device, index: 0)
        known.insert(info.id)
        print("[\(timestamp())] + \(info.isInphic ? "INPHIC " : "")\(info.oneLine)")
    }

    fileprivate func didRemove(_ device: IOHIDDevice) {
        let info = HIDEnumerator.info(device, index: 0)
        known.remove(info.id)
        print("[\(timestamp())] - \(info.isInphic ? "INPHIC " : "")\(info.oneLine)")
    }
}

private let matchingCallback: IOHIDDeviceCallback = { context, _, _, device in
    guard let context else { return }
    Unmanaged<HIDMonitor>.fromOpaque(context).takeUnretainedValue().didMatch(device)
}

private let removalCallback: IOHIDDeviceCallback = { context, _, _, device in
    guard let context else { return }
    Unmanaged<HIDMonitor>.fromOpaque(context).takeUnretainedValue().didRemove(device)
}

func timestamp() -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "HH:mm:ss.SSS"
    return formatter.string(from: Date())
}
