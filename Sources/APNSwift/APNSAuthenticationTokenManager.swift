//===----------------------------------------------------------------------===//
//
// This source file is part of the APNSwift open source project
//
// Copyright (c) 2022 the APNSwift project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of APNSwift project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import Crypto
import Dispatch
import Logging
import NIOConcurrencyHelpers

/// A class to manage the authentication tokens for a single APNS connection.
final class APNSAuthenticationTokenManager {
    private struct Token {
        /// This is the actual JWT token prefixed with `bearer`.
        ///
        /// This is stored as a ``String`` since we use it as an HTTP headers.
        var token: String
        var issuedAt: DispatchWallTime
    }

    /// APNS rejects any token that is more than 1 hour old. We set the duration to be slightly less to refresh earlier.
    private static let expirationDurationInSeconds: Int = 60 * 55

    /// The private key used for signing the tokens.
    private let privateKey: P256.Signing.PrivateKey
    /// The private key's team identifier.
    private let teamIdentifier: String
    /// The private key's identifier.
    private let keyIdentifier: String
    /// The logger.
    private let logger: Logger
    /// A closure to get the current time. This allows for properly testing the behaviour.
    /// Furthermore, we can expose this to clients at some point if they want to provide an NTP synced date.
    private let currentTimeFactory: () -> DispatchWallTime

    /// The lock used to protect access to the ``lastGeneratedToken``.
    private let lock = Lock()

    /// The last generated token.
    private var lastGeneratedToken: Token?

    /// Initializes a new ``APNSAuthenticationTokenManager``.
    ///
    /// - Parameters:
    ///   - privateKey: The private key used for signing the tokens.
    ///   - teamIdentifier: The private key's team identifier.
    ///   - keyIdentifier: The private key's identifier.
    ///   - logger: The logger.
    ///   - currentTimeFactory: A closure to get the current time.
    init(
        privateKey: P256.Signing.PrivateKey,
        teamIdentifier: String,
        keyIdentifier: String,
        logger: Logger,
        currentTimeFactory: @escaping () -> DispatchWallTime = { .now() }
    ) {
        self.privateKey = privateKey
        self.teamIdentifier = teamIdentifier
        self.keyIdentifier = keyIdentifier
        self.logger = logger
        self.currentTimeFactory = currentTimeFactory
    }

    /// This returns the next valid token.
    ///
    /// If there is a previously generated token that is still valid it will be returned, otherwise a fresh token will be generated.
    var nextValidToken: String {
        get throws {
            // First we check if there is a previously generated token
            // and if that token is still valid.
            if let lastGeneratedToken = lastGeneratedToken,
               self.currentTimeFactory().asSecondsSince1970 - lastGeneratedToken.issuedAt.asSecondsSince1970 < Self
               .expirationDurationInSeconds
            {
                // The last generated token is still valid

                logger.debug(
                    "APNSAuthenticationTokenManager reusing previously generated token",
                    metadata: [
                        LoggingKeys.authenticationTokenIssuedAt: "\(lastGeneratedToken.issuedAt)",
                        LoggingKeys.authenticationTokenIssuer: "\(teamIdentifier)",
                        LoggingKeys.authenticationTokenKeyID: "\(keyIdentifier)",
                    ]
                )
                return lastGeneratedToken.token
            } else {
                let token = try generateNewToken(
                    privateKey: privateKey,
                    teamIdentifier: teamIdentifier,
                    keyIdentifier: keyIdentifier
                )
                lastGeneratedToken = token

                return token.token
            }
        }
    }

    private func generateNewToken(
        privateKey: P256.Signing.PrivateKey,
        teamIdentifier: String,
        keyIdentifier: String
    ) throws -> Token {
        let header = """
        {
            "alg": "ES256",
            "typ": "JWT",
            "kid": "\(keyIdentifier)"
        }
        """

        let issueAtTime = currentTimeFactory()
        let payload = """
        {
            "iss": "\(teamIdentifier)",
            "iat": "\(issueAtTime.asSecondsSince1970)",
            "kid": "\(keyIdentifier)"
        }
        """

        // The header and the payload need to be base64 encoded
        // before we can sign them
        let encodedHeader = Base64.encodeBytes(bytes: header.utf8, options: [.base64UrlAlphabet, .omitPaddingCharacter])
        let encodedPayload = Base64.encodeBytes(
            bytes: payload.utf8,
            options: [.base64UrlAlphabet, .omitPaddingCharacter]
        )
        let period = UInt8(ascii: ".")

        var encodedData = [UInt8]()
        /// This should fit the whole JWT token. I arrived at the number
        /// by generating a bunch of tokens and took the upper limit + some.
        encodedData.reserveCapacity(400)
        encodedData.append(contentsOf: encodedHeader)
        encodedData.append(period)
        encodedData.append(contentsOf: encodedPayload)

        let signatureData = try privateKey.signature(for: encodedData)
        let base64Signature = Base64.encodeBytes(
            bytes: signatureData.rawRepresentation,
            options: [.base64UrlAlphabet, .omitPaddingCharacter]
        )

        encodedData.append(period)
        encodedData.append(contentsOf: base64Signature)

        logger.debug(
            "APNSAuthenticationTokenManager generated new token",
            metadata: [
                LoggingKeys.authenticationTokenIssuedAt: "\(issueAtTime)",
                LoggingKeys.authenticationTokenIssuer: "\(teamIdentifier)",
                LoggingKeys.authenticationTokenKeyID: "\(keyIdentifier)",
            ]
        )

        // We are prefixing the token here to avoid an additional
        // allocation for setting the header.
        return Token(
            token: "bearer " + String(decoding: encodedData, as: UTF8.self),
            issuedAt: issueAtTime
        )
    }
}

private extension DispatchWallTime {
    var asSecondsSince1970: Int64 {
        -Int64(bitPattern: rawValue) / 1_000_000_000
    }
}
