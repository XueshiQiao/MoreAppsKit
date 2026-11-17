import Foundation
import Security

// Before a downloaded app is copied into the Applications folder it must prove
// that it was signed by the same developer as the app doing the installing.
//
// This check is the installer's whole security story. A file this process
// downloads does not get the "downloaded from the internet" quarantine flag, so
// Gatekeeper will not look at it on first launch. Nothing but this check stands
// between a tampered download and the user's Applications folder.

public enum CodeSignature {

    public struct VerificationError: Error, Equatable, CustomStringConvertible {
        public let status: OSStatus
        public let detail: String
        public var description: String { "code signature check failed (\(status)): \(detail)" }
    }

    /// Apple team identifiers are exactly ten uppercase letters or digits.
    /// Checked before the identifier is spliced into a requirement string.
    public static func isValidTeamIdentifier(_ text: String) -> Bool {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        return text.count == 10 && text.unicodeScalars.allSatisfy(allowed.contains)
    }

    /// The team that signed the bundle at `url`, or nil when it is unsigned,
    /// ad-hoc signed, or unreadable.
    public static func teamIdentifier(ofBundleAt url: URL) -> String? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code else { return nil }
        var info: CFDictionary?
        let flags = SecCSFlags(rawValue: kSecCSSigningInformation)
        guard SecCodeCopySigningInformation(code, flags, &info) == errSecSuccess,
              let dictionary = info as? [String: Any],
              let team = dictionary[kSecCodeInfoTeamIdentifier as String] as? String,
              isValidTeamIdentifier(team) else { return nil }
        return team
    }

    /// The requirement a downloaded app has to satisfy: an Apple-issued
    /// Developer ID Application certificate belonging to `teamID`.
    ///
    /// - `anchor apple generic`: the chain ends at Apple's root.
    /// - `certificate 1[field.1.2.840.113635.100.6.2.6]`: the intermediate is
    ///   the Developer ID certification authority.
    /// - `certificate leaf[field.1.2.840.113635.100.6.1.13]`: the leaf is a
    ///   Developer ID Application certificate (not a development certificate).
    /// - `certificate leaf[subject.OU]`: the leaf belongs to this team.
    static func requirementText(teamID: String) -> String {
        "anchor apple generic"
        + " and certificate 1[field.1.2.840.113635.100.6.2.6] exists"
        + " and certificate leaf[field.1.2.840.113635.100.6.1.13] exists"
        + " and certificate leaf[subject.OU] = \"\(teamID)\""
    }

    /// Throws unless the app bundle at `url` is intact (every architecture,
    /// nested frameworks and helpers included) and signed with `teamID`'s
    /// Developer ID.
    public static func verify(appAt url: URL, signedByTeam teamID: String) throws {
        guard isValidTeamIdentifier(teamID) else {
            throw VerificationError(status: errSecParam, detail: "malformed team identifier")
        }
        var code: SecStaticCode?
        var status = SecStaticCodeCreateWithPath(url as CFURL, [], &code)
        guard status == errSecSuccess, let code else {
            throw VerificationError(status: status, detail: "not a code bundle")
        }
        var requirement: SecRequirement?
        status = SecRequirementCreateWithString(requirementText(teamID: teamID) as CFString, [], &requirement)
        guard status == errSecSuccess, let requirement else {
            throw VerificationError(status: status, detail: "requirement did not compile")
        }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode | kSecCSStrictValidate)
        var error: Unmanaged<CFError>?
        status = SecStaticCodeCheckValidityWithErrors(code, flags, requirement, &error)
        guard status == errSecSuccess else {
            let detail = error.map { CFErrorCopyDescription($0.takeRetainedValue()) as String } ?? "unknown"
            throw VerificationError(status: status, detail: detail)
        }
    }
}
