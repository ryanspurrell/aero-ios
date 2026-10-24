import CryptoKit
import Foundation

/// The short code both screens show while a device is approved, so she can tell that the device asking is the one in her hand (as in Signal's
/// device linking). The ONE definition, the PC's `fingus_messages_store.approval_code` and the page's `approvalCode`: the first 8 bytes of
/// SHA-256 over the UTF-8 text "fingus device code v1|" + ecdh + "|" + sign (the two keys as the server stores them, base64url text), read as a
/// big-endian unsigned number, modulo 10^6, six digits with leading zeros. The approval signs this code in (`DeviceSigning.approvalText`).
enum DeviceCode {
    static func code(ecdh: String, sign: String) -> String {
        let hash = SHA256.hash(data: Data("fingus device code v1|\(ecdh)|\(sign)".utf8))
        let n = hash.prefix(8).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        let digits = String(n % 1_000_000)
        return String(repeating: "0", count: 6 - digits.count) + digits
    }

    /// "610 778": how it is written on a screen.
    static func shown(_ code: String) -> String { code.count == 6 ? String(code.prefix(3)) + " " + String(code.suffix(3)) : code }

    static func shown(ecdh: String, sign: String) -> String { shown(code(ecdh: ecdh, sign: sign)) }
}
