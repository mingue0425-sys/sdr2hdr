"""Finds KBS K-Choreo HDR uploads on YouTube and, on request, downloads new ones into the repository.

Discovery only reads YouTube metadata. A candidate must satisfy all of the following:

- it comes from the KBS Kpop channel search, and its title contains both "K-Choreo" and "HDR";
- it is not already in the open-content-v2 manifest, by YouTube id or by song;
- its song is not shared with another candidate. The same stage is often uploaded more than once
  (e.g. a "Spatial Sound" version), and two copies in different splits would leak Tune into Validation,
  so only the first listing per song is kept;
- it offers both itag 642 (VP9 Profile 2 HDR) and itag 628 (VP9 SDR of the same upload).

Metadata requests are throttled: at most --probe-limit (default 20) listings are probed per run, one at a time,
--probe-delay seconds apart. Probing stops at YouTube's first bot check, and probe results from an earlier report
are reused, so re-running later continues where it stopped. Browser cookies are never used.

`--download N` fetches the first N accepted candidates:

- files go to data_video/kchoreo-v2/<id>/<id>.f642.mp4 and .f628.mp4;
- yt-dlp runs with --no-cache-dir and keeps its temporary files in .build/tmp;
- each HDR file must decode as HLG (arib-std-b67), otherwise the download is removed;
- downloading stops when free disk space would fall below --min-free-gb.

The report (JSON) lists every listing with its decision. `--emit-list` writes the downloaded ids, in order,
for add_kchoreo_from_list.py. No media is decoded beyond ffprobe stream tags.

Usage:
  python3 -I find_kchoreo_hdr.py REPO_ROOT --report OUT.json [--download N] [--emit-list LIST.json]
"""
import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import time
import urllib.parse

CHANNEL = 'https://www.youtube.com/@KBSKpop/search?query='
ID_IN_BRACKETS = re.compile(r'\[([A-Za-z0-9_-]{11})\]')
QUOTED = re.compile(r"['‘’\"“”]([^'‘’\"“”]+)['‘’\"“”]")
# Listing titles name the artist as "(ATEEZ Choreography)"; manifest sources as "(LE SSERAFIM 'HOT')".
CHOREO_ARTIST = re.compile(r'\(([^()]+?) Choreography\)')
SOURCE_ARTIST = re.compile(r"\(([^()']+?) ['‘]")


def normalise(text):
    """Lower-case alphanumerics. Titles like '퀸카 (Queencard)' keep only the Latin part, so the
    bilingual and English spellings of one song agree; all-Hangul names stay as they are."""
    value = re.sub(r'[^0-9a-z가-힣]+', '', text.lower())
    latin = re.sub(r'[가-힣]+', '', value)
    return latin or value


def song_key(text):
    """Artist + song, so the same song by two artists stays distinct."""
    text = re.sub(r'\(G\)\s*-?\s*I-?DLE', 'GIDLE', text or '', flags=re.IGNORECASE)
    song = QUOTED.search(text)
    artist = CHOREO_ARTIST.search(text) or SOURCE_ARTIST.search(text)
    if not song or not artist:
        return None
    return normalise(artist.group(1)) + '/' + normalise(song.group(1)) or None


def yt_dlp(root, *args):
    env = dict(os.environ, TMPDIR=f'{root}/.build/tmp/')
    return subprocess.run(['yt-dlp', '--no-cache-dir', *args], capture_output=True, text=True, env=env)


def existing(root):
    manifest = json.load(open(f'{root}/data_video/open-content-v2/manifest.json'))
    ids, songs = set(), set()
    for pair in manifest['pairs']:
        text = ' '.join(str(pair.get(k, '')) for k in ('source', 'sourceURL', 'sdr', 'hdr', 'id'))
        ids.update(ID_IN_BRACKETS.findall(text))
        url = pair.get('sourceURL', '')
        if 'watch?v=' in url:
            ids.add(url.split('watch?v=')[1][:11])
        key = song_key(pair.get('source', '')) or song_key(pair.get('hdr', '').replace('[', '(').replace(']', ')'))
        if key:
            songs.add(key)
    return ids, songs


BOT_CHECK = 'confirm you’re not a bot'


def probe(root, vid):
    out = yt_dlp(root, '-J', '--skip-download', '--', f'https://www.youtube.com/watch?v={vid}')
    if out.returncode != 0:
        message = (out.stderr.strip().splitlines() or ['yt-dlp failed'])[-1]
        return {'error': message, 'botCheck': BOT_CHECK in message}
    meta = json.loads(out.stdout)
    formats = {f.get('format_id') for f in meta.get('formats', [])}
    return {'channel': meta.get('channel'), 'uploadDate': meta.get('upload_date'),
            'duration': meta.get('duration'), 'has642': '642' in formats, 'has628': '628' in formats}


def free_gb(path):
    return shutil.disk_usage(path).free / 1e9


