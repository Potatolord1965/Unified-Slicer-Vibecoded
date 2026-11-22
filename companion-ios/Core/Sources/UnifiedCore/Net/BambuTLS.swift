import Foundation
import Security

/// Bambu Lab's printer CAs: the bundle Bambu Studio and OrcaSlicer ship as resources/cert/printer.cer.
let bambuPrinterCAPEM = """
-----BEGIN CERTIFICATE-----
MIIFfzCCA2egAwIBAgIUXtzR6tRiL/RHBRXOoyFU0+XrliowDQYJKoZIhvcNAQEL
BQAwRjELMAkGA1UEBhMCQ04xITAfBgNVBAoMGEJCTCBUZWNobm9sb2dpZXMgQ28u
IEx0ZDEUMBIGA1UEAwwLQkJMIENBMiBSU0EwIBcNMjUwNjE3MDEzODA4WhgPMjA1
MDA2MTcwMTM4MDhaMEYxCzAJBgNVBAYTAkNOMSEwHwYDVQQKDBhCQkwgVGVjaG5v
bG9naWVzIENvLiBMdGQxFDASBgNVBAMMC0JCTCBDQTIgUlNBMIICIjANBgkqhkiG
9w0BAQEFAAOCAg8AMIICCgKCAgEAo4550G4c42gTKzQqixwKT089RizIdZpyOcGA
679rPaOdWsMqVwnYPP2FpMqXKkjFbedE+SpGloi2NKCuiPNVRbq9PHOOZwTs7YLo
bOwf53FJuO6vRFpzFfX1tlc9zlFqJvZnYO9NgHpMysidocWcgrDN/SIDywgPB5CV
bYg3Vvzua9fwZx9e5KT9xd5IpTqdTrWS47jQOVKLhdQCbJFIlMrblOwLBAx+fHok
wqh6tkI6Ktuyyjw8Dysebi1ndWjKtZ2mW47r8xZ/J+z3EZqcyJMY6MRtx/zb1jBF
uHtkjrb5Kv1DMzSKlkaNJIbvC+Mk+hI97W+SjLSRuIdC7+oJUzWaSzgu9cjXCVfm
q8t4IL/35hP69PK95LgLectIrP96CYAT/aVMG19FrFW0QWEyfT+kzG4jkumfPbHq
Y2nNkEN0+tjj3h4WdzrWgQEojK/lhfcRFVkts74+aZoMpQP+vmL17CKmSzXk5o/e
K21xgxJdzMbdztfTpibiXk0abfOpN+1VR+3NYa+bROAKNyGaReEGsyW2bjcjNx51
5Vqzj3SVxhMSp5vfF9E4A1jE99M/l9jQDM6RzkT0lMccGAd5tUSdNvDlrqtQaQiK
v/ZsXPgXLTWfOpvaLNEgwdMgZMuhjpkwvAZyoYfeF9kyydjDh7bvrX//cz/VopAU
lxUtQtMCAwEAAaNjMGEwHQYDVR0OBBYEFNVJgQad1sNTN0jxVkwbJ/XM1an1MB8G
A1UdIwQYMBaAFNVJgQad1sNTN0jxVkwbJ/XM1an1MA8GA1UdEwEB/wQFMAMBAf8w
DgYDVR0PAQH/BAQDAgEGMA0GCSqGSIb3DQEBCwUAA4ICAQBFZDKMJfp/N4gBeFHh
MiFehaUyMS6e9mzrTfMLJLJoj6Jopa9V9jIfcCEBGZuRThqFcATV+UdFHSINpUcH
upcCYnazTRC4dn1hnxnQ1ojQcHxdGp9xGw/YclAKD97d8bPShfBMT1to9zbMK7T5
L8zgqg01YIOKjQk0Hcd0+0iUr6m8zQ5P8Rl3QXqAyeWgqmYQrrjTWwPsgdfHNXKX
vDrx7/cqry5lKU802hUplKMBxelv4W8407Ytj1lfJOwvxqxxsFU5jSwcUG3zo2vk
QtjRs8m5BKup5K1OPYkkPu7Ld89X0XpU073/dNDG11uxb1eDKrtNP6vZuZjNE2Pq
8HCoI1EtP+ItyqtUMvHi6Z2zsmlA25broVioeUKxjlIecpQ9JR/FhDu9CWNF/nDW
LSORNaMMzgsMSzI+HCiUhqN+qMIvVP6rzGTJzwqz/lc5Lf+ZPCnGA9WJTT4uPIhf
ufbZmnUJ35WuWKHxovDsqBh88zQ9sZ+ei4Hi4vVzOhUgfG3aLoSQEYqRoqaboANh
wCwzyuW2Rv54u5QSBbd6Gx1OpvsWmLPWd2/iL2kISl5wfmLGVydvSJa+rbOfuAy7
ycVQacVDQCAnbhoVrQy7+454QsKSW3ZV6BcyRrorewCyCYgd7nyxflxHZTBEykXX
haGNe/KFNvJBMOIuIUzknRRmiQ==
-----END CERTIFICATE-----
-----BEGIN CERTIFICATE-----
MIIB8zCCAZmgAwIBAgIUe61jGQ4RzIC8k+sNuqbI/CaNqPIwCgYIKoZIzj0EAwIw
RjELMAkGA1UEBhMCQ04xITAfBgNVBAoMGEJCTCBUZWNobm9sb2dpZXMgQ28uIEx0
ZDEUMBIGA1UEAwwLQkJMIENBMiBFQ0MwIBcNMjUwNjE3MDEzODM1WhgPMjA1MDA2
MTcwMTM4MzVaMEYxCzAJBgNVBAYTAkNOMSEwHwYDVQQKDBhCQkwgVGVjaG5vbG9n
aWVzIENvLiBMdGQxFDASBgNVBAMMC0JCTCBDQTIgRUNDMFkwEwYHKoZIzj0CAQYI
KoZIzj0DAQcDQgAEpKTF7wRSty4DXpGJzgCPwRh8ghLlxUC3qJbyEgLqTvJgbiwY
APPHK7kVbVmerkqhHOT4QeWRlTG3dOQGLA2VpaNjMGEwHQYDVR0OBBYEFKuRpsjY
REOyIKH7HwOE6jhGBd6NMB8GA1UdIwQYMBaAFKuRpsjYREOyIKH7HwOE6jhGBd6N
MA8GA1UdEwEB/wQFMAMBAf8wDgYDVR0PAQH/BAQDAgEGMAoGCCqGSM49BAMCA0gA
MEUCIErBiUm3VdtP3rz4kb8aLpI5p+BzL7M9vElBGWWJxpHMAiEA3r5tJWVGwuxi
YCrB1c40KYFRFyahGrhOJZAj/YhRdnU=
-----END CERTIFICATE-----
-----BEGIN CERTIFICATE-----
MIIEeTCCA2GgAwIBAgIUOq+lNIaC2xsswkFqj5JPyVBl45cwDQYJKoZIhvcNAQEL
BQAwQjELMAkGA1UEBhMCQ04xIjAgBgNVBAoMGUJCTCBUZWNobm9sb2dpZXMgQ28u
LCBMdGQxDzANBgNVBAMMBkJCTCBDQTAeFw0yNTA2MTcwMjAxMjdaFw0zNTA2MTUw
MjAxMjdaMEYxCzAJBgNVBAYTAkNOMSEwHwYDVQQKDBhCQkwgVGVjaG5vbG9naWVz
IENvLiBMdGQxFDASBgNVBAMMC0JCTCBDQTIgUlNBMIICIjANBgkqhkiG9w0BAQEF
AAOCAg8AMIICCgKCAgEAo4550G4c42gTKzQqixwKT089RizIdZpyOcGA679rPaOd
WsMqVwnYPP2FpMqXKkjFbedE+SpGloi2NKCuiPNVRbq9PHOOZwTs7YLobOwf53FJ
uO6vRFpzFfX1tlc9zlFqJvZnYO9NgHpMysidocWcgrDN/SIDywgPB5CVbYg3Vvzu
a9fwZx9e5KT9xd5IpTqdTrWS47jQOVKLhdQCbJFIlMrblOwLBAx+fHokwqh6tkI6
Ktuyyjw8Dysebi1ndWjKtZ2mW47r8xZ/J+z3EZqcyJMY6MRtx/zb1jBFuHtkjrb5
Kv1DMzSKlkaNJIbvC+Mk+hI97W+SjLSRuIdC7+oJUzWaSzgu9cjXCVfmq8t4IL/3
5hP69PK95LgLectIrP96CYAT/aVMG19FrFW0QWEyfT+kzG4jkumfPbHqY2nNkEN0
+tjj3h4WdzrWgQEojK/lhfcRFVkts74+aZoMpQP+vmL17CKmSzXk5o/eK21xgxJd
zMbdztfTpibiXk0abfOpN+1VR+3NYa+bROAKNyGaReEGsyW2bjcjNx515Vqzj3SV
xhMSp5vfF9E4A1jE99M/l9jQDM6RzkT0lMccGAd5tUSdNvDlrqtQaQiKv/ZsXPgX
LTWfOpvaLNEgwdMgZMuhjpkwvAZyoYfeF9kyydjDh7bvrX//cz/VopAUlxUtQtMC
AwEAAaNjMGEwDwYDVR0TAQH/BAUwAwEB/zAOBgNVHQ8BAf8EBAMCAQYwHQYDVR0O
BBYEFNVJgQad1sNTN0jxVkwbJ/XM1an1MB8GA1UdIwQYMBaAFI80QmjcZ06PxCKe
xXxJ5avdRL4eMA0GCSqGSIb3DQEBCwUAA4IBAQAvS8tyfagaGsFf9YncA2ko/Na5
9BVF+8TlUo+32oznwIVpS1AhSgLP6rNVekXNFKbuP5htudLQ17ZRBJI/UMVyYEDq
IN7xv7Zj+zJwF6W6haYrjb2Vk8igw1XvNULZfvVNNKIkvJUiVqEslWrC+k74crk/
Wv8ChVf+zqvfIN6LV3esaGRL02J3AprQGb7DDhR1EefQMScDkNpGJMUmvCmfknrl
iK8qgvQN1SWO7JRf6fNKHsN1ZQvyP0pgLWxpT3V0/0/WttqX3cMGuJF+jVUzm/Nh
xYhFewG8vc3KzTjnwQApMA6CW554FOJWFyOD2jn5yJLT3Vue+aYDQRp4bKMx
-----END CERTIFICATE-----
-----BEGIN CERTIFICATE-----
MIICrjCCAZagAwIBAgIUOq+lNIaC2xsswkFqj5JPyVBl45gwDQYJKoZIhvcNAQEL
BQAwQjELMAkGA1UEBhMCQ04xIjAgBgNVBAoMGUJCTCBUZWNobm9sb2dpZXMgQ28u
LCBMdGQxDzANBgNVBAMMBkJCTCBDQTAeFw0yNTA2MTcwMjAxNDdaFw0zNTA2MTUw
MjAxNDdaMEYxCzAJBgNVBAYTAkNOMSEwHwYDVQQKDBhCQkwgVGVjaG5vbG9naWVz
IENvLiBMdGQxFDASBgNVBAMMC0JCTCBDQTIgRUNDMFkwEwYHKoZIzj0CAQYIKoZI
zj0DAQcDQgAEpKTF7wRSty4DXpGJzgCPwRh8ghLlxUC3qJbyEgLqTvJgbiwYAPPH
K7kVbVmerkqhHOT4QeWRlTG3dOQGLA2VpaNjMGEwDwYDVR0TAQH/BAUwAwEB/zAO
BgNVHQ8BAf8EBAMCAQYwHQYDVR0OBBYEFKuRpsjYREOyIKH7HwOE6jhGBd6NMB8G
A1UdIwQYMBaAFI80QmjcZ06PxCKexXxJ5avdRL4eMA0GCSqGSIb3DQEBCwUAA4IB
AQCg6PjUSSZV+4bvejcVMvgXmKzfD95osWn0ctnoMBxPDa+m+Gg+BcLT2IlFAe3E
KYMvu4T295WQc92rjKYqW6cirFppng9uEFW2mZLimxaSmutsTftE3sbMVMJ/SLYN
PV7TFv6mcBSIFWXwmBOIpbh4BUcVfONTvdSfIqfyAVxsq4xzc2nc6hPBpAm21Ayj
ToC1ev/TbDJ8VllFZiEVmWWlIP3aNzAm8S2mOpxPB2WnanaZHSrvXLFhstyzwrjD
yO1/isOZ7wtr7rcuTJdEvvvCimOZlkfRhaDoTew9tQ0E2FVpzzSinw02qmQ1xIE9
5/H5ZzJSPkpeAHWEPnKkxg0v
-----END CERTIFICATE-----
-----BEGIN CERTIFICATE-----
MIIDZTCCAk2gAwIBAgIUV1FckwXElyek1onFnQ9kL7Bk4N8wDQYJKoZIhvcNAQEL
BQAwQjELMAkGA1UEBhMCQ04xIjAgBgNVBAoMGUJCTCBUZWNobm9sb2dpZXMgQ28u
LCBMdGQxDzANBgNVBAMMBkJCTCBDQTAeFw0yMjA0MDQwMzQyMTFaFw0zMjA0MDEw
MzQyMTFaMEIxCzAJBgNVBAYTAkNOMSIwIAYDVQQKDBlCQkwgVGVjaG5vbG9naWVz
IENvLiwgTHRkMQ8wDQYDVQQDDAZCQkwgQ0EwggEiMA0GCSqGSIb3DQEBAQUAA4IB
DwAwggEKAoIBAQDL3pnDdxGOk5Z6vugiT4dpM0ju+3Xatxz09UY7mbj4tkIdby4H
oeEdiYSZjc5LJngJuCHwtEbBJt1BriRdSVrF6M9D2UaBDyamEo0dxwSaVxZiDVWC
eeCPdELpFZdEhSNTaT4O7zgvcnFsfHMa/0vMAkvE7i0qp3mjEzYLfz60axcDoJLk
p7n6xKXI+cJbA4IlToFjpSldPmC+ynOo7YAOsXt7AYKY6Glz0BwUVzSJxU+/+VFy
/QrmYGNwlrQtdREHeRi0SNK32x1+bOndfJP0sojuIrDjKsdCLye5CSZIvqnbowwW
1jRwZgTBR29Zp2nzCoxJYcU9TSQp/4KZuWNVAgMBAAGjUzBRMB0GA1UdDgQWBBSP
NEJo3GdOj8QinsV8SeWr3US+HjAfBgNVHSMEGDAWgBSPNEJo3GdOj8QinsV8SeWr
3US+HjAPBgNVHRMBAf8EBTADAQH/MA0GCSqGSIb3DQEBCwUAA4IBAQABlBIT5ZeG
fgcK1LOh1CN9sTzxMCLbtTPFF1NGGA13mApu6j1h5YELbSKcUqfXzMnVeAb06Htu
3CoCoe+wj7LONTFO++vBm2/if6Jt/DUw1CAEcNyqeh6ES0NX8LJRVSe0qdTxPJuA
BdOoo96iX89rRPoxeed1cpq5hZwbeka3+CJGV76itWp35Up5rmmUqrlyQOr/Wax6
itosIzG0MfhgUzU51A2P/hSnD3NDMXv+wUY/AvqgIL7u7fbDKnku1GzEKIkfH8hm
Rs6d8SCU89xyrwzQ0PR853irHas3WrHVqab3P+qNwR0YirL0Qk7Xt/q3O1griNg2
Blbjg3obpHo9
-----END CERTIFICATE-----
"""

