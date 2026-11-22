# Signing in to the Pi

Part of the Tramline iOS notes, see the [index](../README.md).

## What the server expects

From `tramline/internal/secure/secure.go` and `tramline/notes/security.md`:

- **Mutual TLS, TLS 1.3 only,** on port 8726. There's no token or password, and the user chose that over a shared token.
- **The client's certificate is trusted by fingerprint:** the SHA-256 of its DER, as 64 lowercase hex characters, which must be in `/var/lib/tramline/clients.allow`. The server uses `tls.RequireAnyClientCert`, so there's no chain or CA check, but Go still parses the certificate with `x509.ParseCertificate` and checks the handshake signature. The list is read on every connection and request, so allowing or revoking needs no restart.
- **The server's certificate is self-signed,** P-256 ECDSA, with only an IP address in its SAN. Clients pin its fingerprint, given at login, and skip the normal hostname and chain checks (`secure.ClientTLS`).
- The desktop client's own key is P-256 ECDSA, PKCS#8, with a 20-year self-signed certificate, CN `tramline-client`, key usage digitalSignature, extended key usage clientAuth (`secure.KeyGen`).

## The plan for the phone

It's the same scheme as a new computer, see "Setting up a new computer" in the repository README. **The private key never leaves the phone,** which the Secure Enclave makes literally true.

1. **Make a key in the Secure Enclave:** P-256, `kSecAttrTokenIDSecureEnclave`, permanent in the keychain, `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`, so it isn't in backups and can't move to another phone. The iOS Simulator has no Secure Enclave, so fall back to an ordinary keychain key there, and only there.
2. **Make a self-signed certificate for it in code.** The Security framework can't create certificates, so write a small DER encoder (around 150 lines) rather than add a package:
   - TBSCertificate: version v3 (`[0] INTEGER 2`), a 16-byte random serial with the top bit cleared so it's positive (Go refuses negative serials), signature algorithm `ecdsa-with-SHA256` (1.2.840.10045.4.3.2, no parameters), issuer and subject both `CN=tramline-iphone`, validity from an hour ago for 20 years (UTCTime before 2050, GeneralizedTime from 2050), the subject public key info (`id-ecPublicKey` 1.2.840.10045.2.1 with `prime256v1` 1.2.840.10045.3.1.7, and the 65-byte uncompressed point from `SecKeyCopyExternalRepresentation` in a BIT STRING), and the extensions in `[3]`: keyUsage, critical, digitalSignature, and extKeyUsage clientAuth (1.3.6.1.5.5.7.3.2).
   - Sign the TBS DER with `SecKeyCreateSignature(key, .ecdsaSignatureMessageX962SHA256, ...)`, which gives a DER ECDSA signature, and wrap that in a BIT STRING.
3. **Store the certificate in the keychain** next to the key, so the system pairs them as a `SecIdentity`. Read the identity back with `kSecClassIdentity` and pick the one whose certificate's data is ours, rather than relying on a label match.
4. **Show the phone's fingerprint** (SHA-256 of the certificate DER) with a copy button and a share sheet, and the exact command for the Pi:

   ```sh
   sudo -u tramline tramline allow <phone-fingerprint> --name iphone
   ```

   The user runs that themselves, as Claude never runs sudo on the Pi.
5. **Ask for the server's address and fingerprint.** The fingerprint comes from `sudo -u tramline tramline fingerprint` on the Pi, or from the user's Mac. 64 hex characters are painful to type on a phone, so offer, in order of preference:
   - **Scan a QR code.** No command shows one today. A Mac one-liner can make one without touching the server, for example `qrencode -t ansiutf8 "tramline://login?url=https://raspberrypi:8726&fp=<fingerprint>"`, if `qrencode` is installed. A `tramline qr` command would be nicer, but that's a change to Tramline, so ask first.
   - Paste, with the field checking it's 64 hex characters.
   - **Don't offer trust-on-first-use,** where the phone saves whatever the server presents. The CLI deliberately gets the fingerprint at login instead of from the first connection, see Security.
6. **Log in** like `tramline login` does: `GET /v1/status` with both checks. Explain a 403 the way `client.Explain` does: this phone isn't allowed yet, run the allow command above.
7. **Save the login** (URL and server fingerprint) in the keychain or in app storage. They're not secret, but the keychain keeps them off backups as well.

