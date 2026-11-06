#!/bin/bash
# Reproduces the open-content-v2 media excerpts (run from the repository root).
# Downloads go only under sdr2hdr-real-media/. Requires ffmpeg, curl, python3 + numpy.
set -u
cd /Volumes/game/sdr2hdr
R=sdr2hdr-real-media
A=dataset/acquisition/open-content-v2
NOC=https://s3.amazonaws.com/download.opencontent.netflix.com/Nocturne/nocturne_filmgrain
S3=https://dpel-assets.aswf.io/asc-stem3/Warped-Cybercity
TAG="prores_metadata=color_primaries=bt709:color_trc=bt709:colorspace=bt709"
F=(-hide_banner -nostdin -loglevel error -y -rw_timeout 60000000)
get() { # start url out frames [bsf]
  local args=("${F[@]}" -ss "$1" -i "$2" -map 0:v:0 -c copy)
  if [ "${5:-}" != "" ]; then args+=(-bsf:v "$5"); fi
  args+=(-frames:v "$4" "$3")
  ffmpeg "${args[@]}" && ls -l "$3" | awk '{printf "OK %.2fGB %s\n",$5/1e9,$9}' || echo "FAILED $3"
}
mkdir -p $R/netflix-opencontent/nocturne/raw $R/aswf-dpel/stem3-warped $R/aswf-dpel/solemates/zip
echo "=== solemates $(date)"
curl -sS --fail -o $R/aswf-dpel/solemates/zip/quicktime_media-sdr_hdr-v1.0.0.zip https://aswf-dpel-assets.s3.amazonaws.com/solemates/quicktime_media-sdr_hdr-v1.0.0.zip && (cd $R/aswf-dpel/solemates && unzip -o -q zip/quicktime_media-sdr_hdr-v1.0.0.zip && ls -l quick_times-sdr_hdr-v1.0.0/) || echo "FAILED solemates"
echo "=== stem3 tune $(date)"
for t in 79 158; do
  get $t $S3/Warped_Cybercity_1920x1080_Rec709_BT1886_5.1ch.mov $R/aswf-dpel/stem3-warped/warped_sdr_t${t}_120f.mov 120 "$TAG"
  get $t $S3/Warped_Cybercity_3840x2160_Rec2100_ST2084_500nits_5.1ch.mov $R/aswf-dpel/stem3-warped/warped_hdr_t${t}_120f.mov 120
done
echo "=== nocturne $(date)"
for f in 11961 19935 27909; do
  s=$(python3 -c "print(f'{$f/60:.6f}')")
  get $s $NOC/nocturne_60fps_uhd_filmgrain_sdr.mov $R/netflix-opencontent/nocturne/nocturne_sdr_f${f}_120f.mov 120 "$TAG"
  get $s $NOC/nocturne_60fps_uhd_filmgrain_hdr.mov $R/netflix-opencontent/nocturne/raw/nocturne_hdr_p3_f${f}_120f.mov 120
  raw=$R/netflix-opencontent/nocturne/raw/nocturne_hdr_p3_f${f}_120f.mov
  out=$R/netflix-opencontent/nocturne/nocturne_hdr_f${f}_120f.mov
  [ -f "$raw" ] || continue
  ffmpeg "${F[@]}" -i "$raw" -vf "scale=in_color_matrix=bt709:in_range=tv:out_range=full,format=gbrp16le" -f rawvideo -pix_fmt gbrp16le - \
    | python3 -I $A/p3_to_2020.py 3840 2160 \
    | ffmpeg "${F[@]}" -f rawvideo -pix_fmt gbrp16le -s 3840x2160 -r 60 -i - \
        -vf "scale=out_color_matrix=bt2020:out_range=tv,format=yuv444p12le" -c:v prores_ks -profile:v 5 -vendor apl0 \
        -color_primaries bt2020 -color_trc smpte2084 -colorspace bt2020nc -color_range tv "$out" \
    && ls -l "$out" | awk '{printf "OK %.2fGB %s\n",$5/1e9,$9}' || echo "FAILED convert $f"
  # prores_ks leaves primaries/transfer untagged; retag headers losslessly.
  ffmpeg "${F[@]}" -i "$out" -map 0:v:0 -c copy \
    -bsf:v "prores_metadata=color_primaries=bt2020:color_trc=smpte2084:colorspace=bt2020nc" \
    -color_primaries bt2020 -color_trc smpte2084 -colorspace bt2020nc "$out.tag.mov" && mv "$out.tag.mov" "$out" || echo "FAILED retag $f"
done
echo "=== done $(date)"