/// The CAs in `bambuPrinterCAPEM`.
let bambuPrinterCAs: [SecCertificate] = pemCertificates(bambuPrinterCAPEM)

func pemCertificates(_ pem: String) -> [SecCertificate] {
    var out = [SecCertificate]()
    let blocks = pem.components(separatedBy: "-----BEGIN CERTIFICATE-----").dropFirst()
    for block in blocks {
        guard let end = block.range(of: "-----END CERTIFICATE-----") else { continue }
        let b64 = block[..<end.lowerBound].filter { !$0.isWhitespace }
        if let der = Data(base64Encoded: String(b64)), let cert = SecCertificateCreateWithData(nil, der as CFData) {
            out.append(cert)
        }
    }
    return out
}

/// The common name in a certificate's subject, or nil.
func commonName(_ cert: SecCertificate) -> String? {
    var name: CFString?
    guard SecCertificateCopyCommonName(cert, &name) == errSecSuccess, let n = name else { return nil }
    return n as String
}

/// A Bambu printer on the local network is reached by IP address, so its certificate can't be
/// checked by host name: it must chain to Bambu Lab's printer CA and name the printer's serial
/// number, as Bambu Studio checks it. Returns nil when it passes, else the reason.
func bambuTrustProblem(_ trust: SecTrust, serial: String) -> String? {
    SecTrustSetPolicies(trust, SecPolicyCreateBasicX509())
    SecTrustSetAnchorCertificates(trust, bambuPrinterCAs as CFArray)
    SecTrustSetAnchorCertificatesOnly(trust, true)
    var error: CFError?
    guard SecTrustEvaluateWithError(trust, &error) else { return "The printer's certificate isn't from Bambu Lab" }
    let chain = (SecTrustCopyCertificateChain(trust) as? [SecCertificate]) ?? []
    guard let leaf = chain.first else { return "The printer sent no certificate" }
    let name = commonName(leaf)
    let want = serial.trimmingCharacters(in: .whitespacesAndNewlines)
    if !want.isEmpty, want.caseInsensitiveCompare(name ?? "") != .orderedSame {
        return "The device at this address is printer \(name ?? "(no serial number)"), not \(want)"
    }
    return nil
}