**Two addresses:** the user reaches the Pi as `raspberrypi` on the LAN and over Tailscale on 5G, see "Listening by interface" in Tramline's notes. The server's certificate is the same on both, so the pinned fingerprint is too. Let the login hold a list of URLs and try them in order, or just one URL using the Tailscale MagicDNS name, which works at home as well if the phone runs Tailscale. Ask the user which they'd like.

## The URLSession side

- One `URLSession` with a delegate that handles both challenges:
  - `NSURLAuthenticationMethodServerTrust`: take the leaf certificate from `SecTrustCopyCertificateChain`, hash `SecCertificateCopyData`, compare with the saved fingerprint in constant time, and answer `.useCredential` with `URLCredential(trust:)` on a match and `.cancelAuthenticationChallenge` otherwise. Don't call `SecTrustEvaluate`, as the certificate is self-signed.
  - `NSURLAuthenticationMethodClientCertificate`: answer with `URLCredential(identity:certificates: nil, persistence: .forSession)`.
- **Set `tlsMinimumSupportedProtocolVersion = .TLSv13`** on the configuration, to match the server.
- **No redirects:** the CLI refuses them, so the delegate's `willPerformHTTPRedirection` returns nil.
- **Timeouts as in `internal/client/client.go`:** 30 s normally, 4 min for cool, cancel and cancelling a schedule (a move can take 3 minutes to finish), 2 min for print, continue and schedule, 30 s for estop, and 30 min for an upload.
- **Face ID** isn't needed to sign in: the Secure Enclave key is usable while the phone is unlocked. If the user wants Face ID for dangerous actions, `.biometryCurrentSet` on the key would ask for every request, including polls, which is unworkable. Use `LAContext` before the action itself instead, and keep the key as it is.

## App Transport Security

- The API is HTTPS to an IP address or an unqualified name with a self-signed certificate, and the read-only page's endpoints are **plain HTTP** (see [api.md](api.md)). Both need ATS settings in `Info.plist`:
  - `NSAllowsLocalNetworking = YES` covers unqualified names like `raspberrypi`, `.local` names and IP addresses.
  - A Tailscale MagicDNS name such as `raspberrypi.<tailnet>.ts.net` is fully qualified, so it needs an `NSExceptionDomains` entry for `ts.net` with `NSIncludesSubdomains` and `NSExceptionAllowsInsecureHTTPLoads`. Plain HTTP over Tailscale is still encrypted by WireGuard.
  - **Don't use `NSAllowsArbitraryLoads`.**
- **`NSLocalNetworkUsageDescription`** is required, or iOS blocks LAN connections without asking. Something like "Tramline connects to your print server on your home network."

## Not proven

None of this has been tried. In order of risk:

1. **That a Secure Enclave key works as a TLS client identity in URLSession** with TLS 1.3. Apple's developer forums say SE keys can back a `SecIdentity` for client authentication, but it hasn't been checked here. If it fails, fall back to a software key in the keychain with `ThisDeviceOnly`, which is no weaker than the desktop's `client.key`.
2. **That Go accepts the hand-made certificate.** Test it before any UI, see below.
3. **That ATS lets the delegate accept a self-signed server** on a `ts.net` name with only the exception above.

## Proving it

Do this on the Mac before writing UI, against a simulated server only:

1. Start a simulated server with throwaway folders in the scratchpad, as `tramline/sim-gui.sh` does: read that script for the exact `init`, `allow` and `serve --sim` commands and the config it writes. Check the address is `127.0.0.1:18726` and never pass `--bed-clear` from a script.
2. Run the certificate code as a Swift script on the Mac with a software P-256 key (a command-line tool can't use the Secure Enclave without entitlements). Write the certificate and key as PEM to the scratchpad. This key is a throwaway made for the test, so reading it is fine. The secrets rule is about the real keys.
3. `allow` its fingerprint on the simulated server, then `curl --cert ... --key ... -k https://127.0.0.1:18726/v1/status`. A JSON status means Go parsed the certificate and accepted the signature. Then check a certificate that isn't allowed gets refused.
4. Then the iOS Simulator app against the same server: that exercises URLSession, the keychain identity and the pinning, though not the Secure Enclave.
5. Last, the real phone against the simulator on the Mac's LAN address, which needs the Mac's firewall to allow it, and only then against the Pi, read-only first: status and files.
