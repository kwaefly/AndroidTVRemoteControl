//
//  ResponseParser.swift
//
//  Created for PWApp fork
//

import Foundation

/// Parsed response types from Android TV
public enum RemoteResponse {
    /// Error response - the TV rejected our request
    case error(RemoteErrorInfo)

    /// App link launch response - TV echoes back the deep link URI
    case appLinkResponse(uri: String)

    /// App launch result (inferred from lack of error after sending deep link)
    case appLaunchSuccess

    /// Volume level update
    case volumeLevel(Int)

    /// Current app changed
    case currentApp(String)

    /// Unknown/unparsed response
    case unknown(Data)
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

    // Protobuf field tags (field_number << 3 | wire_type)
    // Wire type 2 = length-delimited (for nested messages, strings)
    // Wire type 0 = varint

    /// RemoteError is field 3, wire type 2 = (3 << 3) | 2 = 26 = 0x1a
    private static let remoteErrorTag: UInt8 = 0x1a

    /// AppLinkResponse is field 8, wire type 2 = (8 << 3) | 2 = 66 = 0x42
    /// This is the TV echoing back the deep link URI after launch
    private static let appLinkResponseTag: UInt8 = 0x42

    /// RemoteAppLinkLaunchRequest is field 90, wire type 2 = (90 << 3) | 2 = 722
    /// In varint: 722 = [0xd2, 0x05]
    private static let appLinkRequestTag: [UInt8] = [0xd2, 0x05]

    /// Try to parse a response from raw data
    /// - Parameter data: Raw bytes received from the TV
    /// - Returns: Parsed response, or nil if not a recognized message
    public static func parse(_ data: Data) -> RemoteResponse? {
        guard !data.isEmpty else { return nil }

        let bytes = Array(data)

        // Check for RemoteError (field 3)
        if bytes.first == remoteErrorTag {
            return parseRemoteError(bytes)
        }

        // Check for AppLinkResponse (field 8)
        if bytes.first == appLinkResponseTag {
            return parseAppLinkResponse(bytes)
        }

        return .unknown(data)
    }

    /// Parse a RemoteError message
    private static func parseRemoteError(_ bytes: [UInt8]) -> RemoteResponse? {
        guard bytes.count > 2, bytes[0] == remoteErrorTag else { return nil }

        // Skip the tag byte and read the length
        guard let (length, lengthBytes) = Decoder.decodeVarint(Array(bytes.dropFirst())) else {
            return nil
        }

        let messageStart = 1 + lengthBytes
        guard bytes.count >= messageStart + Int(length) else { return nil }

        let messageBytes = Array(bytes[messageStart..<(messageStart + Int(length))])

        // RemoteError structure:
        // field 1 (bool value) = has error
        // field 2 (RemoteMessage) = original request that caused error

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
                // Skip unknown field
                break
            }
        }

        return .error(RemoteErrorInfo(hasError: hasError, originalRequest: originalRequest))
    }

    /// Parse an AppLinkResponse message (field 8)
    /// This is the TV echoing back the deep link URI after processing
    private static func parseAppLinkResponse(_ bytes: [UInt8]) -> RemoteResponse? {
        guard bytes.count > 2, bytes[0] == appLinkResponseTag else { return nil }

        // Skip the tag byte and read the length
        guard let (length, lengthBytes) = Decoder.decodeVarint(Array(bytes.dropFirst())) else {
            return nil
        }

        let messageStart = 1 + lengthBytes
        guard bytes.count >= messageStart + Int(length) else { return nil }

        let messageBytes = Array(bytes[messageStart..<(messageStart + Int(length))])

        // Find the URI string embedded in the message
        // Look for field 1 (string) with tag 0x0a at various nesting levels
        if let uri = extractUriString(from: messageBytes) {
            return .appLinkResponse(uri: uri)
        }

        // If we can't extract URI, still return success since field 8 means app link was processed
        return .appLinkResponse(uri: "(parsed but URI not extracted)")
    }

    /// Recursively search for a URI string in protobuf message bytes
    private static func extractUriString(from bytes: [UInt8]) -> String? {
        var offset = 0

        while offset < bytes.count {
            let fieldTag = bytes[offset]
            offset += 1

            let fieldNumber = fieldTag >> 3
            let wireType = fieldTag & 0x07

            switch wireType {
            case 0: // Varint
                // Skip varint value
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

                // Check if this looks like a URI string (starts with scheme)
                if let str = String(bytes: fieldData, encoding: .utf8),
                   (str.contains("://") || str.hasPrefix("market:")) {
                    return str
                }

                // Try to find URI in nested message
                if let nestedUri = extractUriString(from: fieldData) {
                    return nestedUri
                }

                offset = fieldEnd

            default:
                // Unknown wire type, can't parse further
                return nil
            }
        }

        return nil
    }
}
