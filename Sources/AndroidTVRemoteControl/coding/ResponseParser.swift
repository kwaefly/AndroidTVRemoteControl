//
//  ResponseParser.swift
//
//  Created for PWApp fork
//

import Foundation

/// Parsed response types from Android TV
public enum RemoteResponse: CustomStringConvertible {
    /// Error response - the TV rejected our request
    case error(RemoteErrorInfo)

    /// Current app changed - contains package name
    case currentApp(packageName: String)

    /// Power state changed
    case powerState(isOn: Bool)

    /// Volume info updated
    case volumeInfo(level: Int, max: Int, muted: Bool)

    /// Ping response (keepalive)
    case pingResponse(val: Int)

    /// Ping request from TV
    case pingRequest(val: Int)

    /// App link echo - TV echoes back the URI we sent
    case appLinkEcho(uri: String)

    /// Device configuration info
    case deviceInfo(vendor: String, model: String, version: String)

    /// Unknown/unparsed response
    case unknown(Data)

    public var description: String {
        switch self {
        case .error(let info):
            return "Error: \(info.description)"
        case .currentApp(let pkg):
            return "Current App: \(pkg)"
        case .powerState(let isOn):
            return "Power: \(isOn ? "ON" : "OFF")"
        case .volumeInfo(let level, let max, let muted):
            return "Volume: \(level)/\(max) (muted: \(muted))"
        case .pingResponse(let val):
            return "Ping Response (\(val))"
        case .pingRequest(let val):
            return "Ping Request (\(val))"
        case .appLinkEcho(let uri):
            return "App Link Echo: \(uri)"
        case .deviceInfo(let vendor, let model, let version):
            return "Device: \(vendor) \(model) v\(version)"
        case .unknown(let data):
            return "Unknown (\(data.count) bytes)"
        }
    }
}

/// Details about a remote error
public struct RemoteErrorInfo {
    /// Whether there was an error (true = error occurred)
    public let hasError: Bool

    /// The original request that caused the error (raw bytes)
    public let originalRequest: Data?

    /// Human-readable description
    public var description: String {
        if hasError {
            return "Remote error occurred"
        } else {
            return "No error"
        }
    }
}

/// Parser for Android TV Remote protocol responses
public class ResponseParser {

    // MARK: - Field Numbers (from protobuf schema)
    // Tag = (field_number << 3) | wire_type
    // Wire type 2 = length-delimited

    private enum FieldTag {
        // Single-byte tags (field < 16)
        static let remoteConfigure: UInt8 = 0x0A      // Field 1
        static let remoteSetActive: UInt8 = 0x12     // Field 2
        static let remoteError: UInt8 = 0x1A        // Field 3
        static let remotePingRequest: UInt8 = 0x42  // Field 8
        static let remotePingResponse: UInt8 = 0x4A // Field 9

        // Multi-byte tags (field >= 16, encoded as varint)
        static let remoteImeKeyInject: [UInt8] = [0xA2, 0x01]  // Field 20 (current app)
        static let remoteStart: [UInt8] = [0xC2, 0x02]         // Field 40 (power state)
        static let remoteSetVolume: [UInt8] = [0xD2, 0x03]     // Field 50 (volume)
        static let remoteAppLink: [UInt8] = [0xD2, 0x05]       // Field 90 (app link)
    }

    /// Try to parse a response from raw data
    /// - Parameter data: Raw bytes received from the TV
    /// - Returns: Parsed response, or nil if not a recognized message
    public static func parse(_ data: Data) -> RemoteResponse? {
        guard data.count >= 2 else { return nil }

        var bytes = Array(data)

        // Messages may have a length prefix - check if first byte(s) match message length
        if let (length, lenBytes) = Decoder.decodeVarint(bytes), Int(length) == bytes.count - lenBytes {
            // Skip the length prefix
            bytes = Array(bytes.dropFirst(lenBytes))
        }

        guard !bytes.isEmpty else { return nil }

        // Check for single-byte tags first
        let firstByte = bytes[0]

        switch firstByte {
        case FieldTag.remoteError:
            return parseRemoteError(bytes)
        case FieldTag.remotePingRequest:
            return parsePingRequest(bytes)
        case FieldTag.remotePingResponse:
            return parsePingResponse(bytes)
        case FieldTag.remoteConfigure:
            return parseDeviceInfo(bytes)
        default:
            break
        }

        // Check for multi-byte tags
        if bytes.count >= 2 {
            let twoBytes = Array(bytes.prefix(2))

            if twoBytes == FieldTag.remoteImeKeyInject {
                return parseCurrentApp(bytes)
            }
            if twoBytes == FieldTag.remoteStart {
                return parsePowerState(bytes)
            }
            if twoBytes == FieldTag.remoteSetVolume {
                return parseVolumeInfo(bytes)
            }
            if twoBytes == FieldTag.remoteAppLink {
                return parseAppLinkEcho(bytes)
            }
        }

        return .unknown(data)
    }

