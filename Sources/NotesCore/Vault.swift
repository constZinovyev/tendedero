import CommonCrypto
import CryptoKit
import Foundation

public enum VaultError: LocalizedError, Equatable {
    case wrongPassword
    case weakPassword
    case damaged(String)
    case exists

    public var errorDescription: String? {
        switch self {
        case .wrongPassword: return "Неверный пароль."
        case .weakPassword: return "Пароль должен быть не короче \(Vault.minimumLength) символов."
        case .damaged(let what): return "Не удаётся прочитать \(what): файл повреждён или изменён."
        case .exists: return "Записная книжка уже под паролем."
        }
    }
}

/// The notebook's key, open: only ever in memory, and only after the
/// password. Pages and files are sealed with AES-256-GCM, each bound to
/// its own file name, so a sealed file cannot be swapped for another.
public final class VaultKey {
    private let sealing: SymmetricKey
    private let naming: SymmetricKey
    /// Kept only to be sealed again for Touch ID on this Mac.
    let master: SymmetricKey

    init(master: SymmetricKey) {
        self.master = master
        sealing = HKDF<SHA256>.deriveKey(inputKeyMaterial: master, info: Data("tendedero-notes-seal".utf8), outputByteCount: 32)
        naming = HKDF<SHA256>.deriveKey(inputKeyMaterial: master, info: Data("tendedero-notes-name".utf8), outputByteCount: 32)
    }

    public func seal(_ data: Data, as name: String) throws -> Data {
        guard let combined = try AES.GCM.seal(data, using: sealing, authenticating: Data(name.utf8)).combined else {
            throw VaultError.damaged(name)
        }
        return combined
    }

    public func open(_ data: Data, as name: String) throws -> Data {
        do {
            return try AES.GCM.open(AES.GCM.SealedBox(combined: data), using: sealing, authenticating: Data(name.utf8))
        } catch {
            throw VaultError.damaged(name)
        }
    }

    /// A file name that says nothing of what it holds, the same every time
    /// for the same thing.
    public func name(for value: String) -> String {
        HMAC<SHA256>.authenticationCode(for: Data(value.utf8), using: naming)
            .prefix(16).map { String(format: "%02x", $0) }.joined()
    }
}

/// `vault.json`: the notebook's key, sealed with a key made from the
/// password. Nothing in it reveals the password or the notes; the password
/// can be changed without touching a single page.
public enum Vault {
    public static let fileName = "vault.json"
    public static let minimumLength = 8
    /// About this long to try one password, on this Mac.
    static let targetMilliseconds: UInt32 = 700
    static let minimumRounds: UInt32 = 310_000

    struct Record: Codable {
        var version = 1
        var kdf = "pbkdf2-sha256"
        var rounds: UInt32
        var salt: Data
        var key: Data
    }

    private static let context = Data("tendedero-notes-vault-1".utf8)

    public static func exists(at root: URL) -> Bool {
        FileManager.default.fileExists(atPath: root.appendingPathComponent(fileName).path)
    }

    /// Makes a new key for the notebook and seals it with the password.
    public static func create(at root: URL, password: String, rounds: UInt32? = nil) throws -> VaultKey {
        guard !exists(at: root) else { throw VaultError.exists }
        guard password.count >= minimumLength else { throw VaultError.weakPassword }
        let master = SymmetricKey(size: .bits256)
        try write(master: master, password: password, rounds: rounds ?? calibratedRounds(), to: root)
        return VaultKey(master: master)
    }

    /// Opens the notebook's key. Slow on purpose: every guess costs the same.
    public static func unlock(at root: URL, password: String) throws -> VaultKey {
        VaultKey(master: try master(at: root, password: password))
    }

    public static func changePassword(at root: URL, from old: String, to new: String, rounds: UInt32? = nil) throws {
        guard new.count >= minimumLength else { throw VaultError.weakPassword }
        let master = try master(at: root, password: old)
        try write(master: master, password: new, rounds: rounds ?? calibratedRounds(), to: root)
    }

    private static func master(at root: URL, password: String) throws -> SymmetricKey {
        let data = try Data(contentsOf: root.appendingPathComponent(fileName))
        guard let record = try? JSONDecoder().decode(Record.self, from: data), record.kdf == "pbkdf2-sha256" else {
            throw VaultError.damaged(fileName)
        }
        let wrapping = derive(password, salt: record.salt, rounds: record.rounds)
        guard let box = try? AES.GCM.SealedBox(combined: record.key),
              let raw = try? AES.GCM.open(box, using: wrapping, authenticating: context) else {
            throw VaultError.wrongPassword
        }
        return SymmetricKey(data: raw)
    }

    private static func write(master: SymmetricKey, password: String, rounds: UInt32, to root: URL) throws {
        var salt = Data(count: 16)
        let status = salt.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }
        guard status == errSecSuccess else { throw VaultError.damaged("random") }
        let wrapping = derive(password, salt: salt, rounds: rounds)
        let raw = master.withUnsafeBytes { Data($0) }
        guard let sealed = try AES.GCM.seal(raw, using: wrapping, authenticating: context).combined else {
            throw VaultError.damaged(fileName)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(Record(rounds: rounds, salt: salt, key: sealed))
            .write(to: root.appendingPathComponent(fileName), options: .atomic)
    }

    static func derive(_ password: String, salt: Data, rounds: UInt32) -> SymmetricKey {
        // The same password typed with composed or decomposed letters is one password.
        let secret = Array(password.precomposedStringWithCanonicalMapping.utf8)
        var out = [UInt8](repeating: 0, count: 32)
        salt.withUnsafeBytes { s in
            _ = CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), secret.map { CChar(bitPattern: $0) }, secret.count,
                                     s.bindMemory(to: UInt8.self).baseAddress, salt.count,
                                     CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), rounds, &out, out.count)
        }
        defer { _ = out.withUnsafeMutableBytes { memset_s($0.baseAddress, 32, 0, 32) } }
        return SymmetricKey(data: out)
    }

    static func calibratedRounds() -> UInt32 {
        let rounds = CCCalibratePBKDF(CCPBKDFAlgorithm(kCCPBKDF2), 16, 16, CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), 32, targetMilliseconds)
        return max(rounds, minimumRounds)
    }
}
