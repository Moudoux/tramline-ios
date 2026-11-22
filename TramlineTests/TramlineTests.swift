import Foundation
import Security
import Testing
@testable import Tramline

private func fixture(_ name: String) throws -> Data {
    let url = try #require(Bundle(for: BundleToken.self).url(forResource: name, withExtension: "json"))
    return try Data(contentsOf: url)
}

private final class BundleToken {}

@Suite struct Decoding {
    @Test func statusCapturedFromTheSimulator() throws {
        let off = try JSON.decoder.decode(StatusResponse.self, from: fixture("status-off"))
        #expect(off.simulated == true)
        #expect(off.plug?.on == false)

        let heating = try JSON.decoder.decode(StatusResponse.self, from: fixture("status-heating"))
        #expect(heating.printer.connected)
        #expect(heating.printer.temps?.bedTarget == 60)
        #expect(heating.heatersOffAt != nil)
    }

    @Test func webStatus() throws {
        let idle = try JSON.decoder.decode(WebStatus.self, from: fixture("web-idle"))
        #expect(!idle.connected)
        let running = try JSON.decoder.decode(WebStatus.self, from: fixture("web-running"))
        #expect(running.print?.state == "running")
        #expect(running.print?.runSeconds == 754.2)
        #expect(running.scheduled?.count == 1)
    }

    @Test func adjustingWithNanosecondTimes() throws {
        let st = try JSON.decoder.decode(StatusResponse.self, from: fixture("status-adjusting"))
        #expect(st.print?.state == "adjusting")
        #expect(st.print?.check?.corner == "front-left")
        #expect(st.tram?.rounds?.first?.readings?.count == 4)
        #expect(st.scheduled?.first?.state == "waiting")
        let at = try #require(st.printer.tempsAt)
        #expect(abs(at.timeIntervalSince1970 - 1_794_598_201.123) < 0.001)
    }

    @Test func filesAndCard() throws {
        let off = try JSON.decoder.decode(FilesResponse.self, from: fixture("files-off"))
        #expect(off.card == nil)
        #expect(off.cardNote == "the printer isn't connected")
        #expect(off.files?.first?.info.lines == 648)
        let on = try JSON.decoder.decode(FilesResponse.self, from: fixture("files-on"))
        #expect(on.card == [])
        let rec = try JSON.decoder.decode(FileRecord.self, from: fixture("file-record"))
        #expect(rec.sdName == "TESTBO88.GCO")
    }

    @Test func meshAndSmallAnswers() throws {
        let mesh = try JSON.decoder.decode(MeshInfo.self, from: fixture("mesh"))
        let report = try #require(mesh.mesh)
        #expect(report.z.count == 5)
        #expect(abs(Words.meshRange(report) - 0.22) < 1e-9)
        #expect(Words.meshText(report).contains("Range 0.220 mm"))
        _ = try JSON.decoder.decode(PreheatResponse.self, from: fixture("preheat"))
        _ = try JSON.decoder.decode(CoolResponse.self, from: fixture("cool"))
        #expect(try JSON.decoder.decode([ScheduledPrint].self, from: fixture("schedule-empty")).isEmpty)
    }
}

@Suite struct Wording {
    @Test(arguments: [
        ("fit test (v2).gcode", "fit_test_v2.gcode"),
        ("part.GCO", "part.gco"),
        ("--weird--.gcode", "weird.gcode"),
        ("((( ))).gcode", "print.gcode"),
        ("nogcode", "nogcode.gcode"),
    ])
    func safeName(input: String, expected: String) {
        #expect(Words.safeName(input) == expected)
        #expect(Limits.isFileName(Words.safeName(input)))
    }

    @Test func clockAndTemp() {
        #expect(Words.clock(3725) == "1 h 2 min")
        #expect(Words.clock(250) == "4 min 10 s")
        #expect(Words.clock(9) == "9 s")
        #expect(Words.clock(-1) == "–")
        #expect(Words.temp(61.54, 80) == "61.5 / 80 °C")
        #expect(Words.temp(21, 0) == "21.0 °C")
        #expect(Words.sentence("the plug is off") == "The plug is off.")
        #expect(Words.bytes(20026) == "20 KB")
    }

    @Test func fileNames() {
        #expect(Limits.isFileName("test_box.gcode"))
        #expect(!Limits.isFileName("_hidden.gcode"))
        #expect(!Limits.isFileName("a b.gcode"))
    }
}

@Suite struct Logins {
    @Test func hosts() {
        #expect(Login.normalizeHost("raspberrypi") == "raspberrypi:8726")
        #expect(Login.normalizeHost(" https://pi.tail1234.ts.net:8726/ ") == "pi.tail1234.ts.net:8726")
        #expect(Login.normalizeHost("100.64.0.7:9000") == "100.64.0.7:9000")
        #expect(Login.normalizeHost("[fd7a:115c::1]") == "[fd7a:115c::1]:8726")
        #expect(Login.normalizeHost("") == nil)
    }

    @Test func scanned() throws {
        let fp = String(repeating: "ab", count: 32)
        #expect(Login.parseScanned(fp.uppercased())?.fingerprint == fp)
        let parsed = try #require(Login.parseScanned("tramline://login?url=https://raspberrypi:8726&fp=\(fp)"))
        #expect(parsed.hosts == ["raspberrypi:8726"])
        #expect(parsed.fingerprint == fp)
        #expect(Login.parseScanned("hello") == nil)
    }
}

@Suite struct Certificate {
    @Test func buildsAParsableCertificate() throws {
        var error: Unmanaged<CFError>?
        let key = try #require(SecKeyCreateRandomKey([
            kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom, kSecAttrKeySizeInBits: 256,
        ] as CFDictionary, &error))
        let point = try #require(SecKeyCopyExternalRepresentation(SecKeyCopyPublicKey(key)!, nil) as Data?)
        var signedTBS = Data()
        var signature = Data()
        let der = try CertificateBuilder.build(publicKey: point, commonName: "tramline-iphone",
                                               serial: Data(repeating: 0xff, count: 16)) { tbs in
            signedTBS = tbs
            signature = SecKeyCreateSignature(key, .ecdsaSignatureMessageX962SHA256, tbs as CFData, nil)! as Data
            return signature
        }
        let cert = try #require(SecCertificateCreateWithData(nil, der as CFData))
        #expect(SecCertificateCopySubjectSummary(cert) as String? == "tramline-iphone")
        let certKey = try #require(SecCertificateCopyKey(cert))
        #expect(SecKeyCopyExternalRepresentation(certKey, nil) as Data? == point)
        #expect(SecKeyVerifySignature(certKey, .ecdsaSignatureMessageX962SHA256, signedTBS as CFData, signature as CFData, nil))
        #expect(Fingerprint.of(der).count == 64)
    }

    @Test func derLengthsAndTimes() {
        #expect(DER.tlv(0x04, Data(count: 200)).prefix(3) == Data([0x04, 0x81, 200]))
        #expect(DER.tlv(0x04, Data(count: 300)).prefix(4) == Data([0x04, 0x82, 0x01, 0x2c]))
        #expect(DER.oid("1.2.840.10045.4.3.2") == Data([0x06, 0x08, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x04, 0x03, 0x02]))
        #expect(DER.time(Date(timeIntervalSince1970: 0)).first == 0x17)
        #expect(DER.time(Date(timeIntervalSince1970: 2_600_000_000)).first == 0x18)
    }
}
