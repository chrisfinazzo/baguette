import Testing
import Foundation
@testable import Baguette

/// Pure-value coverage for `InjectedDylibs` — the contents of a
/// simulator's `DYLD_INSERT_LIBRARIES`.
///
/// The problem this value exists to solve: that env var is **one string
/// for the whole simulator**, and baguette now has more than one feature
/// that wants a dylib inside apps (the virtual camera, and motion). The
/// old code wrote a single path and unset the whole variable on teardown,
/// so a second feature arming would silently disarm the first, and either
/// one stopping would disarm the other.
///
/// Merging is modelled as a value so the arithmetic is tested here and the
/// adapter stays a thin read-modify-write around `launchctl`.
@Suite("InjectedDylibs")
struct InjectedDylibsTests {

    private let camera = "/Users/x/Library/Application Support/Baguette/builds/abc123/VirtualCamera.dylib"
    private let motion = "/Users/x/Library/Application Support/Baguette/builds/def456/BaguetteMotion.dylib"

    @Test func `treats a missing or empty value as nothing armed`() {
        #expect(InjectedDylibs.parsing(nil).isEmpty)
        #expect(InjectedDylibs.parsing("").isEmpty)
        #expect(InjectedDylibs.parsing("   \n").isEmpty)
        #expect(InjectedDylibs.parsing(nil).environmentValue == "")
    }

    @Test func `parses a colon-joined value`() {
        let dylibs = InjectedDylibs.parsing("\(camera):\(motion)")
        #expect(dylibs.paths == [camera, motion])
    }

    @Test func `ignores empty segments and surrounding whitespace`() {
        // `launchctl getenv` output arrives with a trailing newline, and a
        // stray colon shouldn't become an empty dylib path that dyld then
        // complains about.
        let dylibs = InjectedDylibs.parsing(" \(camera)::\(motion) \n")
        #expect(dylibs.paths == [camera, motion])
    }

    @Test func `arms a second dylib alongside the first`() {
        // The headline: turning on motion must not turn off the camera.
        let dylibs = InjectedDylibs.parsing(camera).adding(motion)
        #expect(dylibs.paths == [camera, motion])
        #expect(dylibs.environmentValue == "\(camera):\(motion)")
    }

    @Test func `replaces an earlier build of the same dylib instead of stacking it`() {
        // Every release installs under a fresh sha-keyed directory (iOS 26's
        // dyld page-hash cache rejects a replaced dylib at the same path),
        // so the same dylib legitimately arrives under a new path. Two
        // copies of one dylib in dyld's list is a load error, not a merge.
        let older = "/Users/x/Library/Application Support/Baguette/builds/000aaa/VirtualCamera.dylib"
        let dylibs = InjectedDylibs.parsing(older).adding(camera)
        #expect(dylibs.paths == [camera])
    }

    @Test func `arming the same path twice changes nothing`() {
        let dylibs = InjectedDylibs.parsing(camera).adding(camera)
        #expect(dylibs.paths == [camera])
    }

    @Test func `disarms one dylib and leaves the others armed`() {
        let dylibs = InjectedDylibs.parsing("\(camera):\(motion)").removing(camera)
        #expect(dylibs.paths == [motion])
        #expect(!dylibs.isEmpty)
    }

    @Test func `is empty once the last dylib is disarmed`() {
        // Empty is what tells the adapter to `unsetenv` rather than set an
        // empty string — dyld treats an empty entry as a path it can't load.
        let dylibs = InjectedDylibs.parsing(camera).removing(camera)
        #expect(dylibs.isEmpty)
    }

    @Test func `preserves a dylib baguette did not arm`() {
        // Someone may have armed their own dylib by hand. Read-modify-write
        // means we must hand it back untouched rather than clobbering it.
        let theirs = "/opt/theirs/Instrument.dylib"
        let dylibs = InjectedDylibs.parsing("\(theirs):\(camera)").removing(camera)
        #expect(dylibs.paths == [theirs])
    }

    @Test func `matches by dylib filename, not by directory`() {
        // The sha-keyed install directory differs per release; the filename
        // is what identifies the feature's dylib.
        #expect(InjectedDylibs.parsing(camera).removing(
            "/somewhere/else/VirtualCamera.dylib").isEmpty)
    }
}
