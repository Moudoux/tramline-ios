import CryptoKit
import Foundation
import Security

/// The phone's own client key and certificate, which the Pi allows by fingerprint, as
/// `tramline keygen` and `tramline allow` do for a computer. The private key is made in
/// the Secure Enclave, so it can't leave the phone. The simulator has no Secure Enclave,
/// so there, and only there, it's an ordinary keychain key that also stays on the device.
struct DeviceIdentity: @unchecked Sendable {
    let identity: SecIdentity
    let certificate: Data

    /// The SHA-256 of the certificate's DER in lowercase hex, which the Pi's allow list holds.
    var fingerprint: String { Fingerprint.of(certificate) }

    static let commonName = "tramline-iphone"
    private static let keyTag = Data("com.alar.tramline.client-key".utf8)
    private static let certLabel = "Tramline client certificate"

    enum IdentityError: LocalizedError {
        case keychain(String, OSStatus)
        case key(String)

        var errorDescription: String? {
            switch self {
            case let .keychain(what, status):
                let text = SecCopyErrorMessageString(status, nil) as String? ?? "error \(status)"
                return "Couldn't \(what): \(text)"
            case let .key(text):
                return text
            }
        }
    }

    /// The saved identity, or a new one made now.
    static func loadOrCreate() throws -> DeviceIdentity {
        let key = try loadKey() ?? createKey()
        guard let publicKey = SecKeyCopyPublicKey(key) else { throw IdentityError.key("The key has no public key.") }
        var error: Unmanaged<CFError>?
        guard let point = SecKeyCopyExternalRepresentation(publicKey, &error) as Data? else {
            throw IdentityError.key("Couldn't read the public key: \(error!.takeRetainedValue())")
        }

        let certDER: Data
        if let saved = try loadCertificate(), matches(saved, point: point) {
            certDER = saved
        } else {
            try deleteCertificates()
            certDER = try CertificateBuilder.build(publicKey: point, commonName: commonName) { tbs in
                var error: Unmanaged<CFError>?
                guard let sig = SecKeyCreateSignature(key, .ecdsaSignatureMessageX962SHA256, tbs as CFData, &error) else {
                    throw IdentityError.key("Couldn't sign the certificate: \(error!.takeRetainedValue())")
                }
                return sig as Data
            }
            try saveCertificate(certDER)
        }
        return DeviceIdentity(identity: try findIdentity(for: certDER), certificate: certDER)
    }

    /// Removes the key and certificate, so the next `loadOrCreate` makes a new pair, which
    /// the Pi then has to allow again.
    static func reset() throws {
        try deleteCertificates()
        let status = SecItemDelete([
            kSecClass: kSecClassKey,
            kSecAttrApplicationTag: keyTag,
        ] as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw IdentityError.keychain("remove the key", status)
        }
    }

    // MARK: Key

    private static func loadKey() throws -> SecKey? {
        var out: CFTypeRef?
        let status = SecItemCopyMatching([
            kSecClass: kSecClassKey,
            kSecAttrApplicationTag: keyTag,
            kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom,
            kSecReturnRef: true,
        ] as CFDictionary, &out)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let out else { throw IdentityError.keychain("read the key", status) }
        return (out as! SecKey)
    }

    private static func createKey() throws -> SecKey {
        var privateAttrs: [CFString: Any] = [
            kSecAttrIsPermanent: true,
            kSecAttrApplicationTag: keyTag,
        ]
        var attrs: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits: 256,
        ]
        #if targetEnvironment(simulator)
        privateAttrs[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        #else
        var error: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(
            nil, kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly, .privateKeyUsage, &error
        ) else {
            throw IdentityError.key("Couldn't set the key's access: \(error!.takeRetainedValue())")
        }
        privateAttrs[kSecAttrAccessControl] = access
        attrs[kSecAttrTokenID] = kSecAttrTokenIDSecureEnclave
        #endif
        attrs[kSecPrivateKeyAttrs] = privateAttrs

        var error2: Unmanaged<CFError>?
        guard let key = SecKeyCreateRandomKey(attrs as CFDictionary, &error2) else {
            throw IdentityError.key("Couldn't make a key: \(error2!.takeRetainedValue())")
        }
        return key
    }

    // MARK: Certificate

    private static func loadCertificate() throws -> Data? {
        var out: CFTypeRef?
        let status = SecItemCopyMatching([
            kSecClass: kSecClassCertificate,
            kSecAttrLabel: certLabel,
            kSecReturnData: true,
        ] as CFDictionary, &out)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = out as? Data else {
            throw IdentityError.keychain("read the certificate", status)
        }
        return data
    }

    private static func saveCertificate(_ der: Data) throws {
        guard let cert = SecCertificateCreateWithData(nil, der as CFData) else {
            throw IdentityError.key("The new certificate doesn't parse.")
        }
        let status = SecItemAdd([
            kSecClass: kSecClassCertificate,
            kSecValueRef: cert,
            kSecAttrLabel: certLabel,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ] as CFDictionary, nil)
        guard status == errSecSuccess else { throw IdentityError.keychain("save the certificate", status) }
    }

    private static func deleteCertificates() throws {
        let status = SecItemDelete([
            kSecClass: kSecClassCertificate,
            kSecAttrLabel: certLabel,
        ] as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw IdentityError.keychain("remove the certificate", status)
        }
    }

    /// Whether a saved certificate is for this key, in case the key was replaced.
    private static func matches(_ der: Data, point: Data) -> Bool {
        guard let cert = SecCertificateCreateWithData(nil, der as CFData),
              let key = SecCertificateCopyKey(cert),
              let saved = SecKeyCopyExternalRepresentation(key, nil) as Data?
        else { return false }
        return saved == point
    }

    /// The keychain pairs the certificate with its key by the public key's hash. The
    /// identity is the one whose certificate is ours, rather than trusting a label.
    private static func findIdentity(for der: Data) throws -> SecIdentity {
        var out: CFTypeRef?
        let status = SecItemCopyMatching([
            kSecClass: kSecClassIdentity,
            kSecMatchLimit: kSecMatchLimitAll,
            kSecReturnRef: true,
        ] as CFDictionary, &out)
        guard status == errSecSuccess, let list = out as? [SecIdentity] else {
            throw IdentityError.keychain("find the key and certificate together", status)
        }
        for identity in list {
            var cert: SecCertificate?
            if SecIdentityCopyCertificate(identity, &cert) == errSecSuccess, let cert,
               SecCertificateCopyData(cert) as Data == der {
                return identity
            }
        }
        throw IdentityError.key("The keychain didn't pair the certificate with its key.")
    }
}

enum Fingerprint {
    static func of(_ der: Data) -> String {
        SHA256.hash(data: der).map { String(format: "%02x", $0) }.joined()
    }

    /// A fingerprint as the CLI prints it: 64 lowercase hex characters. Spaces, colons and
    /// capitals are taken out first, for one pasted from somewhere else.
    static func normalized(_ text: String) -> String? {
        let cleaned = text.lowercased().filter { !" :\n\t".contains($0) }
        guard cleaned.count == 64, cleaned.allSatisfy(\.isHexDigit) else { return nil }
        return cleaned
    }

    /// Constant-time comparison, for the server's fingerprint.
    static func equal(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        var diff: UInt8 = 0
        for i in x.indices { diff |= x[i] ^ y[i] }
        return diff == 0
    }
}
