import Testing

@testable import Baguette

@Suite("ScreenPlacement")
struct ScreenPlacementTests {
    @Test("stretch fills the screen surface without cropping or letterboxing")
    func stretchIsIdentity() {
        let placement = DeviceScreenFit.stretch.placement(
            source: RenderDimensions(width: 200, height: 100),
            target: RenderDimensions(width: 100, height: 100)
        )

        #expect(placement == ScreenPlacement(scaleX: 1, scaleY: 1, offsetX: 0, offsetY: 0))
    }

    @Test("cover crops the overflowing width of a wide frame on a square screen")
    func coverCropsWideSourceHorizontally() {
        let placement = DeviceScreenFit.cover.placement(
            source: RenderDimensions(width: 200, height: 100),
            target: RenderDimensions(width: 100, height: 100)
        )

        #expect(placement == ScreenPlacement(scaleX: 0.5, scaleY: 1, offsetX: 0.25, offsetY: 0))
    }

    @Test("cover crops the overflowing height of a tall frame on a square screen")
    func coverCropsTallSourceVertically() {
        let placement = DeviceScreenFit.cover.placement(
            source: RenderDimensions(width: 100, height: 200),
            target: RenderDimensions(width: 100, height: 100)
        )

        #expect(placement == ScreenPlacement(scaleX: 1, scaleY: 0.5, offsetX: 0, offsetY: 0.25))
    }

    @Test("contain letterboxes a wide frame vertically on a square screen")
    func containLetterboxesWideSourceVertically() {
        let placement = DeviceScreenFit.contain.placement(
            source: RenderDimensions(width: 200, height: 100),
            target: RenderDimensions(width: 100, height: 100)
        )

        #expect(placement == ScreenPlacement(scaleX: 1, scaleY: 2, offsetX: 0, offsetY: -0.5))
    }

    @Test("matching aspect ratios need no adjustment for cover or contain")
    func matchingAspectIsIdentity() {
        for fit in [DeviceScreenFit.cover, .contain] {
            let placement = fit.placement(
                source: RenderDimensions(width: 660, height: 1434),
                target: RenderDimensions(width: 1320, height: 2868)
            )

            #expect(placement == ScreenPlacement(scaleX: 1, scaleY: 1, offsetX: 0, offsetY: 0))
        }
    }
}
