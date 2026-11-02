import Foundation
import CryptoKit

func require(_ condition: Bool, _ message: String) throws {
    if !condition { throw NSError(domain: "KeyForgeUpdates", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
}
final class Enclosure: NSObject, XMLParserDelegate {
    var attributes: [String: String]?
    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        if name == "enclosure" { self.attributes = attributes }
    }
}
let args = CommandLine.arguments
try require(args.count == 4, "Usage: verify_updates.swift public-key.txt app.zip appcast.xml")
let keyText = try String(contentsOfFile: args[1], encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
guard let rawKey = Data(base64Encoded: keyText) else { fatalError("Invalid public key") }
let key = try Curve25519.Signing.PublicKey(rawRepresentation: rawKey)
let feed = try Data(contentsOf: URL(fileURLWithPath: args[3]))
let text = String(decoding: feed, as: UTF8.self)
let regex = try NSRegularExpression(pattern: "<!-- sparkle-signatures:\\s*edSignature: ([A-Za-z0-9+/=]+)\\s*length: ([0-9]+)\\s*-->\\s*$")
guard let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
      let signatureRange = Range(match.range(at: 1), in: text), let lengthRange = Range(match.range(at: 2), in: text),
      let blockRange = Range(match.range, in: text), let length = Int(text[lengthRange]),
      let signature = Data(base64Encoded: String(text[signatureRange])) else { fatalError("Missing signed feed metadata") }
let offset = text.utf8.distance(from: text.utf8.startIndex, to: blockRange.lowerBound.samePosition(in: text.utf8)!)
try require(length == offset, "Feed signature length mismatch")
let content = Data(feed.prefix(length))
try require(key.isValidSignature(signature, for: content), "Invalid feed signature")
let enclosure = Enclosure(), parser = XMLParser(data: content)
parser.shouldResolveExternalEntities = false; parser.delegate = enclosure
try require(parser.parse(), "Invalid appcast XML")
guard let attributes = enclosure.attributes, let encoded = attributes["sparkle:edSignature"],
      let archiveSignature = Data(base64Encoded: encoded), let archiveLength = Int(attributes["length"] ?? ""),
      let downloadURL = URL(string: attributes["url"] ?? "") else { fatalError("Missing signed archive metadata") }
let archiveURL = URL(fileURLWithPath: args[2]), archive = try Data(contentsOf: archiveURL)
try require(archive.count == archiveLength, "Archive length mismatch")
try require(downloadURL.scheme == "https" && downloadURL.host == "github.com" && downloadURL.path.hasPrefix("/silentrosehill/KeyForge/releases/download/"), "Unexpected release URL")
try require(downloadURL.lastPathComponent == archiveURL.lastPathComponent, "Archive filename mismatch")
try require(key.isValidSignature(archiveSignature, for: archive), "Invalid archive signature")
print("Verified signed update feed and archive with the public key")
