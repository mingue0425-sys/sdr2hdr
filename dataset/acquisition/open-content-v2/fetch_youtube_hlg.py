"""Downloads same-upload HDR (HLG) and SDR renditions of YouTube uploads listed in a plan.

The plan (JSON list) is written before anything is downloaded, from titles and uploaders only:
  [{"id": "...", "family": "...", "split": "tune|validation|frozen", "maxHeight": 4320 (optional), "note": "..."}]

For each entry:
- read the format list (one metadata request, --probe-delay seconds apart; stop at the first bot check);
- pick the highest VP9 Profile 2 (HDR) format at or below --max-height, and the VP9 Profile 0 (SDR) format of the same
  upload at the same height and frame rate, so the two renditions differ only by YouTube's conversion;
- download both, remuxed to MP4, to data_video/youtube-hlg/<id>/<id>.hdr.<itag>.mp4 and .sdr.<itag>.mp4 (yt-dlp --no-cache-dir,
  temporary files in .build/tmp);
- keep the pair only if the HDR stream is tagged HLG (arib-std-b67); otherwise delete it.

No media is decoded beyond ffprobe stream tags. Browser cookies are never used. Downloading stops when free disk
space would fall below --min-free-gb. The result (JSON) lists every entry with its decision and, for kept pairs, the
file paths and itags, for add_youtube_hlg_from_list.py.

Usage: python3 -I fetch_youtube_hlg.py REPO_ROOT PLAN.json RESULT.json [--max-height 2160] [--min-free-gb 6]
"""
import argparse, json, os, shutil, subprocess, sys, time

BOT_CHECK = 'confirm you’re not a bot'


def yt_dlp(root, *args):
    env = dict(os.environ, TMPDIR=f'{root}/.build/tmp/')
    return subprocess.run(['yt-dlp', '--no-cache-dir', *args], capture_output=True, text=True, env=env)


def pick(formats, max_height):
    def vp9(f, profile):
        codec = f.get('vcodec') or ''
        return codec.startswith(f'vp09.0{profile}') or (profile == 2 and codec == 'vp9.2') or \
            (profile == 0 and codec == 'vp9')
    hdr = [f for f in formats if vp9(f, 2) and (f.get('height') or 0) <= max_height]
    for h in sorted(hdr, key=lambda f: ((f.get('height') or 0), f.get('fps') or 0, f.get('tbr') or 0), reverse=True):
        sdr = [f for f in formats if vp9(f, 0) and f.get('height') == h.get('height') and f.get('fps') == h.get('fps')
               and (f.get('dynamic_range') in (None, 'SDR'))]
        if sdr:
            return h, max(sdr, key=lambda f: f.get('tbr') or 0)
    return None, None


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('root')
    parser.add_argument('plan')
    parser.add_argument('result')
    parser.add_argument('--max-height', type=int, default=2160)
    parser.add_argument('--min-free-gb', type=float, default=6)
    parser.add_argument('--probe-delay', type=float, default=4)
    args = parser.parse_args()
    root = os.path.abspath(args.root)
    plan = json.load(open(args.plan))
    previous = {r['id']: r for r in json.load(open(args.result))} if os.path.exists(args.result) else {}
    results = []
    blocked = False
    for index, entry in enumerate(plan):
        row = dict(entry)
        done = previous.get(entry['id'])
        if done and (done['decision'] == 'kept' or done['decision'].startswith('skip')):
            results.append(done)
            continue
        if blocked:
            row['decision'] = 'not probed: YouTube bot check'
            results.append(row)
            continue
        if index:
            time.sleep(args.probe_delay)
        out = yt_dlp(root, '-J', '--skip-download', '--', f"https://www.youtube.com/watch?v={entry['id']}")
        if out.returncode != 0:
            message = (out.stderr.strip().splitlines() or ['yt-dlp failed'])[-1]
            blocked = BOT_CHECK in message
            row['decision'] = 'not probed: YouTube bot check' if blocked else 'skip: metadata unavailable'
            results.append(row)
            continue
        meta = json.loads(out.stdout)
        row.update({'title': meta.get('title'), 'uploader': meta.get('channel') or meta.get('uploader'),
                    'uploadDate': meta.get('upload_date'), 'duration': meta.get('duration'),
                    'license': meta.get('license')})
        hdr, sdr = pick(meta.get('formats', []), entry.get('maxHeight', args.max_height))
        if not hdr:
            row['decision'] = 'skip: no VP9 HDR/SDR pair at one height and frame rate'
            results.append(row)
            continue
        target = f"{root}/data_video/youtube-hlg/{entry['id']}"
        os.makedirs(target, exist_ok=True)
        files = {}
        for role, fmt in (('hdr', hdr), ('sdr', sdr)):
            if shutil.disk_usage(root).free / 1e9 < args.min_free_gb + 1.5:
                row['decision'] = 'stopped: free space below --min-free-gb'
                break
            path = f"{target}/{entry['id']}.{role}.{fmt['format_id']}.%(ext)s"
            # Remux (stream copy) to MP4: AVFoundation cannot open WebM, and *.mp4 is git-ignored.
            got = yt_dlp(root, '--no-progress', '-q', '-f', fmt['format_id'], '--remux-video', 'mp4', '-o', path,
                         '--paths', f'temp:{root}/.build/tmp/yt', '--', f"https://www.youtube.com/watch?v={entry['id']}")
            if got.returncode != 0:
                row['decision'] = f"failed: itag {fmt['format_id']}"
                break
            files[role] = path.replace('%(ext)s', 'mp4')
        if 'decision' in row:
            results.append(row)
            if row['decision'].startswith('stopped'):
                break
            continue
        transfer = subprocess.run(['ffprobe', '-v', 'error', '-select_streams', 'v:0', '-show_entries',
                                   'stream=color_transfer', '-of', 'csv=p=0', '--', files['hdr']],
                                  capture_output=True, text=True).stdout.strip().strip(',')
        if transfer != 'arib-std-b67':
            shutil.rmtree(target)
            row['decision'] = f'skip: HDR transfer is {transfer or "unknown"}, not HLG'
        else:
            row.update({'decision': 'kept', 'hdrItag': hdr['format_id'], 'sdrItag': sdr['format_id'],
                        'height': hdr.get('height'), 'fps': hdr.get('fps'),
                        'hdrFile': os.path.relpath(files['hdr'], root), 'sdrFile': os.path.relpath(files['sdr'], root)})
        print(entry['id'], row['decision'], flush=True)
        results.append(row)
    seen = {r['id'] for r in results}
    results += [dict(e, decision='not reached') for e in plan if e['id'] not in seen]
    json.dump(results, open(args.result, 'w'), indent=2, ensure_ascii=False)
    counts = {}
    for r in results:
        counts[r['decision'].split(':')[0]] = counts.get(r['decision'].split(':')[0], 0) + 1
    print(counts)


if __name__ == '__main__':
    main()
