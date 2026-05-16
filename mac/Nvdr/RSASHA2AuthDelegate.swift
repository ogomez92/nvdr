import Foundation
import NIOCore
@preconcurrency import NIOSSH

/// Offers RSA private-key authentication with SHA-2 signatures, in
/// preference order: rsa-sha2-512 → rsa-sha2-256.
///
/// We deliberately do NOT fall back to ssh-rsa (SHA-1) here. The whole point
/// of installing this delegate is to talk to a server that already rejected
/// SHA-1; offering it again wastes a round trip and gets the connection
/// torn down with the same opaque "all auth methods failed".
///
/// Returning `nil` from `nextChallengePromise` tells NIOSSH that we have
/// nothing more to offer — the connection then fails cleanly.
final class RSASHA2AuthDelegate: NIOSSHClientUserAuthenticationDelegate {
    private let username: String
    private let pem: String
    private var attempt = 0

    init(username: String, openSSHPrivateKeyPEM: String) {
        self.username = username
        self.pem = openSSHPrivateKeyPEM
    }

    func nextAuthenticationType(
        availableMethods: NIOSSHAvailableUserAuthenticationMethods,
        nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
    ) {
        guard availableMethods.contains(.publicKey) else {
            nextChallengePromise.succeed(nil)
            return
        }

        do {
            switch attempt {
            case 0:
                attempt += 1
                let key = try RSASHA512PrivateKey(openSSHPEM: pem)
                let nio = NIOSSHPrivateKey(custom: key)
                nextChallengePromise.succeed(
                    NIOSSHUserAuthenticationOffer(
                        username: username, serviceName: "",
                        offer: .privateKey(.init(privateKey: nio))
                    )
                )
            case 1:
                attempt += 1
                let key = try RSASHA256PrivateKey(openSSHPEM: pem)
                let nio = NIOSSHPrivateKey(custom: key)
                nextChallengePromise.succeed(
                    NIOSSHUserAuthenticationOffer(
                        username: username, serviceName: "",
                        offer: .privateKey(.init(privateKey: nio))
                    )
                )
            default:
                nextChallengePromise.succeed(nil)
            }
        } catch {
            nextChallengePromise.fail(error)
        }
    }
}
