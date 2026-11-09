import Foundation
import IOKit
import IOKit.hid

/// 一个 IOHIDDevice（通常对应复合设备的一个 HID 接口/collection）。
public struct HIDDeviceInfo: Sendable, Equatable, Identifiable {
    public var index: Int
    public var vendorID: Int
    public var productID: Int
    public var usagePage: Int
    public var usage: Int
    public var transport: String
    public var product: String
    public var manufacturer: String
    public var serialNumber: String
    public var locationID: Int
    public var interfaceNumber: Int?
    public var maxInputReportSize: Int
    public var maxOutputReportSize: Int
    public var maxFeatureReportSize: Int

    public var id: String {
        "\(vendorID):\(productID):\(interfaceNumber.map(String.init) ?? "-"):\(usagePage):\(usage):\(locationID)"
    }

    public var isInphic: Bool { InphicHardware.isInphicVendor(vendorID) }
    public var hasUpstreamPID: Bool { productID == InphicHardware.upstreamProductID }

    public var isLikelyConfigurationInterface: Bool {
        interfaceNumber == InphicHardware.configInterfaceNumber
    }

    public var usageText: String {
        String(format: "UP=0x%04X U=0x%04X", usagePage, usage)
    }

    public var oneLine: String {
        let iface = interfaceNumber.map(String.init) ?? "?"
        return String(
            format: "[%2d] VID_%04X&PID_%04X  if=%@  %@  in=%d out=%d feat=%d  \"%@\"  %@  loc=0x%08X%@",
            index, vendorID, productID, iface, usageText,
            maxInputReportSize, maxOutputReportSize, maxFeatureReportSize,
            product, transport, locationID,
            isInphic ? (hasUpstreamPID ? "  <INPHIC>" : "  <INPHIC? PID≠8266>") : ""
        )
    }
}

public enum InphicHardware {
    public static let usbVendorID = 0x248A
    public static let wirelessVendorID = 0x249A
    /// 上游文档记录的 PID；实机发现 2.4G 接收器也可能使用其它 PID（见 docs/STATUS.md）。
    public static let upstreamProductID = 0x8266
    public static let configInterfaceNumber = 2

    public static func isInphicVendor(_ vendorID: Int) -> Bool {
        vendorID == usbVendorID || vendorID == wirelessVendorID
    }

    public static func isInphic(vendorID: Int, productID: Int) -> Bool {
        isInphicVendor(vendorID) && productID == upstreamProductID
    }
}

public enum HIDEnumeratorError: Error, CustomStringConvertible {
    case managerOpenFailed(IOReturn)

    public var description: String {
        switch self {
        case .managerOpenFailed(let code):
            "IOHIDManagerOpen 失败: \(Self.returnText(code))"
        }
    }

    public static func returnText(_ code: IOReturn) -> String {
        let name: String
        switch code {
        case kIOReturnSuccess: name = "kIOReturnSuccess"
        case kIOReturnExclusiveAccess: name = "kIOReturnExclusiveAccess"
        case kIOReturnNotPermitted: name = "kIOReturnNotPermitted"
        case kIOReturnNotOpen: name = "kIOReturnNotOpen"
        case kIOReturnNotAttached: name = "kIOReturnNotAttached"
        case kIOReturnUnsupported: name = "kIOReturnUnsupported"
        case kIOReturnBadArgument: name = "kIOReturnBadArgument"
        case kIOReturnIOError: name = "kIOReturnIOError"
        case kIOReturnNotFound: name = "kIOReturnNotFound"
        default: name = "IOReturn(\(String(format: "0x%08X", UInt32(bitPattern: code))))"
        }
        return "\(name) [\(String(format: "0x%08X", UInt32(bitPattern: code)))]"
    }
}

/// 枚举系统 HID 设备。只读，不打开任何 collection。
public final class HIDEnumerator {
    private let manager: IOHIDManager

    public init() throws {
        // 打开“全部 HID”时，只要其中一个 collection 返回 kIOReturnUnsupported，
        // IOHIDManagerOpen 就会整体失败（例如同时插着其它 2.4G 键盘）。
        // 此时退回只匹配 Inphic 厂商（248A / 249A）的多个 matching 字典。
        do {
            manager = try Self.open(matching: nil)
        } catch {
            manager = try Self.open(matchingMultiple: [
                [kIOHIDVendorIDKey as String: InphicHardware.usbVendorID],
                [kIOHIDVendorIDKey as String: InphicHardware.wirelessVendorID],
            ])
        }
    }

