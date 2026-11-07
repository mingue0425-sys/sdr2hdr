#!/bin/bash
# Round 3: more user-provided KBS Kpop HDR uploads (HLG HDR itag 642 + platform SDR itag 628 of the same upload).
# Run from the repository root. yt-dlp cache is disabled so nothing is written outside the repo.
set -u
ids=(-cnGceAdbs4 xWyeg5qYL2I BXa_OjjJIDY rjQX-XKilF8 iSEvfuJO0hQ 2IGhGkJIq0k GXUlNQMZuzo 7PMhlVxFfZg)
for id in "${ids[@]}"; do
  d=data_video/kchoreo-v2/$id; mkdir -p "$d"
  for f in 642 628; do
    yt-dlp --no-cache-dir --no-progress -q -f $f -o "$d/${id}.f${f}.%(ext)s" --paths temp:.build/tmp/yt -- "https://www.youtube.com/watch?v=$id" \
      && echo "OK $id f$f $(ls -l "$d"/${id}.f${f}.* | awk '{printf "%.2fGB", $5/1e9}')" || echo "FAILED $id f$f"
  done
done
echo DONE