    // MARK: - Individual Parsers

    /// Parse RemoteError (field 3) - error response
    private static func parseRemoteError(_ bytes: [UInt8]) -> RemoteResponse? {
        guard bytes.count > 2, bytes[0] == FieldTag.remoteError else { return nil }

        guard let (length, lengthBytes) = Decoder.decodeVarint(Array(bytes.dropFirst())) else {
            return nil
        }

        let messageStart = 1 + lengthBytes
        guard bytes.count >= messageStart + Int(length) else { return nil }

        let messageBytes = Array(bytes[messageStart..<(messageStart + Int(length))])

        var hasError = false
        var originalRequest: Data? = nil
        var offset = 0

        while offset < messageBytes.count {
            let fieldTag = messageBytes[offset]
            offset += 1

            let fieldNumber = fieldTag >> 3
            let wireType = fieldTag & 0x07

            switch fieldNumber {
            case 1: // bool value
                if wireType == 0, offset < messageBytes.count {
                    hasError = messageBytes[offset] != 0
                    offset += 1
                }
            case 2: // RemoteMessage (original request)
                if wireType == 2 {
                    guard let (msgLen, msgLenBytes) = Decoder.decodeVarint(Array(messageBytes.dropFirst(offset))) else {
                        break
                    }
                    offset += msgLenBytes
                    if offset + Int(msgLen) <= messageBytes.count {
                        originalRequest = Data(messageBytes[offset..<(offset + Int(msgLen))])
                        offset += Int(msgLen)
                    }
                }
            default:
                if let skip = skipField(wireType: wireType, bytes: messageBytes, offset: offset) {
                    offset = skip
                }
            }
        }

        return .error(RemoteErrorInfo(hasError: hasError, originalRequest: originalRequest))
    }

    /// Parse RemoteImeKeyInject (field 20) - current app notification
    private static func parseCurrentApp(_ bytes: [UInt8]) -> RemoteResponse? {
        guard bytes.count > 3 else { return nil }

        // Skip the 2-byte tag
        var offset = 2

        guard let (length, lengthBytes) = Decoder.decodeVarint(Array(bytes.dropFirst(offset))) else {
            return nil
        }
        offset += lengthBytes

        guard bytes.count >= offset + Int(length) else { return nil }

        let messageBytes = Array(bytes[offset..<(offset + Int(length))])

        // Look for app_info.app_package string in nested message
        if let packageName = extractPackageName(from: messageBytes) {
            return .currentApp(packageName: packageName)
        }

        return nil
    }

    /// Parse RemoteStart (field 40) - power state
    private static func parsePowerState(_ bytes: [UInt8]) -> RemoteResponse? {
        guard bytes.count > 3 else { return nil }

        // Skip the 2-byte tag
        var offset = 2

        guard let (length, lengthBytes) = Decoder.decodeVarint(Array(bytes.dropFirst(offset))) else {
            return nil
        }
        offset += lengthBytes

        guard bytes.count >= offset + Int(length) else { return nil }

        let messageBytes = Array(bytes[offset..<(offset + Int(length))])

        // Look for field 1 (started: bool)
        var fieldOffset = 0
        while fieldOffset < messageBytes.count {
            let fieldTag = messageBytes[fieldOffset]
            fieldOffset += 1

            let fieldNumber = fieldTag >> 3
            let wireType = fieldTag & 0x07

            if fieldNumber == 1 && wireType == 0 && fieldOffset < messageBytes.count {
                let isOn = messageBytes[fieldOffset] != 0
                return .powerState(isOn: isOn)
            }

            if let skip = skipField(wireType: wireType, bytes: messageBytes, offset: fieldOffset) {
                fieldOffset = skip
            }
        }

        return nil
    }

