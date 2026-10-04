# Notes on `wg_transform-error-propagation.patch`

**Status: untested draft.** Written from a reading of Wine master, not built
or run. Treat it as a proposal to accompany the bug report, not a tested fix.

## What it changes

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

1. **Flush/reset does not clear the latch.** `wg_transform_flush()` (and any
   seek or format-change path) should reset `fatal_flow_ret` to
   `GST_FLOW_OK`, or a single bad clip will permanently disable a transform
   that is then reused. This is the most likely review comment.
2. **Diff context is approximate.** Hunk headers use function names rather
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
