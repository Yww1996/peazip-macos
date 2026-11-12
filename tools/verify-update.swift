import CryptoKit
import Foundation

// Independent check against the public key embedded in the app, rather than the
// signer's keychain. Catches publishing with a different signing identity.
guard CommandLine.arguments.count == 5,
      let signature = Data(base64Encoded: CommandLine.arguments[2]),
      let plistData = try? Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[3])),
      let plist = (try? PropertyListSerialization.propertyList(from: plistData, format: nil)) as? [String: Any],
      let publicText = plist["SUPublicEDKey"] as? String,
      let publicBytes = Data(base64Encoded: publicText) else {
    fatalError("Usage: verify-update.swift archive signature Info.plist expected-length")
}
let archive = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]), options: .mappedIfSafe)
let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: publicBytes)
guard publicKey.isValidSignature(signature, for: archive),
      archive.count == Int(CommandLine.arguments[4]) else {
    fputs("Update signature or archive size is invalid\n", stderr)
    exit(1)
}
print("Update signature and archive size verified against bundled public key")
