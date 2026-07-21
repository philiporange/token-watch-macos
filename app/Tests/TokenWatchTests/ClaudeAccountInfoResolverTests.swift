import Foundation
import Testing
@testable import TokenWatch

@Suite struct ClaudeAccountInfoResolverTests {

    private func writeConfig(_ json: String) throws -> URL {
        let dir = try makeTemporaryDirectory()
        let url = dir.appendingPathComponent(".claude.json")
        try json.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    @Test func resolvesOAuthAccountFields() throws {
        let url = try writeConfig(
            #"{"oauthAccount":{"emailAddress":"a@b.com","displayName":"Alice","organizationName":"Org"}}"#
        )
        let info = ClaudeAccountInfoResolver(configURL: url).resolve()
        #expect(info == ClaudeAccountInfo(email: "a@b.com", displayName: "Alice", organizationName: "Org"))
    }

    @Test func missingFileReturnsNil() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).json")
        #expect(ClaudeAccountInfoResolver(configURL: url).resolve() == nil)
    }

    @Test func missingOAuthAccountReturnsNil() throws {
        let url = try writeConfig(#"{"somethingElse":1}"#)
        #expect(ClaudeAccountInfoResolver(configURL: url).resolve() == nil)
    }

    @Test func allEmptyOAuthAccountReturnsNil() throws {
        let url = try writeConfig(#"{"oauthAccount":{}}"#)
        #expect(ClaudeAccountInfoResolver(configURL: url).resolve() == nil)
    }
}