    /// Parse RemoteSetVolumeLevel (field 50) - volume info
    private static func parseVolumeInfo(_ bytes: [UInt8]) -> RemoteResponse? {
        guard bytes.count > 3 else { return nil }

        // Skip the 2-byte tag
        var offset = 2

        guard let (length, lengthBytes) = Decoder.decodeVarint(Array(bytes.dropFirst(offset))) else {
            return nil
        }
        offset += lengthBytes

        guard bytes.count >= offset + Int(length) else { return nil }

        let messageBytes = Array(bytes[offset..<(offset + Int(length))])

        // RemoteSetVolumeLevel fields:
        // field 1: volume_level (int)
        // field 2: volume_max (int)
        // field 3: volume_muted (bool)

        var level = 0
        var max = 100
        var muted = false
        var fieldOffset = 0

        while fieldOffset < messageBytes.count {
            let fieldTag = messageBytes[fieldOffset]
            fieldOffset += 1

            let fieldNumber = fieldTag >> 3
            let wireType = fieldTag & 0x07

            if wireType == 0 { // varint
                guard let (value, valBytes) = Decoder.decodeVarint(Array(messageBytes.dropFirst(fieldOffset))) else {
                    break
                }
                fieldOffset += valBytes

                switch fieldNumber {
                case 1: level = Int(value)
                case 2: max = Int(value)
                case 3: muted = value != 0
                default: break
                }
            } else if let skip = skipField(wireType: wireType, bytes: messageBytes, offset: fieldOffset) {
                fieldOffset = skip
            }
        }

        return .volumeInfo(level: level, max: max, muted: muted)
    }

    /// Parse RemotePingRequest (field 8)
    private static func parsePingRequest(_ bytes: [UInt8]) -> RemoteResponse? {
        guard bytes.count > 2, bytes[0] == FieldTag.remotePingRequest else { return nil }

        guard let (length, lengthBytes) = Decoder.decodeVarint(Array(bytes.dropFirst())) else {
            return nil
        }

        let messageStart = 1 + lengthBytes
        guard bytes.count >= messageStart + Int(length) else { return nil }

        let messageBytes = Array(bytes[messageStart..<(messageStart + Int(length))])

        // Look for field 1 (val1: int)
        if messageBytes.count >= 2 && messageBytes[0] == 0x08 {
            if let (val, _) = Decoder.decodeVarint(Array(messageBytes.dropFirst())) {
                return .pingRequest(val: Int(val))
            }
        }

        return .pingRequest(val: 0)
    }

    /// Parse RemotePingResponse (field 9)
    private static func parsePingResponse(_ bytes: [UInt8]) -> RemoteResponse? {
        guard bytes.count > 2, bytes[0] == FieldTag.remotePingResponse else { return nil }

        guard let (length, lengthBytes) = Decoder.decodeVarint(Array(bytes.dropFirst())) else {
            return nil
        }

        let messageStart = 1 + lengthBytes
        guard bytes.count >= messageStart + Int(length) else { return nil }

        let messageBytes = Array(bytes[messageStart..<(messageStart + Int(length))])

        // Look for field 1 (val1: int)
        if messageBytes.count >= 2 && messageBytes[0] == 0x08 {
            if let (val, _) = Decoder.decodeVarint(Array(messageBytes.dropFirst())) {
                return .pingResponse(val: Int(val))
            }
        }

        return .pingResponse(val: 0)
    }

    /// Parse RemoteConfigure (field 1) - device info
    private static func parseDeviceInfo(_ bytes: [UInt8]) -> RemoteResponse? {
        guard bytes.count > 2, bytes[0] == FieldTag.remoteConfigure else { return nil }

        guard let (length, lengthBytes) = Decoder.decodeVarint(Array(bytes.dropFirst())) else {
            return nil
        }

        let messageStart = 1 + lengthBytes
        guard bytes.count >= messageStart + Int(length) else { return nil }

        let messageBytes = Array(bytes[messageStart..<(messageStart + Int(length))])

        // Look for device_info nested message and extract strings
        var vendor = ""
        var model = ""
        var version = ""

        // Find strings in nested structure
        if let strings = extractAllStrings(from: messageBytes) {
            if strings.count >= 1 { vendor = strings[0] }
            if strings.count >= 2 { model = strings[1] }
            if strings.count >= 3 { version = strings[2] }
        }

        if !vendor.isEmpty || !model.isEmpty {
            return .deviceInfo(vendor: vendor, model: model, version: version)
        }

        return nil
    }

    /// Parse RemoteAppLinkLaunchRequest (field 90) - app link echo
    private static func parseAppLinkEcho(_ bytes: [UInt8]) -> RemoteResponse? {
        guard bytes.count > 3 else { return nil }

        // Skip the 2-byte tag
        var offset = 2

        guard let (length, lengthBytes) = Decoder.decodeVarint(Array(bytes.dropFirst(offset))) else {
            return nil
        }
        offset += lengthBytes

        guard bytes.count >= offset + Int(length) else { return nil }

        let messageBytes = Array(bytes[offset..<(offset + Int(length))])

        // Look for field 1 (app_link: string)
        if let uri = extractUriString(from: messageBytes) {
            return .appLinkEcho(uri: uri)
        }

        return .appLinkEcho(uri: "(URI not extracted)")
    }

    // MARK: - Helper Functions

