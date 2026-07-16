# Test fixtures

## `ramp-2000x1000.mp4`, `ramp-320x240.mp4`

Pre-encoded H.264 clips for `AVVideoDecoderTests`.

`AVVideoDecoder` wraps `AVAssetReader`, so covering it needs a real
asset. The suite used to synthesise one per run with `AVAssetWriter` —
which meant every test run encoded H.264 on whatever machine it ran on.
That is fine on a developer Mac and not fine on CI: a runner without a
usable VideoToolbox encoder doesn't fail the write, it stalls it, and
the job hangs until GitHub's 6-hour default timeout. Decoding needs no
encoder, so the clips are committed instead.

Both hold **4 frames at 30 fps** of solid grey ramping 40, 60, 80, 100
(one level per frame). The tests depend on all of that:

- `ramp-2000x1000.mp4` — over the 1280 canvas cap, so it must fit down
  to 1280×640. The non-square aspect proves the fit isn't square.
- `ramp-320x240.mp4` — under the cap, so it must come back unscaled.
- 4 frames exactly — `frames arrive in presentation order and run out at
  the end of the asset` asserts the count.
- Distinct pixels per frame — `rewind replays the asset from its first
  frame` compares the replayed frame against frame 0, which would pass
  trivially if every frame were identical.

Together they're under 7 KB.

### Regenerating

Only needed if a test wants a different size, frame count or pattern —
the clips are otherwise static. Run `generate.swift` on a Mac with a
working H.264 encoder (any normal Mac; not a CI runner):

```sh
swift Tests/BaguetteTests/Fixtures/generate.swift Tests/BaguetteTests/Fixtures
```

It verifies each clip's `naturalSize` after writing and fails loudly
rather than hanging if the encoder never drains.
