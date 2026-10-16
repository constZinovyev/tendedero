import CryptoKit
import Foundation
import LocalAuthentication

/// Opening the notebook with a finger on this Mac. The password is never
/// kept: the notebook's key is sealed to a key that lives in the Secure
/// Enclave and works only after Touch ID, and only on this Mac. New
/// fingerprints added later void it; the password always still works.
///
/// The file holds the enclave key's handle (useless off this Mac), a
/// one-off public key and the sealed notebook key.
public enum Fingerprint {
    struct Record: Codable {
        var version = 1
        var enclaveKey: Data
        var ephemeral: Data
        var sealed: Data
    }

    private static let info = Data("tendedero-notes-touchid-1".utf8)

    /// Whether this Mac has Touch ID set up and a Secure Enclave.
    public static var isAvailable: Bool {
        var error: NSError?
        return SecureEnclave.isAvailable
            && LAContext().canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)
    }

    public static func isEnabled(_ file: URL) -> Bool { FileManager.default.fileExists(atPath: file.path) }

    /// Seals the open notebook's key for Touch ID. Asks for nothing.
    public static func enable(for key: VaultKey, file: URL) throws {
        guard let access = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
                                                           [.privateKeyUsage, .biometryCurrentSet], nil) else {
            throw VaultError.damaged("Touch ID")
        }
        let enclave = try SecureEnclave.P256.KeyAgreement.PrivateKey(accessControl: access)
        let (ephemeral, sealed) = try wrap(key.master, to: enclave.publicKey)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(Record(enclaveKey: enclave.dataRepresentation, ephemeral: ephemeral, sealed: sealed))
        try data.write(to: file, options: [.atomic, .completeFileProtection])
    }

    /// Asks for a finger and opens the notebook's key. Blocks until the
    /// finger or a cancel: call it off the main thread.
    public static func unlock(file: URL, reason: String) throws -> VaultKey {
        guard let record = try? JSONDecoder().decode(Record.self, from: Data(contentsOf: file)) else {
            throw VaultError.damaged("Touch ID")
        }
        let context = LAContext()
        context.localizedReason = reason
        let enclave = try SecureEnclave.P256.KeyAgreement.PrivateKey(dataRepresentation: record.enclaveKey, authenticationContext: context)
        let ephemeral = try P256.KeyAgreement.PublicKey(x963Representation: record.ephemeral)
        let shared = try enclave.sharedSecretFromKeyAgreement(with: ephemeral)
        return VaultKey(master: try unwrap(record.sealed, shared: shared, ephemeral: record.ephemeral))
    }

    public static func disable(file: URL) { try? FileManager.default.removeItem(at: file) }

    // MARK: Sealing, without the enclave so it can be tested

    static func wrap(_ master: SymmetricKey, to recipient: P256.KeyAgreement.PublicKey) throws -> (ephemeral: Data, sealed: Data) {
        let ephemeral = P256.KeyAgreement.PrivateKey()
        let shared = try ephemeral.sharedSecretFromKeyAgreement(with: recipient)
        let publicData = ephemeral.publicKey.x963Representation
        let raw = master.withUnsafeBytes { Data($0) }
        guard let sealed = try AES.GCM.seal(raw, using: wrapping(shared, publicData), authenticating: info).combined else {
            throw VaultError.damaged("Touch ID")
        }
        return (publicData, sealed)
    }

    static func unwrap(_ sealed: Data, shared: SharedSecret, ephemeral: Data) throws -> SymmetricKey {
        guard let box = try? AES.GCM.SealedBox(combined: sealed),
              let raw = try? AES.GCM.open(box, using: wrapping(shared, ephemeral), authenticating: info) else {
            throw VaultError.damaged("Touch ID")
        }
        return SymmetricKey(data: raw)
    }

    private static func wrapping(_ shared: SharedSecret, _ ephemeral: Data) -> SymmetricKey {
        shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: ephemeral, sharedInfo: info, outputByteCount: 32)
    }
}
