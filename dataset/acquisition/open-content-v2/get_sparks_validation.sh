#!/bin/bash
# Sparks Validation windows for open-content-v2 (15%/45% of 13777 frames; away from consumed f04133/f08266).
# HDR TIFF headers carry no PQ tags; the encode writes BT.2020/ST.2084 tags; check with ffprobe afterwards.
set -euo pipefail
B=https://s3.amazonaws.com/download.opencontent.netflix.com/sparks
OUT=sdr2hdr-real-media/netflix-opencontent/sparks
TMP=.build/tmp/sparks
mkdir -p "$OUT" "$TMP"
N=96
for start in 2067 6200; do
  W="$TMP/w$start"; mkdir -p "$W"
  seq $start $((start+N-1)) | xargs -P 8 -I{} sh -c 'f=$(printf "SPARKS_HDR10_4K_2020_PQ_1000nits_%05d.tif" {}); curl -sf --retry 3 --max-time 600 -o "'"$W"'/$f" "'"$B"'/HDR10_1000nit_PQ_2020_image_sequence/$f"'
  test "$(ls "$W" | wc -l | tr -d ' ')" = "$N"
  ffmpeg -hide_banner -nostdin -loglevel error -y -framerate 60000/1001 -start_number $start \
    -i "$W/SPARKS_HDR10_4K_2020_PQ_1000nits_%05d.tif" -frames:v $N \
    -vf "scale=out_color_matrix=bt2020nc:out_range=tv:flags=accurate_rnd+full_chroma_int,format=yuv444p10le,setparams=color_primaries=bt2020:color_trc=smpte2084:colorspace=bt2020nc:range=tv" \
    -c:v prores_ks -profile:v 5 -vendor apl0 -color_primaries bt2020 -color_trc smpte2084 -colorspace bt2020nc -color_range tv \
    "$OUT/sparks_hdr10_f$(printf %05d $start)_${N}f.mov"
  python3 -I -c "import hashlib,glob,json,sys; print(json.dumps({f.rsplit('/',1)[1]:hashlib.sha256(open(f,'rb').read()).hexdigest() for f in sorted(glob.glob('$W/*.tif'))}))" > "$TMP/tif-sha256-$start.json"
  rm -rf "$W"
  ss=$(python3 -c "print(($start+0.5)*1001/60000)")
  ffmpeg -hide_banner -nostdin -loglevel error -y -rw_timeout 60000000 -ss $ss -i "$B/sdr/Sparks_SDR_UHD_4096x2160_5994fps.mov" -map 0:v:0 -c copy -frames:v $N "$OUT/sparks_sdr_f$(printf %05d $start)_${N}f.mov"
  ls -l "$OUT" | awk 'NR>1{printf "%.2fGB %s\n",$5/1e9,$9}'
done
date; echo DONE
