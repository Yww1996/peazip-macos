// Run only when creating this app's first signing key. Never overwrite an existing key.
import CryptoKit
import Foundation

let folder = URL(fileURLWithPath: ".update-signing", isDirectory: true)
let path = folder.appendingPathComponent("ed25519.private-key")
try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                      attributes: [.posixPermissions: 0o700])
let key: Curve25519.Signing.PrivateKey
if FileManager.default.fileExists(atPath: path.path) {
    guard let bytes = Data(base64Encoded: try String(contentsOf: path, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines))
    else { fatalError("Invalid existing signing key; refusing to overwrite it") }
    key = try Curve25519.Signing.PrivateKey(rawRepresentation: bytes)
} else {
    key = Curve25519.Signing.PrivateKey()
    try Data((key.rawRepresentation.base64EncodedString() + "\n").utf8).write(to: path, options: .atomic)
}
try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
print(key.publicKey.rawRepresentation.base64EncodedString())