    /// Extract package name from RemoteImeKeyInject message
    private static func extractPackageName(from bytes: [UInt8]) -> String? {
        // RemoteImeKeyInject contains RemoteAppInfo which has app_package
        // Structure: field 1 = app_info (nested), which contains field 1 = app_package (string)

        var offset = 0
        while offset < bytes.count {
            let fieldTag = bytes[offset]
            offset += 1

            let fieldNumber = fieldTag >> 3
            let wireType = fieldTag & 0x07

            if wireType == 2 { // length-delimited
                guard let (fieldLen, lenBytes) = Decoder.decodeVarint(Array(bytes.dropFirst(offset))) else {
                    return nil
                }
                offset += lenBytes

                let fieldEnd = min(offset + Int(fieldLen), bytes.count)
                let fieldData = Array(bytes[offset..<fieldEnd])

                // Try to extract as string first
                if let str = String(bytes: fieldData, encoding: .utf8),
                   str.contains(".") && !str.contains(" ") && str.count > 3 {
                    // Looks like a package name (e.g., com.netflix.ninja)
                    return str
                }

                // Try nested message
                if let nested = extractPackageName(from: fieldData) {
                    return nested
                }

                offset = fieldEnd
            } else if let skip = skipField(wireType: wireType, bytes: bytes, offset: offset) {
                offset = skip
            } else {
                break
            }
        }

        return nil
    }

    /// Extract URI string from nested message
    private static func extractUriString(from bytes: [UInt8]) -> String? {
        var offset = 0

        while offset < bytes.count {
            let fieldTag = bytes[offset]
            offset += 1

            let wireType = fieldTag & 0x07

            switch wireType {
            case 0: // Varint
                while offset < bytes.count && (bytes[offset] & 0x80) != 0 {
                    offset += 1
                }
                if offset < bytes.count {
                    offset += 1
                }

            case 2: // Length-delimited (string or nested message)
                guard let (fieldLen, lenBytes) = Decoder.decodeVarint(Array(bytes.dropFirst(offset))) else {
                    return nil
                }
                offset += lenBytes

                let fieldStart = offset
                let fieldEnd = min(offset + Int(fieldLen), bytes.count)
                let fieldData = Array(bytes[fieldStart..<fieldEnd])

                // Check if this looks like a URI string
                if let str = String(bytes: fieldData, encoding: .utf8),
                   (str.contains("://") || str.hasPrefix("market:")) {
                    return str
                }

                // Try nested message
                if let nestedUri = extractUriString(from: fieldData) {
                    return nestedUri
                }

                offset = fieldEnd

            default:
                return nil
            }
        }

        return nil
    }

    /// Extract all strings from nested message
    private static func extractAllStrings(from bytes: [UInt8]) -> [String]? {
        var strings: [String] = []
        var offset = 0

        while offset < bytes.count {
            let fieldTag = bytes[offset]
            offset += 1

            let wireType = fieldTag & 0x07

            if wireType == 2 { // length-delimited
                guard let (fieldLen, lenBytes) = Decoder.decodeVarint(Array(bytes.dropFirst(offset))) else {
                    break
                }
                offset += lenBytes

                let fieldEnd = min(offset + Int(fieldLen), bytes.count)
                let fieldData = Array(bytes[offset..<fieldEnd])

                if let str = String(bytes: fieldData, encoding: .utf8),
                   !str.isEmpty && str.allSatisfy({ $0.isASCII }) {
                    strings.append(str)
                } else if let nested = extractAllStrings(from: fieldData) {
                    strings.append(contentsOf: nested)
                }

                offset = fieldEnd
            } else if let skip = skipField(wireType: wireType, bytes: bytes, offset: offset) {
                offset = skip
            } else {
                break
            }
        }

        return strings.isEmpty ? nil : strings
    }

    /// Skip a field based on wire type
    private static func skipField(wireType: UInt8, bytes: [UInt8], offset: Int) -> Int? {
        var newOffset = offset

        switch wireType {
        case 0: // Varint
            while newOffset < bytes.count && (bytes[newOffset] & 0x80) != 0 {
                newOffset += 1
            }
            return newOffset < bytes.count ? newOffset + 1 : nil

        case 1: // 64-bit fixed
            return newOffset + 8 <= bytes.count ? newOffset + 8 : nil

        case 2: // Length-delimited
            guard let (len, lenBytes) = Decoder.decodeVarint(Array(bytes.dropFirst(newOffset))) else {
                return nil
            }
            newOffset += lenBytes + Int(len)
            return newOffset <= bytes.count ? newOffset : nil

        case 5: // 32-bit fixed
            return newOffset + 4 <= bytes.count ? newOffset + 4 : nil

        default:
            return nil
        }
    }
}
