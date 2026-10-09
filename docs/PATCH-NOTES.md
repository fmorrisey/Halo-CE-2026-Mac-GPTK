# Notes on `wg_transform-error-propagation.patch`

**Status: built, grafted, runtime test pending.** The patch is now a real
`git diff` against a `wine-10.0` checkout (not an approximation from master),
compiled as x86_64 on macOS, and the resulting `winegstreamer.so` has been
installed into the wrapper with the original backed up. Whether it actually
converts the hang into a recoverable error has not yet been observed.

Build recipe that worked on Apple Silicon (host is arm64, target is x86_64
because the wrapper's Wine runs under Rosetta):

```
brew install mingw-w64 pkgconf bison flex gstreamer gst-plugins-base
git clone --depth 1 --branch wine-10.0 https://github.com/wine-mirror/wine.git
# Headers from Homebrew (arch-independent); x86_64 dylibs from the wrapper's
# own bundled GStreamer.framework, via a symlink with no spaces in the path.
CC="clang -arch x86_64" \
GSTREAMER_CFLAGS="-I/opt/homebrew/include/gstreamer-1.0 -I/opt/homebrew/include/glib-2.0 -I/opt/homebrew/lib/glib-2.0/include" \
GSTREAMER_LIBS="-L<gst-x86_64>/lib -lgstreamer-1.0 -lgstvideo-1.0 -lgstaudio-1.0 -lgsttag-1.0 -lglib-2.0 -lgobject-2.0" \
./configure --host=x86_64-apple-darwin --enable-win64 --disable-tests --without-x --without-freetype --without-vulkan
make -j18 dlls/winegstreamer/winegstreamer.so
```

Only the unix-side `.so` needs replacing: `wg_transform.c` compiles into it,
and the PE `winegstreamer.dll` just marshals across the unixlib boundary. The
export surface (`__wine_unix_call_funcs` + wow64 entry) is identical between
the built module and the wrapper's original, and every library reference is
`@rpath/...` matching the wrapper's install_names.

## Why v1 could not work, proven from source

v1 latched the `GstFlowReturn` from `gst_pad_push()`. Built, grafted, and
tested: the decoder error occurred (`libav :0:: no frame!` in the log) and
**the latch never fired.** The reason is in `gstvideodecoder.c`:

```c
dec->priv->error_count += weight;
if (dec->priv->max_errors >= 0 &&
    dec->priv->error_count > dec->priv->max_errors)
    return GST_FLOW_ERROR;
return GST_FLOW_OK;
```

with `#define GST_VIDEO_DECODER_MAX_ERRORS -1` as the default, and
`gst-libav` not overriding it. The `>= 0` guard never passes, so a
`GstVideoDecoder` returns `GST_FLOW_OK` on **every** failure, forever, by
design — one corrupt packet must not kill playback. `avdec_h264`'s
`send_packet_failed` path goes through exactly this macro with weight 1.
Upstream can never observe the failure via the flow return. A latch at
`gst_pad_push()` is correct for the API contract and unreachable under the
default configuration.

## ROOT CAUSE (found 2026-10-05): the caps `streamheader` is chained as data

Printing the create-time caps of the **real** video transform — not the
throwaway probe transform Electra creates first, which is the one every earlier
grep had matched — shows:

```
video/x-h264, stream-format=byte-stream, alignment=au,
streamheader=(buffer)00000001674d402995900780227e5c04400000fa00003a98210000000168eb8f20
```

Thirty-three bytes: Annex-B SPS + PPS. The chain, each link verified from
source or log:

1. Electra sets the MPEG sequence header on the decoder's input media type.
2. `wg_media_type.c:init_caps_from_video_h264` copies it onto the caps as
   `streamheader`. (The probe transform's type has no header; the logo clip's
   never did either — which is why those were fine.)
3. `GstBaseParse`, on the **first** data buffer, calls
   `gst_base_parse_process_streamheader()`: it reads `streamheader` off the
   sink caps and feeds it through `gst_base_parse_chain()` **as data**, ahead
   of the sample (`gstbaseparse.c`, `first_buffer` block).
4. `h264parse` with `alignment=au` on input forces `drain` for every buffer,
   so the 33-byte `[SPS][PPS]` buffer is treated as a complete access unit:
   it pushes a picture-less frame ("Inserting AUD into the stream").
5. `avdec_h264`: `libav :0:: no frame!` → `Invalid input packet`. With
   `max-errors = -1` the base class returns `GST_FLOW_OK`, and the decoder's
   frame bookkeeping is off by one for the rest of the clip; the client never
   gets what it is waiting for.

The two parse passes in the hang log are on different buffers — a macOS-heap
pointer (the `gst_buffer_new_and_alloc` streamheader) and then the PE-memory
sample — which is what finally separated this from the sample's own prepended
headers. v4 had stripped the sample's copy of those bytes; the harmful copy
was the one on the caps.

## v5: do not expose the sequence header as `streamheader` (installed)

One deletion in `wg_media_type.c`: byte-stream H.264 carries SPS/PPS in-band
(verified at every IDR in these files, and h264parse's own `set_caps` comment
says in-band is what it expects for this stream-format), so the caps field adds
nothing and triggers the injection. v2's dead-decoder reporting is kept so a
future failure surfaces as an error instead of a hang. The v4 strip is removed
as unnecessary. Built, grafted; runtime result pending.

For upstream, this could reasonably be argued either way: Wine should not
advertise `streamheader` for byte-stream input, and/or h264parse should not
emit a picture-less frame in AU mode. The Wine-side change is the smaller one
and the one that has been built and tested here.

## v3 result: loaded, but the game exited before its first push — reverted

With `alignment=nal` on the input caps the module loaded and the transform
was created cleanly (`input caps … alignment=(string)nal`, parser and decoder
built, no error logged). Two differences followed. First, `h264parse`
negotiated its **output** as `avc` instead of `byte-stream` — with NAL input
it no longer passes the format through, and it picks the first format the
decoder offers. Second, the game process exited before pushing a single
sample, twice in a row (21:47 and 21:50), with no crash dump, no native crash
report, and nothing in the system log. Whatever Electra does immediately after
creating the decoder, it does not like what it gets back when the parser is
in that mode. The exit is not visible from the GStreamer side, and capturing
Wine's stderr (Wineskin "Debug Mode") would be the next step if this route is
revisited. The install was reverted to v1.

## v4: keep Wine's `au` declaration, remove the bytes that cause the phantom

The mechanism is fully characterised (see below): Electra prepends the avcC
SPS/PPS ahead of the stream's AUD, and in AU-input mode `h264parse` pushes
those orphaned headers as a frame before reaching the slice. The in-band
SPS/PPS that follow the AUD carry the same data. v4 leaves the caps alone and,
in `wg_transform_push_data`, skips a leading run of SPS/PPS NALs when an AUD
follows them, via `gst_buffer_resize()` — no copy, no change to the sample.

The helper was unit-tested on the **byte-exact buffers Wine pushed** (rebuilt
from the capture and verified at 249,407 bytes): it returns 33 for both the
failing clip and the working one, and 0 for a buffer that begins with the
AUD and for one that begins with a slice. Built on top of v2 (so a decoder
that still fails reports an error rather than hanging), grafted, runtime
result pending.

## v3 analysis: how the phantom frame was found

A `GST_DEBUG=*:1,WINE:4,h264parse:5,videodecoder:5` capture during a live hang
showed the whole mechanism on a single 249,407-byte push:

- Wine pushed the complete first sample, intact — 33 bytes longer than the
  file's first access unit. Those 33 bytes are `00000001`+SPS(21) and
  `00000001`+PPS(4): **Electra prepends the avcC headers ahead of the AUD.**
  Nothing in winegstreamer injects data; the prepend is the client's.
- `h264parse1` identified SPS at 4 and PPS at 29 (both `GST_H264_PARSER_OK`),
  then **finished a frame without ever reaching the AUD at 37** — logging
  "Inserting AUD into the stream" and pushing. libav: `no frame!`,
  `Invalid input packet`. Then "last parse position 0" and SPS at 4 *again*:
  the first push consumed nothing. A phantom, header-only frame.
- The real AU decoded on the second pass (one `Copied 3133440 bytes` read),
  but Electra never pushed a second sample: its first sample's timestamp was
  spent on the phantom.

The same 249,407 bytes, with the wrapper's own x86_64 `h264parse`/`avdec`
1.26.6.1, decode cleanly from the command line under `alignment=au`, `nal`,
and none — so the trigger is how `wg_transform` drives the parser through its
pads, not the data or the plugins. What AU alignment does in the parser:

```c
drain = GST_BASE_PARSE_DRAINING (parse)
    || h264parse->in_align == GST_H264_PARSE_ALIGN_AU;
```

every buffer is treated as a complete, drainable access unit. NAL alignment
makes the parser collect NALs and finish only on a picture boundary
(`collect_nal` is gated on `picture_start`).

v3 is a one-line change in `wg_media_type.c`: declare `alignment=nal`. It is
layered on v2 so a decoder that still fails reports an error instead of
hanging. Built and grafted; runtime result pending.

Seven other hypotheses were eliminated by direct test on the way here — the
clip itself (ffmpeg decodes all 2250 frames), stream order (fails as the first
video too), the 4 KB `cbSize` (Wine's own tests show Windows reports the same),
AVCC-as-byte-stream (fails natively for the working clip too), multi-buffer
truncation (`ConvertToContiguousBuffer` is used), parser trouble with large
Annex-B NALs (decodes 60/60), and `streamheader` on the caps (no effect).

## v2: give decoders a finite error budget

The counter resets in `gst_video_decoder_clip_and_push_buf` — only when a
frame is genuinely pushed out — so a finite `max-errors` means *"this many
consecutive failures with no output"*: a dead decoder, not a glitch.

`wg_transform` creates its decoder directly via
`find_element(GST_ELEMENT_FACTORY_TYPE_DECODER, ...)` (no `decodebin`), so
the hook is a one-liner beside the existing `set_max_threads(element)`:

```c
static void set_max_errors(GstElement *element)
{
    if (!GST_IS_VIDEO_DECODER(element))
        return;
    gst_video_decoder_set_max_errors(GST_VIDEO_DECODER(element),
                                     WG_DECODER_MAX_CONSECUTIVE_ERRORS);
}
```

with `WG_DECODER_MAX_CONSECUTIVE_ERRORS` set to 30 — one GOP at the
keyframe intervals seen here, so the decoder has had a keyframe opportunity
and still produced nothing. After the budget is exhausted the decoder
returns `GST_FLOW_ERROR` and the v1 latch does the rest.

Built and verified (240,400 bytes, x86_64, `gst_video_decoder_set_max_errors`
present as a linked import). Runtime result pending.

## What it changes (v1 layer, still part of the patch)

`get_transform_output()` already captures the `GstFlowReturn` from
`gst_pad_push()` and discards it:

```c
if ((ret = gst_pad_push(transform->my_src, input_buffer)))
    GST_WARNING("Failed to push transform input, error %d", ret);
```

When a decoder rejects its input, downstream returns `GST_FLOW_ERROR` and the
transform can never produce output again — but the loop continues and
`wg_transform_read_data()` goes on reporting `MF_E_TRANSFORM_NEED_MORE_INPUT`.
The patch latches fatal returns and reports them instead.

## Why flow returns rather than the bus

The obvious fix is to watch the pipeline bus for `GST_MESSAGE_ERROR`. That is
harder here than it looks: `transform->container` is created with
`gst_bin_new()`, not `gst_pipeline_new()`, and an unparented `GstBin` has no
bus of its own. Bus-based detection would mean adding a pipeline or a
dedicated bus plus a watch — considerably more invasive.

The flow return is already in hand at exactly the right point. It is the
smaller change and it needs no new plumbing.

## Deliberate choices

- **Only genuinely fatal returns latch.** `GST_FLOW_FLUSHING` and
  `GST_FLOW_EOS` occur normally during seeks, drains and end of stream, and
  must not poison the transform.
- **`break` on fatal error** rather than continuing to drain input into a
  chain that cannot accept it.
- **`MF_E_INVALID_STREAM_DATA`** as the reported result. It matches the
  observed cause (a decoder rejecting malformed input). `MF_E_UNEXPECTED` or
  mapping `GST_FLOW_NOT_NEGOTIATED` to `MF_E_INVALIDMEDIATYPE` are reasonable
  alternatives a maintainer may prefer.

## Known gaps — a maintainer will want these addressed

1. ~~**Flush/reset does not clear the latch.**~~ **Resolved** in the real
   patch: `wg_transform_flush()` sets `fatal_flow_ret = GST_FLOW_OK`.
   Original note kept for the record: `wg_transform_flush()` (and any
   seek or format-change path) should reset `fatal_flow_ret` to
   `GST_FLOW_OK`, or a single bad clip will permanently disable a transform
   that is then reused. This is the most likely review comment.
2. ~~**Diff context is approximate.**~~ **Resolved**: now a real `git diff`
   against `wine-10.0`. Original note: Hunk headers use function names rather
   than line numbers because the patch was written against a reading of the
   file, not a checkout. It needs regenerating with `git diff` against a real
   tree before submission.
3. **No test.** Wine's test suite has winegstreamer coverage under
   `dlls/mf/tests` and `dlls/winegstreamer/tests`; a case feeding a decoder
   deliberately malformed data and asserting that a failure is returned
   rather than `MF_E_TRANSFORM_NEED_MORE_INPUT` would make this far more
   likely to be accepted.
4. **Unverified against the real failure.** The reasoning is sound and the
   evidence is in `BUGREPORT-winegstreamer.md`, but nobody has yet confirmed
   that latching this specific error unblocks this specific hang. Building
   Wine for macOS and grafting a rebuilt `winegstreamer` into the wrapper
   would be the way to prove it.

## If submitting

Send to `wine-devel` or open a merge request on the Wine GitLab, with the bug
report as context. Expect to be asked for item 1 and item 3 above.