    private static func open(matching: CFDictionary?) throws -> IOHIDManager {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(manager, matching)
        let result = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        guard result == kIOReturnSuccess else {
            IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
            throw HIDEnumeratorError.managerOpenFailed(result)
        }
        return manager
    }

    private static func open(matchingMultiple: [[String: Any]]) throws -> IOHIDManager {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatchingMultiple(manager, matchingMultiple as CFArray)
        let result = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        guard result == kIOReturnSuccess else {
            IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
            throw HIDEnumeratorError.managerOpenFailed(result)
        }
        return manager
    }

    deinit {
        IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
    }

    /// 按稳定顺序返回设备与 IOHIDDevice 引用。
    public func entries() -> [(info: HIDDeviceInfo, device: IOHIDDevice)] {
        guard let rawSet = IOHIDManagerCopyDevices(manager) else { return [] }
        let nsSet = rawSet as NSSet
        guard let devices = nsSet.allObjects as? [IOHIDDevice] else { return [] }

        var rows = devices.map { dev in (device: dev, info: Self.info(dev, index: 0)) }
        rows.sort {
            if $0.info.isInphic != $1.info.isInphic { return $0.info.isInphic }
            if $0.info.vendorID != $1.info.vendorID { return $0.info.vendorID < $1.info.vendorID }
            if $0.info.productID != $1.info.productID { return $0.info.productID < $1.info.productID }
            let a = $0.info.interfaceNumber ?? Int.max
            let b = $1.info.interfaceNumber ?? Int.max
            if a != b { return a < b }
            if $0.info.usagePage != $1.info.usagePage { return $0.info.usagePage < $1.info.usagePage }
            if $0.info.usage != $1.info.usage { return $0.info.usage < $1.info.usage }
            return $0.info.locationID < $1.info.locationID
        }
        return rows.enumerated().map { index, row in
            var info = row.info
            info.index = index
            return (info, row.device)
        }
    }

    public func devices() -> [HIDDeviceInfo] { entries().map(\.info) }

    // MARK: - 属性读取

    public static func info(_ device: IOHIDDevice, index: Int) -> HIDDeviceInfo {
        HIDDeviceInfo(
            index: index,
            vendorID: intProperty(device, kIOHIDVendorIDKey as CFString) ?? -1,
            productID: intProperty(device, kIOHIDProductIDKey as CFString) ?? -1,
            usagePage: intProperty(device, kIOHIDPrimaryUsagePageKey as CFString) ?? -1,
            usage: intProperty(device, kIOHIDPrimaryUsageKey as CFString) ?? -1,
            transport: stringProperty(device, kIOHIDTransportKey as CFString) ?? "?",
            product: stringProperty(device, kIOHIDProductKey as CFString) ?? "?",
            manufacturer: stringProperty(device, kIOHIDManufacturerKey as CFString) ?? "?",
            serialNumber: stringProperty(device, kIOHIDSerialNumberKey as CFString) ?? "",
            locationID: intProperty(device, kIOHIDLocationIDKey as CFString) ?? 0,
            interfaceNumber: interfaceNumber(device),
            maxInputReportSize: intProperty(device, kIOHIDMaxInputReportSizeKey as CFString) ?? 0,
            maxOutputReportSize: intProperty(device, kIOHIDMaxOutputReportSizeKey as CFString) ?? 0,
            maxFeatureReportSize: intProperty(device, kIOHIDMaxFeatureReportSizeKey as CFString) ?? 0
        )
    }

    static func intProperty(_ device: IOHIDDevice, _ key: CFString) -> Int? {
        guard let value = IOHIDDeviceGetProperty(device, key) else { return nil }
        return (value as? NSNumber)?.intValue
    }

    static func stringProperty(_ device: IOHIDDevice, _ key: CFString) -> String? {
        guard let value = IOHIDDeviceGetProperty(device, key) else { return nil }
        return value as? String
    }

    /// Windows 上接口号来自路径 `mi_02`；macOS 上从 IORegistry 父节点取 `bInterfaceNumber`。
    static func interfaceNumber(_ device: IOHIDDevice) -> Int? {
        let service = IOHIDDeviceGetService(device)
        guard service != 0 else { return nil }
        let options = IOOptionBits(kIORegistryIterateRecursively) | IOOptionBits(kIORegistryIterateParents)
        guard let value = IORegistryEntrySearchCFProperty(
            service,
            kIOServicePlane,
            "bInterfaceNumber" as CFString,
            kCFAllocatorDefault,
            options
        ) else { return nil }
        return (value as? NSNumber)?.intValue
    }
}
