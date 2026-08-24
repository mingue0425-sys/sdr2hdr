# HDR calibration dataset

Add only authorized, same-content SDR/HDR pairs. A pair must be declared in
`manifest.json`; filenames alone are never treated as evidence of a match.

Example:

```json
{
  "version": 1,
  "pairs": [
    {
      "id": "owned_clip_001",
      "sdr": "owned_clip_001/sdr.mp4",
      "hdr": "owned_clip_001/hdr.mp4",
      "license": "user_owned",
      "source": "local",
      "expectedRelation": "same_master",
      "split": "tune",
      "notes": "same edit and frame rate"
    }
  ]
}
```

The HDR side must expose BT.2020 PQ metadata and a 10-bit P010-compatible
decoded path. HLG is intentionally rejected until its absolute-luminance
viewing assumptions are supplied explicitly.
