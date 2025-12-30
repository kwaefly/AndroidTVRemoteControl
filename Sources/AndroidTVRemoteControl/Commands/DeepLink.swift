//
//  DeepLink.swift
//
//
//  Created by Roman Odyshew on 08.11.2023.
//  Modified for PWApp fork - added package targeting support
//

import Foundation

public struct DeepLink {
    let url: String
    /// Optional package name to force the URL to open in a specific app
    /// This is an experimental extension - the TV may or may not respect it
    let package: String?

    public init(_ url: String, package: String? = nil) {
        self.url = url
        self.package = package
    }

    public init(_ url: URL, package: String? = nil) {
        self.url = url.absoluteString
        self.package = package
    }
}

extension DeepLink: RequestDataProtocol {
    public var data: Data {
        // RemoteAppLinkLaunchRequest is field 90 in RemoteMessage
        // Field 90 with wire type 2 (length-delimited) = (90 << 3) | 2 = 722
        // Varint 722 = [0xd2, 0x05]

        // Build the inner message first
        var innerMessage = Data()

        // Field 1: app_link (string)
        // Field 1, wire type 2 = (1 << 3) | 2 = 10 = 0x0a
        innerMessage.append(0x0a)
        innerMessage.append(contentsOf: Encoder.encodeVarint(UInt(url.count)))
        innerMessage.append(contentsOf: url.utf8)

        // Field 2: package (string) - EXPERIMENTAL
        // Field 2, wire type 2 = (2 << 3) | 2 = 18 = 0x12
        if let pkg = package, !pkg.isEmpty {
            innerMessage.append(0x12)
            innerMessage.append(contentsOf: Encoder.encodeVarint(UInt(pkg.count)))
            innerMessage.append(contentsOf: pkg.utf8)
        }

        // Build the outer message
        var data = Data([0xd2, 0x05])  // Field 90 tag
        data.append(contentsOf: Encoder.encodeVarint(UInt(innerMessage.count)))
        data.append(innerMessage)

        return data
    }
}
