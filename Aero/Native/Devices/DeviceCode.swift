import Foundation

/// The short code both screens show while a device is approved, so she can tell that the device asking is the one in her hand (as in Signal's
/// device linking). Derived from the waiting device's public keys only.
///
/// PROVISIONAL: the PC side's function (Fingus branch remove-atomic) had not landed on main when this was written, so this uses the app's
/// existing safety-code function over the one device's keys. It is kept in this one place; when the PC's function and its test vector land,
/// replace the body and add the vector test (DeviceCodeTests).
enum DeviceCode {
    static func code(ecdh: String, sign: String) -> String {
        ChatCrypto.safetyCode([(ecdh: ecdh, sign: sign)])
    }
}