def download(root, vid, min_free_gb):
    target = f'{root}/data_video/kchoreo-v2/{vid}'
    os.makedirs(target, exist_ok=True)
    for itag in ('642', '628'):
        if free_gb(root) < min_free_gb + 1.5:
            return 'stopped: free space below --min-free-gb'
        out = yt_dlp(root, '--no-progress', '-q', '-f', itag, '-o', f'{target}/{vid}.f{itag}.%(ext)s',
                     '--paths', f'temp:{root}/.build/tmp/yt', '--', f'https://www.youtube.com/watch?v={vid}')
        if out.returncode != 0:
            return f'failed: itag {itag}'
    transfer = subprocess.run(['ffprobe', '-v', 'error', '-select_streams', 'v:0', '-show_entries',
                               'stream=color_transfer', '-of', 'csv=p=0', '--', f'{target}/{vid}.f642.mp4'],
                              capture_output=True, text=True).stdout.strip().strip(',')
    if transfer != 'arib-std-b67':
        shutil.rmtree(target)
        return f'removed: HDR transfer is {transfer or "unknown"}, not HLG'
    return 'downloaded'


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('root')
    parser.add_argument('--report', required=True)
    parser.add_argument('--query', default='K-Choreo 8K HDR')
    parser.add_argument('--download', type=int, default=0)
    parser.add_argument('--min-free-gb', type=float, default=15)
    parser.add_argument('--emit-list')
    parser.add_argument('--probe-limit', type=int, default=20)
    parser.add_argument('--probe-delay', type=float, default=3.0)
    args = parser.parse_args()
    root = os.path.abspath(args.root)

    listing = yt_dlp(root, '--flat-playlist', '-J', CHANNEL + urllib.parse.quote(args.query))
    if listing.returncode != 0:
        sys.exit('channel search failed: ' + listing.stderr[-300:])
    entries = json.loads(listing.stdout).get('entries', [])
    known_ids, known_songs = existing(root)

    rows, seen_songs, to_probe = [], set(), []
    for entry in entries:
        vid, title = entry.get('id'), entry.get('title') or ''
        key = song_key(title)
        row = {'id': vid, 'title': title, 'song': key}
        if 'K-Choreo' not in title or 'HDR' not in title:
            row['decision'] = 'skip: title lacks K-Choreo/HDR'
        elif vid in known_ids:
            row['decision'] = 'skip: already in manifest'
        elif key is None:
            row['decision'] = 'skip: no artist/song in title'
        elif key in known_songs:
            row['decision'] = 'skip: song already in manifest'
        elif key in seen_songs:
            row['decision'] = 'skip: duplicate song in listing'
        else:
            seen_songs.add(key)
            row['decision'] = 'probe'
            to_probe.append(row)
        rows.append(row)

    # Probe one listing at a time, at most --probe-limit of them, with a pause between requests.
    # YouTube answers a burst of metadata requests with a bot check; on the first one, probing stops
    # and the remaining rows are left unprobed. Probe results from an earlier report are reused.
    previous = {}
    if os.path.exists(args.report):
        for row in json.load(open(args.report)).get('rows', []):
            if row.get('decision') in ('candidate', 'downloaded') or 'has642' in row:
                previous[row['id']] = {k: row[k] for k in ('channel', 'uploadDate', 'duration', 'has642', 'has628')
                                       if k in row}
    probed = 0
    blocked = False
    for row in to_probe:
        if row['id'] in previous:
            info = previous[row['id']]
        elif blocked or probed >= args.probe_limit:
            row['decision'] = 'not probed: ' + ('YouTube bot check' if blocked else 'probe limit')
            continue
        else:
            if probed:
                time.sleep(args.probe_delay)
            info = probe(root, row['id'])
            probed += 1
            if info.get('botCheck'):
                blocked = True
                row['decision'] = 'not probed: YouTube bot check'
                continue
        row.update(info)
        if 'error' in info:
            row['decision'] = 'skip: metadata unavailable'
        elif info.get('channel') != 'KBS Kpop':
            row['decision'] = 'skip: not the KBS Kpop channel'
        elif not (info.get('has642') and info.get('has628')):
            row['decision'] = 'skip: no 642/628 HDR+SDR pair'
        else:
            row['decision'] = 'candidate'
    if blocked:
        print('YouTube asked for a bot check; probing stopped. Re-run later to continue (earlier results are reused).',
              file=sys.stderr)

    downloaded = []
    for row in [r for r in rows if r['decision'] == 'candidate'][:max(args.download, 0)]:
        row['decision'] = download(root, row['id'], args.min_free_gb)
        print(row['id'], row['decision'], flush=True)
        if row['decision'] == 'downloaded':
            downloaded.append({'id': row['id'], 'title': row['title'], 'uploadDate': row.get('uploadDate')})
        elif row['decision'].startswith('stopped'):
            break

    json.dump({'query': args.query, 'listed': len(entries), 'rows': rows}, open(args.report, 'w'),
              indent=2, ensure_ascii=False)
    if args.emit_list:
        json.dump(downloaded, open(args.emit_list, 'w'), indent=2, ensure_ascii=False)
    counts = {}
    for row in rows:
        counts[row['decision'].split(':')[0]] = counts.get(row['decision'].split(':')[0], 0) + 1
    print('listed', len(entries), counts)


if __name__ == '__main__':
    main()
