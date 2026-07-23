import Testing
import Foundation
@testable import Baguette

@Suite("BakeryRef")
struct BakeryRefTests {

    // MARK: - owner/repo shorthand

    @Test func `owner slash repo defaults to github over https`() throws {
        let ref = try BakeryRef.parse("tddworks/baguette-plugins")
        #expect(ref.host == "github.com")
        #expect(ref.owner == "tddworks")
        #expect(ref.repo == "baguette-plugins")
        #expect(ref.plugin == nil)
        #expect(ref.cloneURL == "https://github.com/tddworks/baguette-plugins.git")
    }

    @Test func `a third segment names a plugin inside the bakery`() throws {
        let ref = try BakeryRef.parse("tddworks/baguette-plugins/a11y")
        #expect(ref.owner == "tddworks")
        #expect(ref.repo == "baguette-plugins")
        #expect(ref.plugin == "a11y")
    }

    @Test func `a trailing .git on the repo segment is dropped`() throws {
        let ref = try BakeryRef.parse("tddworks/baguette-plugins.git")
        #expect(ref.repo == "baguette-plugins")
        #expect(ref.cloneURL == "https://github.com/tddworks/baguette-plugins.git")
    }

    @Test func `the github prefix is accepted as an explicit host`() throws {
        let ref = try BakeryRef.parse("github:acme/tools")
        #expect(ref.host == "github.com")
        #expect(ref.owner == "acme")
        #expect(ref.repo == "tools")
    }

    // MARK: - full URLs (any host)

    @Test func `an https URL keeps its own host`() throws {
        let ref = try BakeryRef.parse("https://gitlab.com/acme/tools")
        #expect(ref.host == "gitlab.com")
        #expect(ref.owner == "acme")
        #expect(ref.repo == "tools")
        #expect(ref.cloneURL == "https://gitlab.com/acme/tools.git")
    }

    @Test func `an scp-style git URL is understood`() throws {
        // `git@github.com:owner/repo.git` — the form GitHub prints for
        // SSH remotes. Kept verbatim as the clone URL so a user's SSH
        // keys carry through for private bakeries.
        let ref = try BakeryRef.parse("git@github.com:acme/tools.git")
        #expect(ref.host == "github.com")
        #expect(ref.owner == "acme")
        #expect(ref.repo == "tools")
        #expect(ref.cloneURL == "git@github.com:acme/tools.git")
    }

    @Test func `a file URL is a local bakery, host-less`() throws {
        // The reproducible test path and a handy way to develop a
        // bakery against a checkout without pushing.
        let ref = try BakeryRef.parse("file:///Users/me/my-bakery")
        #expect(ref.host == "")
        #expect(ref.repo == "my-bakery")
        #expect(ref.cloneURL == "file:///Users/me/my-bakery")
    }

    // MARK: - identity + cache location

    @Test func `two refs to the same repo compare equal regardless of plugin`() throws {
        // The bakery is the repo; the plugin segment only picks what to
        // install. Adding the source is the same act either way.
        let bare = try BakeryRef.parse("acme/tools")
        let scoped = try BakeryRef.parse("acme/tools/hello")
        #expect(bare.bakery == scoped.bakery)
    }

    @Test func `the cache subpath is host and owner scoped so names can't collide`() throws {
        let a = try BakeryRef.parse("acme/tools")
        let b = try BakeryRef.parse("https://gitlab.com/acme/tools")
        #expect(a.cacheSubpath == "github.com/acme/tools")
        #expect(b.cacheSubpath == "gitlab.com/acme/tools")
        #expect(a.cacheSubpath != b.cacheSubpath)
    }

    // MARK: - rejections

    @Test func `an empty reference is rejected`() throws {
        #expect(throws: BakeryRefError.empty) { try BakeryRef.parse("   ") }
    }

    @Test func `a bare word with no owner is rejected`() throws {
        #expect(throws: BakeryRefError.malformed(reference: "justaname")) {
            try BakeryRef.parse("justaname")
        }
    }

    @Test func `a shorthand with too many segments is rejected`() throws {
        #expect(throws: BakeryRefError.malformed(reference: "a/b/c/d")) {
            try BakeryRef.parse("a/b/c/d")
        }
    }
}
