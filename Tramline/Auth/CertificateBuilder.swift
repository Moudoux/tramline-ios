import Foundation

/// Builds the phone's self-signed client certificate, as `secure.KeyGen` does for a
/// computer, see `tramline/internal/secure/secure.go`. The Security framework can't make
/// certificates, so this is a small DER encoder. The server trusts the certificate by its
/// SHA-256 fingerprint only, but Go still parses it and checks the handshake signature,
/// so it has to be a well-formed X.509 v3 certificate.
///
/// The key itself stays wherever `sign` keeps it: in the Secure Enclave on a phone.
enum CertificateBuilder {
    enum BuildError: Error {
        case badPublicKey
    }

    /// - Parameters:
    ///   - publicKey: the 65-byte uncompressed P-256 point, as `SecKeyCopyExternalRepresentation` gives.
    ///   - commonName: the subject and issuer's CN.
    ///   - now: when the certificate is made; it's valid from an hour before, for 20 years.
    ///   - serial: 16 random bytes; the top bit is cleared so the serial is positive.
    ///   - sign: signs the DER it's given with ECDSA over SHA-256, returning a DER signature.
    /// - Returns: the certificate's DER.
    static func build(
        publicKey: Data,
        commonName: String,
        now: Date = Date(),
        serial: Data = randomSerial(),
        sign: (Data) throws -> Data
    ) throws -> Data {
        guard publicKey.count == 65, publicKey.first == 0x04 else { throw BuildError.badPublicKey }

        var serialBytes = [UInt8](serial)
        serialBytes[0] &= 0x7f
        // DER integers are minimal, so leading zero bytes go, but keep one byte.
        while serialBytes.count > 1, serialBytes[0] == 0, serialBytes[1] & 0x80 == 0 {
            serialBytes.removeFirst()
        }

        let ecdsaWithSHA256 = DER.sequence([DER.oid("1.2.840.10045.4.3.2")])
        let name = DER.sequence([
            DER.set([
                DER.sequence([DER.oid("2.5.4.3"), DER.utf8String(commonName)]),
            ]),
        ])
        let notBefore = now.addingTimeInterval(-3600)
        let notAfter = Calendar(identifier: .gregorian).date(byAdding: .year, value: 20, to: now)!
        let validity = DER.sequence([DER.time(notBefore), DER.time(notAfter)])
        let spki = DER.sequence([
            DER.sequence([DER.oid("1.2.840.10045.2.1"), DER.oid("1.2.840.10045.3.1.7")]),
            DER.bitString(publicKey),
        ])
        // keyUsage, critical: digitalSignature only. Bit 0 of the BIT STRING, with 7 unused bits.
        let keyUsage = DER.sequence([
            DER.oid("2.5.29.15"),
            DER.boolean(true),
            DER.octetString(DER.tlv(0x03, Data([0x07, 0x80]))),
        ])
        // extKeyUsage: clientAuth.
        let extKeyUsage = DER.sequence([
            DER.oid("2.5.29.37"),
            DER.octetString(DER.sequence([DER.oid("1.3.6.1.5.5.7.3.2")])),
        ])
        let tbs = DER.sequence([
            DER.tlv(0xa0, DER.integer(Data([0x02]))), // [0] version v3
            DER.integer(Data(serialBytes)),
            ecdsaWithSHA256,
            name, // issuer
            validity,
            name, // subject
            spki,
            DER.tlv(0xa3, DER.sequence([keyUsage, extKeyUsage])), // [3] extensions
        ])
        let signature = try sign(tbs)
        return DER.sequence([tbs, ecdsaWithSHA256, DER.bitString(signature)])
    }

    static func randomSerial() -> Data {
        var bytes = [UInt8](repeating: 0, count: 16)
        for i in bytes.indices { bytes[i] = UInt8.random(in: 0...255) }
        return Data(bytes)
    }

    /// The certificate as PEM, for showing or testing with curl.
    static func pem(_ der: Data) -> String {
        let base64 = der.base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed])
        return "-----BEGIN CERTIFICATE-----\n\(base64)\n-----END CERTIFICATE-----\n"
    }
}

/// Just enough DER for a certificate.
enum DER {
    static func tlv(_ tag: UInt8, _ content: Data) -> Data {
        var out = Data([tag])
        let n = content.count
        if n < 0x80 {
            out.append(UInt8(n))
        } else {
            var len = [UInt8]()
            var v = n
            while v > 0 { len.insert(UInt8(v & 0xff), at: 0); v >>= 8 }
            out.append(0x80 | UInt8(len.count))
            out.append(contentsOf: len)
        }
        out.append(content)
        return out
    }

    static func sequence(_ items: [Data]) -> Data { tlv(0x30, items.reduce(Data(), +)) }
    static func set(_ items: [Data]) -> Data { tlv(0x31, items.reduce(Data(), +)) }
    static func boolean(_ v: Bool) -> Data { tlv(0x01, Data([v ? 0xff : 0x00])) }
    static func octetString(_ d: Data) -> Data { tlv(0x04, d) }
    static func utf8String(_ s: String) -> Data { tlv(0x0c, Data(s.utf8)) }
    /// A BIT STRING with no unused bits.
    static func bitString(_ d: Data) -> Data { tlv(0x03, Data([0x00]) + d) }

    /// An INTEGER from big-endian bytes, which must already be minimal and positive.
    static func integer(_ bytes: Data) -> Data {
        var b = bytes
        if let first = b.first, first & 0x80 != 0 { b.insert(0x00, at: 0) }
        return tlv(0x02, b)
    }

    static func oid(_ dotted: String) -> Data {
        let parts = dotted.split(separator: ".").map { UInt64($0)! }
        var out = Data([UInt8(parts[0] * 40 + parts[1])])
        for var v in parts.dropFirst(2) {
            var chunk = [UInt8(v & 0x7f)]
            v >>= 7
            while v > 0 {
                chunk.insert(UInt8(v & 0x7f) | 0x80, at: 0)
                v >>= 7
            }
            out.append(contentsOf: chunk)
        }
        return tlv(0x06, out)
    }

    /// UTCTime before 2050 and GeneralizedTime from 2050, as RFC 5280 requires.
    static func time(_ date: Date) -> Data {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let year = cal.component(.year, from: date)
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        if year < 2050 {
            f.dateFormat = "yyMMddHHmmss'Z'"
            return tlv(0x17, Data(f.string(from: date).utf8))
        }
        f.dateFormat = "yyyyMMddHHmmss'Z'"
        return tlv(0x18, Data(f.string(from: date).utf8))
    }
}
