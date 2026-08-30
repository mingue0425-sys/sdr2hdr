#!/usr/bin/env bash
set -Eeuo pipefail

###############################################################################
# Strict importer v23
#
# Candidate:
#   DVB Live-Linear 03_hevc_uhd_sdr_ac4
#   DVB Live-Linear 05_hevc_uhd_hlg_heaac
#
# Goal:
#   Produce a strictly validated, still-unconsumed virgin SDR/HLG pair.
#
# Evidence hierarchy:
#   1. Official DVB Live-Linear page identifies the services and shared source.
#   2. Runtime-resolved official DASH MPDs are captured and hashed.
#   3. HEVC stream/VUI metadata is checked with ffprobe.
#   4. Every captured video frame must decode without error.
#   5. Full captured timelines are compared using low-resolution spatial and
#      temporal fingerprints.
#   6. No frozen/holdout/dataset-lock file is modified.
###############################################################################

say() { printf '\033[1m==>\033[0m %s\n' "$*"; }
ok()  { printf '\033[1;32mPASS\033[0m %s\n' "$*"; }
die() { printf '\033[1;31mFAIL\033[0m %s\n' "$*" >&2; exit 1; }

trap 'rc=$?; printf "\033[1;31mFAILED\033[0m at line %s (exit %s)\n" "$LINENO" "$rc" >&2' ERR

command -v git >/dev/null 2>&1 || die "git not found"
command -v curl >/dev/null 2>&1 || die "curl not found"
command -v ffmpeg >/dev/null 2>&1 || die "ffmpeg not found"
command -v ffprobe >/dev/null 2>&1 || die "ffprobe not found"
command -v python3 >/dev/null 2>&1 || die "python3 not found"

REPO="$(git rev-parse --show-toplevel 2>/dev/null || true)"
[ -n "$REPO" ] || die "run inside the sdr2hdr git repository"
cd "$REPO"

OFFICIAL_PAGE="https://live-linear.dvb.org/"
SDR_SERVICE="03_hevc_uhd_sdr_ac4"
HDR_SERVICE="05_hevc_uhd_hlg_heaac"
SOURCE_TOKEN="Caminandes_E1"
PAIR_ID="dvb_live_linear_caminandes_hevc_uhd_sdr_hlg"

OUT="$REPO/data_video/virgin_candidates/$PAIR_ID"
META="$OUT/metadata"
WORK="$OUT/.work"
mkdir -p "$META" "$WORK"

HOME_HTML="$META/dvb-live-linear.html"
SERVICE_LIST_XML="$META/tagdvborg2025dvblivelinear.xml"
SERVICE_LIST_EVIDENCE="$META/service-list-evidence.json"
PROVIDER_EVIDENCE="$META/provider-evidence.json"
RESOLVE_JSON="$META/resolved-manifests.json"
SDR_MPD_FILE="$META/sdr.mpd"
HDR_MPD_FILE="$META/hdr.mpd"

FINAL_SDR_CAPTURE="$OUT/DVB_LiveLinear_03_HEVC_UHD_SDR.mp4"
FINAL_HDR_CAPTURE="$OUT/DVB_LiveLinear_05_HEVC_UHD_HLG.mp4"
FINAL_MANIFEST="$OUT/VIRGIN_PAIR_VALID.json"

# Validate entirely against pending assets. Existing validated assets and the
# PAIR_VALID_VIRGIN manifest are replaced only after every gate succeeds.
PENDING="$WORK/pending"
mkdir -p "$PENDING"
SDR_CAPTURE="$PENDING/DVB_LiveLinear_03_HEVC_UHD_SDR.mp4"
HDR_CAPTURE="$PENDING/DVB_LiveLinear_05_HEVC_UHD_HLG.mp4"
PENDING_MANIFEST="$PENDING/VIRGIN_PAIR_VALID.json"

CAPTURE_SECONDS="${CAPTURE_SECONDS:-70}"
MIN_CONTIGUOUS_SEGMENTS=14
ALIGN_MAX_OFFSET_SECONDS="${ALIGN_MAX_OFFSET_SECONDS:-8}"
GRID_W=32
GRID_H=18
GRID_FRAME_BYTES=$((GRID_W * GRID_H))
MIN_ALIGNED_SECONDS="${MIN_ALIGNED_SECONDS:-50}"

say "repo: $REPO"
say "pair output: $OUT"
say "bash runtime: ${BASH_VERSION:-unknown}"

python3 - "$META/bash-runtime.json" "${BASH_VERSION:-unknown}" <<'PY'
import json
import sys

outp, version = sys.argv[1:]
with open(outp, "w", encoding="utf-8") as f:
    json.dump(
        {
            "bash_version": version,
            "compatibility_target": "macOS system Bash 3.2+",
            "nested_heredoc_inside_command_substitution": False,
        },
        f,
        ensure_ascii=False,
        indent=2,
    )
    f.write("\n")
PY

###############################################################################
# 1) VIRGIN SOURCE-ID / HISTORY GUARD
###############################################################################

say "checking current tree, local results, and full git history for prior source consumption"

python3 - \
  "$REPO" "$OUT" \
  "$SDR_SERVICE" "$HDR_SERVICE" "$SOURCE_TOKEN" "$OFFICIAL_PAGE" <<'PY'
import os
import subprocess
import sys

repo, out, sdr_id, hdr_id, source_token, official = sys.argv[1:]

tokens = [
    sdr_id,
    hdr_id,
    source_token,
    "Caminandes_E1-1080p_50fps.mp4",
    "dvb_live_linear_caminandes_hevc_uhd_sdr_hlg",
]

# Current tracked tree. Exclude the candidate output and the importer itself.
tracked = subprocess.check_output(
    ["git", "-C", repo, "ls-files"],
    text=True,
).splitlines()

hits = []
for rel in tracked:
    full = os.path.join(repo, rel)
    if os.path.abspath(full).startswith(os.path.abspath(out) + os.sep):
        continue
    if os.path.basename(rel).startswith("add_virgin_hlg_pair"):
        continue
    try:
        data = open(full, "rb").read()
    except Exception:
        continue
    low = data.lower()
    for token in tokens:
        if token.encode().lower() in low:
            hits.append(("current-tree", rel, token))

# Full git history: source names/IDs must never have appeared in committed
# calibration evidence. Importer filenames are deliberately excluded.
for token in tokens:
    p = subprocess.run(
        [
            "git", "-C", repo, "log", "--all", "-S", token,
            "--pretty=format:%H%x09%s", "--",
            ":(exclude)add_virgin_hlg_pair*.sh",
            ":(exclude)data_video/virgin_candidates/**",
        ],
        capture_output=True,
        text=True,
    )
    if p.stdout.strip():
        for line in p.stdout.splitlines()[:20]:
            hits.append(("git-history", line, token))

# Local untracked/result text evidence outside this candidate.
for root_name in ("results", "data_video"):
    root = os.path.join(repo, root_name)
    if not os.path.isdir(root):
        continue
    for dp, dns, fns in os.walk(root):
        abs_dp = os.path.abspath(dp)
        if abs_dp.startswith(os.path.abspath(out)):
            dns[:] = []
            continue
        dns[:] = [d for d in dns if d not in {".git", ".work"}]
        for fn in fns:
            if not fn.lower().endswith(
                (".json", ".md", ".txt", ".csv", ".yaml", ".yml", ".toml")
            ):
                continue
            full = os.path.join(dp, fn)
            try:
                data = open(full, "rb").read().lower()
            except Exception:
                continue
            for token in tokens:
                if token.encode().lower() in data:
                    hits.append(("local-metadata", os.path.relpath(full, repo), token))

if hits:
    print("Prior-consumption evidence found:", file=sys.stderr)
    for kind, where, token in hits[:100]:
        print("  %s | %s | %s" % (kind, where, token), file=sys.stderr)
    raise SystemExit(1)

print("virgin source-ID/history guard passed")
PY

ok "no prior Caminandes/DVB Live-Linear source consumption found"

###############################################################################
# 2) FETCH OFFICIAL DVB PAGE + DVB-I SERVICE LIST
###############################################################################

say "fetching official DVB Live-Linear page"

curl -fsSL \
  --retry 4 \
  --retry-delay 1 \
  --connect-timeout 15 \
  --max-time 120 \
  -A 'Mozilla/5.0 sdr2hdr-virgin-validation/1.0' \
  "$OFFICIAL_PAGE" -o "$HOME_HTML"

[ -s "$HOME_HTML" ] || die "DVB Live-Linear page fetch was empty"

say "discovering official DVB-I service-list XML"

SERVICE_LIST_URL_FILE="$WORK/service-list.url"
rm -f "$SERVICE_LIST_URL_FILE"

python3 - "$HOME_HTML" "$OFFICIAL_PAGE" >"$SERVICE_LIST_URL_FILE" <<'PY'
import html
import re
import sys
from urllib.parse import urljoin

path, base = sys.argv[1:]
raw = open(path, encoding="utf-8", errors="replace").read()

patterns = [
    r'(?is)href=["\']([^"\']*tagdvborg2025dvblivelinear\.xml[^"\']*)["\']',
    r'(?is)href=["\']([^"\']*\.xml[^"\']*)["\'][^>]*>[^<]*tagdvborg2025dvblivelinear',
]
for pat in patterns:
    m = re.search(pat, raw)
    if m:
        print(urljoin(base, html.unescape(m.group(1))))
        raise SystemExit(0)

print(urljoin(base, "tagdvborg2025dvblivelinear.xml"))
PY

SERVICE_LIST_URL="$(tr -d '\r\n' <"$SERVICE_LIST_URL_FILE")"

[ -n "$SERVICE_LIST_URL" ] || die "could not resolve DVB-I service-list URL"

curl -fsSL \
  --retry 4 \
  --retry-delay 1 \
  --connect-timeout 15 \
  --max-time 120 \
  -A 'Mozilla/5.0 sdr2hdr-virgin-validation/1.0' \
  "$SERVICE_LIST_URL" -o "$SERVICE_LIST_XML"

[ -s "$SERVICE_LIST_XML" ] || die "DVB-I service-list XML fetch was empty"

python3 - \
  "$HOME_HTML" "$OFFICIAL_PAGE" \
  "$SERVICE_LIST_XML" "$SERVICE_LIST_URL" \
  "$SDR_SERVICE" "$HDR_SERVICE" \
  "$PROVIDER_EVIDENCE" "$SERVICE_LIST_EVIDENCE" <<'PY'
import hashlib
import html
import json
import re
import sys
import xml.etree.ElementTree as ET

(
    page_path, page_url,
    xml_path, xml_url,
    sdr_id, hdr_id,
    provider_out, service_out,
) = sys.argv[1:]

page_blob = open(page_path, "rb").read()
page_raw = page_blob.decode("utf-8", "replace")
xml_blob = open(xml_path, "rb").read()

page_txt = re.sub(r"(?is)<script\b.*?</script>", " ", page_raw)
page_txt = re.sub(r"(?is)<style\b.*?</style>", " ", page_txt)
page_txt = re.sub(r"(?s)<[^>]+>", " ", page_txt)
page_txt = html.unescape(page_txt)
page_txt = re.sub(r"\s+", " ", page_txt).strip()
page_low = page_txt.lower()

errors = []

# Static HTML proves the common source. The service cards themselves are
# client-side rendered and are therefore NOT required in this HTML.
for term in (
    "Caminandes_E1-1080p_50fps.mp4",
    "Source files",
):
    if term.lower() not in page_low:
        errors.append(
            "provider source-provenance term missing from initial HTML: %s"
            % term
        )

try:
    root = ET.fromstring(xml_blob)
except Exception as exc:
    errors.append("DVB-I service-list XML parse failed: %s" % exc)
    root = None

url_re = re.compile(r'https?://[^\s<>"\']+')

def element_tokens(el):
    out = []
    if el.text and el.text.strip():
        out.append(el.text.strip())
    for k, v in el.attrib.items():
        out.extend([k, v])
    for child in list(el):
        out.extend(element_tokens(child))
        if child.tail and child.tail.strip():
            out.append(child.tail.strip())
    return out

def subtree_blob(el):
    return " ".join(element_tokens(el))

def clean_url(url):
    return html.unescape(url).rstrip(".,;)")

def candidate_service_context(service_id):
    if root is None:
        return None, []

    sid = service_id.lower()
    matches = []
    for el in root.iter():
        blob = subtree_blob(el)
        if sid in blob.lower():
            matches.append((len(blob), el, blob))

    if not matches:
        return None, []

    matches.sort(key=lambda x: x[0])

    for _, el, blob in matches:
        urls = []
        for token in element_tokens(el):
            urls.extend(clean_url(x) for x in url_re.findall(token))
        if urls:
            seen = set()
            dedup = []
            for url in urls:
                if url not in seen:
                    seen.add(url)
                    dedup.append(url)
            return blob, dedup

    # Service is present but this smallest context had no URLs.
    return matches[0][2], []

def rank_url(service_id, url):
    low = url.lower()
    score = 0
    if service_id.lower() in low:
        score += 100
    if ".mpd" in low:
        score += 80
    if "singleperiod" in low or "single-period" in low:
        score += 60
    if "jitsu" in low:
        score += 40
    if "livesim2" in low:
        score += 35
    if "multi" in low:
        score -= 10
    return score

services = {}
for role, sid in (("sdr", sdr_id), ("hdr", hdr_id)):
    context, urls = candidate_service_context(sid)

    if context is None:
        errors.append(
            "service ID not present in official DVB-I XML: %s" % sid
        )
        services[role] = {
            "id": sid,
            "found": False,
            "candidate_urls": [],
        }
        continue

    ranked = sorted(
        (
            {"url": url, "score": rank_url(sid, url)}
            for url in urls
        ),
        key=lambda x: (-x["score"], x["url"]),
    )

    services[role] = {
        "id": sid,
        "found": True,
        "context_excerpt": context[:2000],
        "candidate_urls": ranked,
    }

provider = {
    "authoritative": True,
    "page": {
        "url": page_url,
        "sha256": hashlib.sha256(page_blob).hexdigest(),
    },
    "service_list": {
        "url": xml_url,
        "sha256": hashlib.sha256(xml_blob).hexdigest(),
    },
    "shared_source_evidence": {
        "file": "Caminandes_E1-1080p_50fps.mp4",
        "verified_from_provider_initial_html":
            "caminandes_e1-1080p_50fps.mp4" in page_low,
    },
    "service_registry_policy": (
        "Initial provider HTML proves shared-source provenance; "
        "the official DVB-I XML is the authoritative runtime service "
        "registry because service cards are client-side rendered."
    ),
    "services": services,
    "errors": errors,
}

service_evidence = {
    "service_list_url": xml_url,
    "service_list_sha256": hashlib.sha256(xml_blob).hexdigest(),
    "services": services,
    "errors": errors,
}

for outp, obj in (
    (provider_out, provider),
    (service_out, service_evidence),
):
    with open(outp, "w", encoding="utf-8") as f:
        json.dump(obj, f, ensure_ascii=False, indent=2)
        f.write("\n")

print(json.dumps(provider, ensure_ascii=False, indent=2))

if errors:
    for err in errors:
        print("PROVIDER/SERVICE-LIST ERROR:", err, file=sys.stderr)
    raise SystemExit(1)
PY

ok "official DVB source provenance + DVB-I service registry verified"

###############################################################################
# 3) RESOLVE OFFICIAL MPDs FROM DVB-I DELIVERY URIS
###############################################################################

say "resolving official SDR/HLG DASH manifests from DVB-I service list"

resolve_service_mpd() {
  role="$1"
  evidence_json="$2"
  resolved_url_file="$3"
  mpd_out="$4"

  rm -f "$resolved_url_file" "$mpd_out"

  python3 - "$evidence_json" "$role" >"$WORK/${role}.service-urls.txt" <<'PY'
import json
import sys

data = json.load(open(sys.argv[1], encoding="utf-8"))
for item in data["services"][sys.argv[2]]["candidate_urls"]:
    print(item["url"])
PY

  while IFS= read -r candidate
  do
    [ -n "$candidate" ] || continue

    tmp="$WORK/${role}.candidate.body"

    if ! curl -fsSL \
      --retry 2 \
      --connect-timeout 12 \
      --max-time 45 \
      -A 'Mozilla/5.0 sdr2hdr-virgin-validation/1.0' \
      "$candidate" -o "$tmp"
    then
      continue
    fi

    if python3 - "$tmp" <<'PY'
import sys

blob = open(sys.argv[1], "rb").read(524288)
text = blob.decode("utf-8", "replace").lstrip("\ufeff \t\r\n")
raise SystemExit(0 if ("<MPD" in text or "<mpd" in text) else 1)
PY
    then
      printf '%s\n' "$candidate" >"$resolved_url_file"
      cp "$tmp" "$mpd_out"
      return 0
    fi

    python3 - "$tmp" "$candidate" >"$WORK/${role}.nested-mpd-urls.txt" <<'PY'
import html
import re
import sys
from urllib.parse import urljoin

path, base = sys.argv[1:]
raw = open(path, encoding="utf-8", errors="replace").read()

patterns = [
    r'(?i)https?://[^\s"\'<>]+\.mpd(?:\?[^\s"\'<>]*)?',
    r'(?is)(?:href|src)=["\']([^"\']+\.mpd(?:\?[^"\']*)?)["\']',
]

urls = []
for pat in patterns:
    for m in re.finditer(pat, raw):
        value = m.group(1) if m.lastindex else m.group(0)
        urls.append(urljoin(base, html.unescape(value)))

seen = set()
for url in urls:
    if url not in seen:
        seen.add(url)
        print(url)
PY

    while IFS= read -r nested
    do
      [ -n "$nested" ] || continue

      if curl -fsSL \
        --retry 2 \
        --connect-timeout 12 \
        --max-time 45 \
        -A 'Mozilla/5.0 sdr2hdr-virgin-validation/1.0' \
        "$nested" -o "$tmp"
      then
        if grep -qi '<MPD' "$tmp"; then
          printf '%s\n' "$nested" >"$resolved_url_file"
          cp "$tmp" "$mpd_out"
          return 0
        fi
      fi
    done <"$WORK/${role}.nested-mpd-urls.txt"

  done <"$WORK/${role}.service-urls.txt"

  return 1
}

SDR_URL_FILE="$WORK/sdr.mpd.url"
HDR_URL_FILE="$WORK/hdr.mpd.url"

resolve_service_mpd \
  "sdr" "$SERVICE_LIST_EVIDENCE" "$SDR_URL_FILE" "$SDR_MPD_FILE" || \
  die "could not resolve an official MPD for $SDR_SERVICE from DVB-I XML"

resolve_service_mpd \
  "hdr" "$SERVICE_LIST_EVIDENCE" "$HDR_URL_FILE" "$HDR_MPD_FILE" || \
  die "could not resolve an official MPD for $HDR_SERVICE from DVB-I XML"

SDR_MPD_URL="$(cat "$SDR_URL_FILE")"
HDR_MPD_URL="$(cat "$HDR_URL_FILE")"

python3 - \
  "$SDR_MPD_URL" "$HDR_MPD_URL" \
  "$SDR_MPD_FILE" "$HDR_MPD_FILE" \
  "$SERVICE_LIST_EVIDENCE" "$RESOLVE_JSON" <<'PY'
import hashlib
import json
import sys

su, hu, sp, hp, service_p, outp = sys.argv[1:]
services = json.load(open(service_p, encoding="utf-8"))

def sha(path):
    return hashlib.sha256(open(path, "rb").read()).hexdigest()

errors = []
if su == hu:
    errors.append("SDR and HDR resolved to the same MPD URL")

result = {
    "resolver": "official DVB-I service-list delivery URI",
    "sdr_mpd_url": su,
    "hdr_mpd_url": hu,
    "sdr_mpd_sha256": sha(sp),
    "hdr_mpd_sha256": sha(hp),
    "service_list_sha256": services["service_list_sha256"],
    "errors": errors,
}

with open(outp, "w", encoding="utf-8") as f:
    json.dump(result, f, ensure_ascii=False, indent=2)
    f.write("\n")

print(json.dumps(result, ensure_ascii=False, indent=2))

if errors:
    raise SystemExit(1)
PY

ok "official SDR/HLG MPDs resolved from DVB-I service registry"

###############################################################################
# 4) DIRECT DASH SEGMENT CAPTURE (NO FFMPEG DASH DEMUXER REQUIRED)
###############################################################################

say "capturing synchronized HEVC DASH segments directly from both DVB MPDs"

DASH_CAPTURE_SCRIPT="$WORK/direct_dash_capture.py"
DASH_CAPTURE_EVIDENCE="$META/direct-dash-capture.json"

cat >"$DASH_CAPTURE_SCRIPT" <<'PY'
#!/usr/bin/env python3
import concurrent.futures
import datetime as dt
import email.utils
import hashlib
import json
import math
import os
import re
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET

(
    sdr_mpd,
    hdr_mpd,
    capture_seconds_s,
    min_contiguous_segments_s,
    sdr_out,
    hdr_out,
    work_root,
    evidence_out,
) = sys.argv[1:]

CAPTURE_SECONDS = float(capture_seconds_s)
MIN_CONTIGUOUS_SEGMENTS = int(min_contiguous_segments_s)
POLL_SECONDS = 1.0
USER_AGENT = "Mozilla/5.0 sdr2hdr-virgin-validation/1.0"

class FetchError(RuntimeError):
    def __init__(self, message, http_status=None):
        super().__init__(message)
        self.code = http_status

def localname(tag):
    return tag.rsplit("}", 1)[-1] if "}" in tag else tag

def children(el, name):
    return [c for c in list(el) if localname(c.tag) == name]

def child(el, name):
    xs = children(el, name)
    return xs[0] if xs else None

def fetch(url, timeout=30, attempts=4):
    last = None
    for attempt in range(attempts):
        try:
            req = urllib.request.Request(
                url,
                headers={
                    "User-Agent": USER_AGENT,
                    "Accept": "*/*",
                    "Cache-Control": "no-cache",
                },
            )
            with urllib.request.urlopen(req, timeout=timeout) as r:
                return r.read(), {
                    "status": getattr(r, "status", 200),
                    "content_type": r.headers.get("Content-Type"),
                    "content_length": r.headers.get("Content-Length"),
                    "etag": r.headers.get("ETag"),
                    "last_modified": r.headers.get("Last-Modified"),
                    "date": r.headers.get("Date"),
                }
        except urllib.error.HTTPError as exc:
            last = exc
            # These statuses are normal evidence while probing a dynamic
            # time-shift window. Retrying the same address cannot change its
            # state quickly enough to help this poll.
            if exc.code in (404, 410, 425):
                raise FetchError(
                    "fetch failed %s: %r" % (url, exc),
                    http_status=exc.code,
                ) from exc
            if attempt + 1 < attempts:
                time.sleep(0.35 * (attempt + 1))
        except Exception as exc:
            last = exc
            if attempt + 1 < attempts:
                time.sleep(0.35 * (attempt + 1))
    raise FetchError(
        "fetch failed %s: %r" % (url, last),
        http_status=getattr(last, "code", None),
    ) from last

def parse_iso_duration(value):
    if not value:
        return None
    m = re.fullmatch(
        r"P(?:(?P<d>[0-9.]+)D)?"
        r"(?:T(?:(?P<h>[0-9.]+)H)?"
        r"(?:(?P<m>[0-9.]+)M)?"
        r"(?:(?P<s>[0-9.]+)S)?)?",
        value,
    )
    if not m:
        return None
    parts = {
        k: float(v) if v else 0.0
        for k, v in m.groupdict().items()
    }
    return (
        parts["d"] * 86400
        + parts["h"] * 3600
        + parts["m"] * 60
        + parts["s"]
    )

def parse_xs_datetime(value):
    if not value:
        return None

    value = value.strip()

    if value.endswith("Z"):
        value = value[:-1] + "+00:00"

    try:
        parsed = dt.datetime.fromisoformat(value)
    except Exception:
        return None

    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=dt.timezone.utc)

    return parsed.astimezone(dt.timezone.utc).timestamp()

def parse_http_datetime(value):
    if not value:
        return None

    try:
        parsed = email.utils.parsedate_to_datetime(value)
    except Exception:
        return None

    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=dt.timezone.utc)

    return parsed.astimezone(dt.timezone.utc).timestamp()

def text_base(el):
    b = child(el, "BaseURL")
    if b is None or not b.text:
        return None
    return b.text.strip()

def apply_base(parent_url, *elements):
    base = parent_url.rsplit("/", 1)[0] + "/"
    for el in elements:
        if el is None:
            continue
        value = text_base(el)
        if value:
            base = urllib.parse.urljoin(base, value)
    return base

def adaptation_is_video(ad):
    attrs = {k.lower(): v for k, v in ad.attrib.items()}
    if attrs.get("contenttype", "").lower() == "video":
        return True
    if attrs.get("mimetype", "").lower().startswith("video/"):
        return True

    for rep in children(ad, "Representation"):
        a = {k.lower(): v for k, v in rep.attrib.items()}
        if a.get("mimetype", "").lower().startswith("video/"):
            return True
        codecs = a.get("codecs", "").lower()
        if any(x in codecs for x in ("hvc1", "hev1")):
            return True
    return False

def choose_representation(root):
    periods = [x for x in root if localname(x.tag) == "Period"]
    if not periods:
        raise RuntimeError("MPD has no Period")

    candidates = []

    for pindex, period in enumerate(periods):
        for ad in children(period, "AdaptationSet"):
            if not adaptation_is_video(ad):
                continue

            for rep in children(ad, "Representation"):
                attrs = {}
                attrs.update(ad.attrib)
                attrs.update(rep.attrib)

                codecs = attrs.get("codecs", "").lower()
                mime = attrs.get("mimeType", attrs.get("mimetype", "")).lower()

                if not (
                    "hvc1" in codecs
                    or "hev1" in codecs
                    or mime.startswith("video/")
                ):
                    continue

                width = int(attrs.get("width", 0) or 0)
                height = int(attrs.get("height", 0) or 0)
                bandwidth = int(attrs.get("bandwidth", 0) or 0)
                score = width * height * 1000000000 + bandwidth

                candidates.append(
                    (score, pindex, period, ad, rep, attrs)
                )

    if not candidates:
        raise RuntimeError("MPD has no HEVC/video Representation")

    candidates.sort(key=lambda x: x[0], reverse=True)
    return candidates[0][1:]

def merge_segment_template(ad, rep):
    ad_st = child(ad, "SegmentTemplate")
    rep_st = child(rep, "SegmentTemplate")

    if ad_st is None and rep_st is None:
        raise RuntimeError("video Representation has no SegmentTemplate")

    attrs = {}
    if ad_st is not None:
        attrs.update(ad_st.attrib)
    if rep_st is not None:
        attrs.update(rep_st.attrib)

    timeline = None
    if rep_st is not None:
        timeline = child(rep_st, "SegmentTimeline")
    if timeline is None and ad_st is not None:
        timeline = child(ad_st, "SegmentTimeline")

    return attrs, timeline

def template_expand(template, rep_id, bandwidth, number=None, time_value=None):
    if template is None:
        return None

    sentinel = "\x00DOLLAR\x00"
    value = template.replace("$$", sentinel)

    def repl(match):
        key = match.group(1)
        fmt = match.group(2)

        if key == "RepresentationID":
            raw = str(rep_id)
        elif key == "Bandwidth":
            raw = str(bandwidth)
        elif key == "Number":
            if number is None:
                raise RuntimeError("template requires $Number$ but none supplied")
            raw = str(number)
        elif key == "Time":
            if time_value is None:
                raise RuntimeError("template requires $Time$ but none supplied")
            raw = str(time_value)
        else:
            raise RuntimeError("unsupported DASH template token: %s" % key)

        if fmt:
            width_m = re.fullmatch(r"%0([0-9]+)d", fmt)
            if not width_m:
                raise RuntimeError("unsupported DASH numeric format: %s" % fmt)
            raw = ("%0" + width_m.group(1) + "d") % int(raw)

        return raw

    value = re.sub(
        r"\$(RepresentationID|Bandwidth|Number|Time)(%0[0-9]+d)?\$",
        repl,
        value,
    )
    return value.replace(sentinel, "$")

def timeline_entries(timeline, start_number):
    ss = children(timeline, "S")
    if not ss:
        return []

    out = []
    current = None
    number = int(start_number)

    for idx, s in enumerate(ss):
        d = int(s.attrib["d"])
        if "t" in s.attrib:
            current = int(s.attrib["t"])
        elif current is None:
            current = 0

        r = int(s.attrib.get("r", "0"))

        if r < 0:
            # Repeat until the explicit time of the next S element.
            next_t = None
            for later in ss[idx + 1:]:
                if "t" in later.attrib:
                    next_t = int(later.attrib["t"])
                    break
            if next_t is None:
                # For a dynamic MPD without a following explicit t, the MPD
                # snapshot's timeShiftBufferDepth bounds the useful window.
                # A conservative single element is safer than inventing
                # unavailable future segments.
                r = 0
            else:
                r = max(0, int((next_t - current) // d) - 1)

        for _ in range(r + 1):
            out.append({
                "number": number,
                "time": current,
                "duration": d,
            })
            number += 1
            current += d

    return out

def enumerate_segments(root, mpd_url, response_time=None):
    (
        period_index,
        period,
        ad,
        rep,
        attrs,
    ) = choose_representation(root)

    st, timeline = merge_segment_template(ad, rep)

    media = st.get("media")
    initialization = st.get("initialization")

    if not media or not initialization:
        raise RuntimeError(
            "SegmentTemplate must expose media and initialization"
        )

    rep_id = rep.attrib.get("id")
    if rep_id is None:
        raise RuntimeError("selected Representation has no id")

    bandwidth = int(
        rep.attrib.get(
            "bandwidth",
            ad.attrib.get("bandwidth", "0"),
        )
        or 0
    )

    start_number = int(st.get("startNumber", "1"))
    timescale = int(st.get("timescale", "1"))

    base = apply_base(mpd_url, root, period, ad, rep)

    init_rel = template_expand(
        initialization,
        rep_id,
        bandwidth,
    )
    init_url = urllib.parse.urljoin(base, init_rel)

    entries = []

    live_number_evidence = None

    if timeline is not None:
        entries = timeline_entries(timeline, start_number)
        for item in entries:
            item["number_strategy"] = "segment_timeline"
    else:
        duration_units = int(st.get("duration", "0") or 0)
        if duration_units <= 0:
            raise RuntimeError(
                "SegmentTemplate has neither SegmentTimeline nor duration"
            )

        seg_seconds = duration_units / float(timescale)
        tsbd = parse_iso_duration(root.attrib.get("timeShiftBufferDepth"))
        if tsbd is None:
            tsbd = 30.0

        ast = parse_xs_datetime(root.attrib.get("availabilityStartTime"))
        publish = parse_xs_datetime(root.attrib.get("publishTime"))

        period_start = parse_iso_duration(period.attrib.get("start")) or 0.0

        if ast is None:
            raise RuntimeError(
                "dynamic duration-based MPD has no parseable "
                "availabilityStartTime"
            )

        # Livesim2's start_<epoch> URLs keep MPD@publishTime and
        # SegmentTemplate@startNumber fixed at the presentation origin. The
        # media window nevertheless advances against the server clock. Use the
        # HTTP Date from this no-cache MPD response as the live clock; it is
        # server-authored and avoids client clock skew. MPD@publishTime remains
        # the fallback for generators that update it, with local UTC last.
        #
        # HTTP media existence is authoritative:
        #   200 -> usable live segment
        #   404/425 -> not yet available / wrong candidate
        #   410 -> outside time-shift buffer
        #
        if response_time is not None:
            live_clock = response_time
            live_clock_source = "HTTP Date"
            global_strategy = "ast_http_date_global"
        elif publish is not None and publish > ast:
            live_clock = publish
            live_clock_source = "MPD@publishTime"
            global_strategy = "ast_mpd_publish_global"
        else:
            live_clock = time.time()
            live_clock_source = "local UTC fallback"
            global_strategy = "ast_local_utc_global"

        global_elapsed = live_clock - ast
        mpd_publish_elapsed = (
            publish - ast
            if publish is not None
            else None
        )
        period_relative_elapsed = (
            global_elapsed - period_start
            if global_elapsed is not None
            else None
        )

        window_segments = max(
            8,
            int(math.ceil(tsbd / seg_seconds)) + 4,
        )
        probe_forward = 0

        end_number_raw = st.get("endNumber")
        end_number = (
            int(end_number_raw)
            if end_number_raw not in (None, "")
            else None
        )

        def apply_end_number(number):
            if end_number is None:
                return number
            return min(number, end_number)

        # Strategy 1 — server-clock live window.
        global_entries = []
        global_last_number = None
        # Keep each poll cheaper than one segment period. Probing only the two
        # newest complete numbers lets a failed side retry the prior segment
        # while the next segment is being published, instead of spending the
        # whole time-shift window downloading old media and creating gaps.
        global_probe_back = max(
            6,
            int(math.floor(tsbd / seg_seconds)),
        )

        if global_elapsed > 0:
            global_last_complete_index = (
                int(math.floor(global_elapsed / seg_seconds)) - 1
            )
            global_last_number = (
                start_number + global_last_complete_index
            )
            global_first_number = max(
                start_number,
                global_last_number - global_probe_back + 1,
            )
            global_final_number = apply_end_number(
                global_last_number + probe_forward
            )

            if global_final_number >= global_first_number:
                global_entries = [
                    {
                        "number": number,
                        "time": None,
                        "duration": duration_units,
                        "number_strategy": global_strategy,
                    }
                    for number in range(
                        global_first_number,
                        global_final_number + 1,
                    )
                ]

        # Strategy 2 — MPD startNumber fallback. Some DASH generators advance
        # startNumber to the first segment in the advertised live window.
        direct_first_number = start_number
        direct_last_number = apply_end_number(
            start_number + window_segments + probe_forward
        )

        direct_entries = [
            {
                "number": number,
                "time": None,
                "duration": duration_units,
                "number_strategy": "mpd_start_number_window",
            }
            for number in range(
                direct_first_number,
                direct_last_number + 1,
            )
        ]

        # Keep strategy identity even for overlapping numbers. poll_once()
        # probes one strategy at a time and locks onto the first strategy that
        # produces actual media HTTP responses.
        entries = list(global_entries)
        entries.extend(direct_entries)

        live_number_evidence = {
            "availability_start_time": root.attrib.get(
                "availabilityStartTime"
            ),
            "publish_time": root.attrib.get("publishTime"),
            "mpd_publish_elapsed_seconds": mpd_publish_elapsed,
            "live_clock_utc": dt.datetime.fromtimestamp(
                live_clock,
                tz=dt.timezone.utc,
            ).isoformat(),
            "live_clock_source": live_clock_source,
            "period_start_seconds": period_start,
            "global_elapsed_seconds": global_elapsed,
            "period_relative_elapsed_seconds":
                period_relative_elapsed,
            "segment_duration_seconds": seg_seconds,
            "start_number": start_number,
            "preferred_strategy": global_strategy,
            "preferred_last_complete_number":
                global_last_number,
            "fallback_strategy": "mpd_start_number_window",
            "fallback_first_number": direct_first_number,
            "fallback_last_number": direct_last_number,
            "time_shift_buffer_depth_seconds": tsbd,
            "window_segments": window_segments,
            "probe_back_segments": global_probe_back,
            "probe_forward_segments": probe_forward,
            "mpd_publish_time_is_static_at_ast": (
                mpd_publish_elapsed is not None
                and abs(mpd_publish_elapsed) < 0.001
            ),
            "period_start_cancels_global_elapsed": (
                period_relative_elapsed is not None
                and abs(period_relative_elapsed) <
                    max(0.001, seg_seconds * 0.25)
            ),
        }

    segments = []
    for item in entries:
        rel = template_expand(
            media,
            rep_id,
            bandwidth,
            number=item["number"],
            time_value=item["time"],
        )
        segments.append({
            **item,
            "number_strategy": item.get(
                "number_strategy",
                "segment_timeline",
            ),
            "url": urllib.parse.urljoin(base, rel),
        })

    info = {
        "representation_id": rep_id,
        "bandwidth": bandwidth,
        "width": int(attrs.get("width", 0) or 0),
        "height": int(attrs.get("height", 0) or 0),
        "codecs": attrs.get("codecs"),
        "mimeType": attrs.get("mimeType", attrs.get("mimetype")),
        "period_index": period_index,
        "timescale": timescale,
        "start_number": start_number,
        "addressing": (
            "SegmentTimeline"
            if timeline is not None
            else "SegmentTemplateDuration"
        ),
        "base_url": base,
        "initialization_url": init_url,
        "live_number_evidence": live_number_evidence,
        "segment_template_raw": dict(st),
        "period_raw": dict(period.attrib),
        "mpd_raw": {
            key: root.attrib.get(key)
            for key in (
                "type",
                "availabilityStartTime",
                "publishTime",
                "minimumUpdatePeriod",
                "timeShiftBufferDepth",
                "suggestedPresentationDelay",
            )
        },
    }

    return info, segments

def segment_sort_key(seg):
    if seg["time"] is not None:
        return (0, int(seg["time"]), int(seg["number"]))
    return (1, int(seg["number"]), 0)

def segment_identity(seg):
    if seg["time"] is not None:
        return "t:%s" % seg["time"]
    return "n:%s" % seg["number"]

def split_contiguous_runs(numbers):
    ordered = sorted(set(int(number) for number in numbers))
    if not ordered:
        return []

    runs = [[ordered[0]]]
    for number in ordered[1:]:
        if number == runs[-1][-1] + 1:
            runs[-1].append(number)
        else:
            runs.append([number])
    return runs

class RoleCapture:
    def __init__(self, role, mpd_url, output_path, work_dir):
        self.role = role
        self.mpd_url = mpd_url
        self.output_path = output_path
        self.work_dir = work_dir
        self.fragments_dir = os.path.join(work_dir, role + "-fragments")
        os.makedirs(self.fragments_dir, exist_ok=True)

        self.init_bytes = None
        self.init_url = None
        self.init_sha = None
        self.rep_info = None
        self.downloaded = {}
        self.failed_attempts = {}
        self.active_number_strategy = None
        self.strategy_successes = {}
        self.mpd_snapshots = 0
        self.first_segment_key = None
        self.last_segment_key = None
        self.errors = []

    def download_segment(self, seg):
        key_core = segment_identity(seg)
        key = "%s|%s" % (
            seg.get("number_strategy", "unknown"),
            key_core,
        )

        if key in self.downloaded:
            return False

        try:
            blob, headers = fetch(
                seg["url"],
                timeout=30,
                attempts=2,
            )
        except Exception as exc:
            status = getattr(exc, "code", None)
            record = self.failed_attempts.get(
                key,
                {
                    "attempts": 0,
                    "last_error": None,
                    "last_http_status": None,
                    "url": seg["url"],
                },
            )
            record["attempts"] += 1
            record["last_error"] = repr(exc)
            record["last_http_status"] = status
            self.failed_attempts[key] = record

            # 404/410/425 around the live edge are expected probe evidence.
            # Other statuses remain visible in diagnostics.
            return False

        if len(blob) < 64:
            self.failed_attempts[key] = (
                self.failed_attempts.get(key, 0) + 1
            )
            return False

        path = os.path.join(
            self.fragments_dir,
            "%08d.m4s" % len(self.downloaded),
        )
        with open(path, "wb") as f:
            f.write(blob)

        self.downloaded[key] = {
            **seg,
            "key": key,
            "path": path,
            "bytes": len(blob),
            "sha256": hashlib.sha256(blob).hexdigest(),
            "headers": headers,
        }

        strategy = seg.get(
            "number_strategy",
            "unknown",
        )
        self.strategy_successes[strategy] = (
            self.strategy_successes.get(strategy, 0) + 1
        )

        if self.first_segment_key is None:
            self.first_segment_key = key
        self.last_segment_key = key

        return True

    def poll_once(self, initial=False):
        mpd_blob, mpd_headers = fetch(self.mpd_url)
        self.mpd_snapshots += 1

        try:
            root = ET.fromstring(mpd_blob)
        except Exception as exc:
            raise RuntimeError(
                "%s MPD XML parse failed: %r" % (self.role, exc)
            )

        response_time = parse_http_datetime(mpd_headers.get("date"))
        info, segments = enumerate_segments(
            root,
            self.mpd_url,
            response_time=response_time,
        )
        if not segments:
            raise RuntimeError(
                "%s MPD exposed no video segments" % self.role
            )

        if self.rep_info is None:
            self.rep_info = info
            self.init_url = info["initialization_url"]
            self.init_bytes, init_headers = fetch(self.init_url)
            self.init_sha = hashlib.sha256(self.init_bytes).hexdigest()
            self.init_headers = init_headers
        else:
            # Do not silently switch representation while capturing.
            for field in ("representation_id", "width", "height", "codecs"):
                if info.get(field) != self.rep_info.get(field):
                    raise RuntimeError(
                        "%s representation changed mid-capture: %s %r -> %r"
                        % (
                            self.role,
                            field,
                            self.rep_info.get(field),
                            info.get(field),
                        )
                    )

        # Preserve enumerate_segments strategy order:
        #   1) availabilityStartTime + server-authored live clock
        #   2) MPD startNumber window
        # Once one strategy yields actual HTTP media, lock to it.
        strategies = []
        for seg in segments:
            strategy = seg.get(
                "number_strategy",
                "unknown",
            )
            if strategy not in strategies:
                strategies.append(strategy)

        new_count = 0
        attempted_strategies = []
        target_segment_identity = None

        if self.active_number_strategy is not None:
            candidates = [
                seg
                for seg in segments
                if seg.get("number_strategy") ==
                   self.active_number_strategy
            ]
            attempted_strategies.append(
                self.active_number_strategy
            )

            # After bootstrap, request exactly the next number. This prevents
            # a slow poll from jumping to a newer live-window snapshot and
            # leaving a permanent gap. The wider enumerated window exists only
            # so this one target remains retryable inside the TSBD.
            downloaded_for_strategy = [
                seg
                for seg in self.downloaded.values()
                if seg.get("number_strategy") ==
                   self.active_number_strategy
            ]
            if (
                downloaded_for_strategy
                and all(seg["time"] is None for seg in candidates)
            ):
                next_number = max(
                    int(seg["number"])
                    for seg in downloaded_for_strategy
                ) + 1
                target_segment_identity = "n:%d" % next_number
                candidates = [
                    seg
                    for seg in candidates
                    if int(seg["number"]) == next_number
                ]
            else:
                candidates = sorted(
                    candidates,
                    key=segment_sort_key,
                )[-1:]

            for seg in candidates:
                if self.download_segment(seg):
                    new_count += 1
        else:
            for strategy in strategies:
                attempted_strategies.append(strategy)
                strategy_new = 0

                candidates = [
                    seg
                    for seg in segments
                    if seg.get("number_strategy") == strategy
                ]

                # Bootstrap with one newest complete segment. Subsequent polls
                # advance strictly by one number from that anchor.
                candidates = sorted(
                    candidates,
                    key=segment_sort_key,
                )[-1:]
                if candidates:
                    target_segment_identity = segment_identity(candidates[0])

                for seg in candidates:
                    if self.download_segment(seg):
                        strategy_new += 1
                        new_count += 1

                if strategy_new > 0:
                    self.active_number_strategy = strategy
                    break

        return {
            "mpd_sha256": hashlib.sha256(mpd_blob).hexdigest(),
            "mpd_headers": mpd_headers,
            "available_segments": len(segments),
            "new_segments": new_count,
            "attempted_number_strategies":
                attempted_strategies,
            "active_number_strategy":
                self.active_number_strategy,
            "target_segment_identity": target_segment_identity,
        }

    def finalize(self, paired_identities=None):
        if self.init_bytes is None:
            raise RuntimeError("%s never downloaded initialization segment" % self.role)

        selected = list(self.downloaded.values())
        if paired_identities is not None:
            selected = [
                seg
                for seg in selected
                if segment_identity(seg) in paired_identities
            ]

        if len(selected) < 5:
            diagnostic = {
                "role": self.role,
                "captured_media_segments_before_pair_intersection":
                    len(self.downloaded),
                "paired_media_segments": len(selected),
                "representation": self.rep_info,
                "failed_attempts": self.failed_attempts,
                "active_number_strategy":
                    self.active_number_strategy,
                "strategy_successes":
                    self.strategy_successes,
                "mpd_snapshots": self.mpd_snapshots,
            }
            raise RuntimeError(
                "%s captured only %d media segments; diagnostics=%s"
                % (
                    self.role,
                    len(selected),
                    json.dumps(
                        diagnostic,
                        ensure_ascii=False,
                        sort_keys=True,
                    ),
                )
            )

        ordered = sorted(
            selected,
            key=segment_sort_key,
        )

        source_timestamps_path = self.output_path + ".source-timestamps.mp4"
        normalized_tmp_path = self.output_path + ".normalizing.mp4"

        with open(source_timestamps_path, "wb") as out:
            out.write(self.init_bytes)
            for seg in ordered:
                out.write(open(seg["path"], "rb").read())

        try:
            os.unlink(normalized_tmp_path)
        except FileNotFoundError:
            pass

        remux = subprocess.run(
            [
                "ffmpeg",
                "-hide_banner",
                "-nostdin",
                "-y",
                "-v",
                "error",
                "-xerror",
                "-copyts",
                "-start_at_zero",
                "-i",
                source_timestamps_path,
                "-map",
                "0:v:0",
                "-an",
                "-sn",
                "-dn",
                "-c",
                "copy",
                "-movflags",
                "+faststart",
                normalized_tmp_path,
            ],
            capture_output=True,
            text=True,
        )
        if remux.returncode != 0:
            raise RuntimeError(
                "%s timestamp-normalizing stream copy failed: %s"
                % (self.role, remux.stderr[-4000:])
            )

        os.replace(normalized_tmp_path, self.output_path)
        os.unlink(source_timestamps_path)

        probe = json.loads(subprocess.check_output([
            "ffprobe",
            "-v",
            "error",
            "-select_streams",
            "v:0",
            "-show_entries",
            "stream=start_time,r_frame_rate,avg_frame_rate",
            "-of",
            "json",
            self.output_path,
        ]))["streams"][0]
        normalized_start_time = float(probe.get("start_time", "nan"))
        if (
            not math.isfinite(normalized_start_time)
            or abs(normalized_start_time) > 0.001
        ):
            raise RuntimeError(
                "%s timestamp normalization start_time=%r expected 0"
                % (self.role, probe.get("start_time"))
            )

        output_sha = hashlib.sha256(
            open(self.output_path, "rb").read()
        ).hexdigest()

        return {
            "role": self.role,
            "mpd_url": self.mpd_url,
            "mpd_snapshots": self.mpd_snapshots,
            "representation": self.rep_info,
            "initialization_url": self.init_url,
            "initialization_sha256": self.init_sha,
            "captured_media_segment_count_before_pair_intersection":
                len(self.downloaded),
            "media_segment_count": len(ordered),
            "media_total_bytes": sum(x["bytes"] for x in ordered),
            "segment_identities": [
                segment_identity(seg)
                for seg in ordered
            ],
            "first_segment": {
                k: ordered[0].get(k)
                for k in ("key", "number", "time", "duration", "url")
            },
            "last_segment": {
                k: ordered[-1].get(k)
                for k in ("key", "number", "time", "duration", "url")
            },
            "active_number_strategy":
                self.active_number_strategy,
            "strategy_successes":
                self.strategy_successes,
            "failed_live_edge_attempts":
                self.failed_attempts,
            "output_path": os.path.abspath(self.output_path),
            "output_bytes": os.path.getsize(self.output_path),
            "output_sha256": output_sha,
            "timestamp_normalization": {
                "method": (
                    "FFmpeg stream copy with -copyts -start_at_zero; "
                    "encoded media packets are not re-encoded"
                ),
                "start_time_seconds": normalized_start_time,
                "r_frame_rate": probe.get("r_frame_rate"),
                "avg_frame_rate": probe.get("avg_frame_rate"),
            },
        }

def capture_pair():
    os.makedirs(work_root, exist_ok=True)

    sdr = RoleCapture(
        "sdr",
        sdr_mpd,
        sdr_out,
        os.path.join(work_root, "direct-dash"),
    )
    hdr = RoleCapture(
        "hdr",
        hdr_mpd,
        hdr_out,
        os.path.join(work_root, "direct-dash"),
    )

    roles = [sdr, hdr]
    started = time.monotonic()

    poll_log = []

    with concurrent.futures.ThreadPoolExecutor(max_workers=2) as ex:
        initial_futures = {
            ex.submit(role.poll_once, True): role
            for role in roles
        }
        for future, role in [
            (f, initial_futures[f])
            for f in initial_futures
        ]:
            poll_log.append({
                "role": role.role,
                "elapsed": time.monotonic() - started,
                **future.result(),
            })

        # MPD/init/bootstrap latency is not usable captured duration. Start the
        # requested live collection window only after both roles have anchored
        # their first media segment.
        capture_window_started = time.monotonic()
        bootstrap_seconds = capture_window_started - started
        deadline = capture_window_started + CAPTURE_SECONDS

        while time.monotonic() < deadline:
            loop_started = time.monotonic()

            futures = {
                ex.submit(role.poll_once, False): role
                for role in roles
            }

            for future, role in [
                (f, futures[f])
                for f in futures
            ]:
                poll_log.append({
                    "role": role.role,
                    "elapsed": time.monotonic() - started,
                    **future.result(),
                })

            remaining = POLL_SECONDS - (time.monotonic() - loop_started)
            if remaining > 0:
                time.sleep(remaining)

        # One final snapshot catches the segment published near the deadline.
        futures = {
            ex.submit(role.poll_once, False): role
            for role in roles
        }
        for future, role in [
            (f, futures[f])
            for f in futures
        ]:
            poll_log.append({
                "role": role.role,
                "elapsed": time.monotonic() - started,
                **future.result(),
            })

    capture_method = (
        "direct Python DASH SegmentTemplate $Number$ downloader; "
        "paired longest-contiguous-common-run selection; FFmpeg DASH "
        "demuxer not required"
    )

    if (
        sdr.rep_info.get("addressing") != "SegmentTemplateDuration"
        or hdr.rep_info.get("addressing") != "SegmentTemplateDuration"
    ):
        raise RuntimeError(
            "contiguous temporal capture requires duration-based "
            "SegmentTemplate $Number$ addressing"
        )

    sdr_numbers = {
        int(seg["number"])
        for seg in sdr.downloaded.values()
        if seg["time"] is None
    }
    hdr_numbers = {
        int(seg["number"])
        for seg in hdr.downloaded.values()
        if seg["time"] is None
    }
    common_numbers = sorted(sdr_numbers & hdr_numbers)
    common_runs = split_contiguous_runs(common_numbers)
    run_summaries = [
        {
            "start_segment": run[0],
            "end_segment": run[-1],
            "segment_count": len(run),
        }
        for run in common_runs
    ]
    selected_run = (
        max(common_runs, key=lambda run: (len(run), run[-1]))
        if common_runs
        else []
    )

    sdr_duration_units = int(
        sdr.rep_info["segment_template_raw"]["duration"]
    )
    hdr_duration_units = int(
        hdr.rep_info["segment_template_raw"]["duration"]
    )
    if (
        sdr_duration_units != hdr_duration_units
        or int(sdr.rep_info["timescale"]) !=
           int(hdr.rep_info["timescale"])
    ):
        raise RuntimeError(
            "SDR/HDR SegmentTemplate duration or timescale differs"
        )
    segment_duration_seconds = (
        sdr_duration_units / float(sdr.rep_info["timescale"])
    )

    if len(selected_run) < MIN_CONTIGUOUS_SEGMENTS:
        failure = {
            "capture_method": capture_method,
            "status": "FAIL_CONTIGUOUS_COMMON_RUN_TOO_SHORT",
            "capture_seconds_requested": CAPTURE_SECONDS,
            "bootstrap_seconds_excluded_from_capture_window":
                bootstrap_seconds,
            "minimum_contiguous_segments": MIN_CONTIGUOUS_SEGMENTS,
            "segment_duration_seconds": segment_duration_seconds,
            "common_segment_numbers": common_numbers,
            "contiguous_runs": run_summaries,
            "longest_contiguous_segment_count": len(selected_run),
            "existing_validated_assets_and_manifest_preserved": True,
            "errors": [
                "longest contiguous common run has %d segments; minimum=%d"
                % (len(selected_run), MIN_CONTIGUOUS_SEGMENTS)
            ],
            "polls": poll_log,
        }
        with open(evidence_out, "w", encoding="utf-8") as f:
            json.dump(failure, f, ensure_ascii=False, indent=2)
            f.write("\n")
        raise RuntimeError(
            "contiguous common DASH run too short after %.3fs: "
            "longest=%d segments (%.2fs), required=%d segments (%.2fs); "
            "existing PAIR_VALID_VIRGIN manifest/assets were not modified; "
            "runs=%s"
            % (
                CAPTURE_SECONDS,
                len(selected_run),
                len(selected_run) * segment_duration_seconds,
                MIN_CONTIGUOUS_SEGMENTS,
                MIN_CONTIGUOUS_SEGMENTS * segment_duration_seconds,
                json.dumps(run_summaries, sort_keys=True),
            )
        )

    paired_identities = {"n:%d" % number for number in selected_run}
    paired_identity_order = ["n:%d" % number for number in selected_run]

    sdr_result = sdr.finalize(paired_identities)
    hdr_result = hdr.finalize(paired_identities)

    errors = []

    # The paired services should expose matching segment-addressing families.
    if (
        sdr_result["representation"]["addressing"]
        != hdr_result["representation"]["addressing"]
    ):
        errors.append(
            "SDR/HDR DASH addressing differs: %r vs %r"
            % (
                sdr_result["representation"]["addressing"],
                hdr_result["representation"]["addressing"],
            )
        )

    if sdr_result["segment_identities"] != hdr_result["segment_identities"]:
        errors.append("SDR/HDR selected segment identity arrays differ")
    if sdr_result["segment_identities"] != paired_identity_order:
        errors.append("final selected segment identities differ from run")
    if len(selected_run) < MIN_CONTIGUOUS_SEGMENTS:
        errors.append("selected contiguous run is below required minimum")

    contiguous_run = {
        "start_segment": selected_run[0],
        "end_segment": selected_run[-1],
        "segment_count": len(selected_run),
        "duration_seconds": (
            len(selected_run) * segment_duration_seconds
        ),
        "segment_duration_seconds": segment_duration_seconds,
        "no_gaps": True,
        "segment_identities": paired_identity_order,
    }

    result = {
        "capture_method": capture_method,
        "capture_seconds_requested": CAPTURE_SECONDS,
        "bootstrap_seconds_excluded_from_capture_window":
            bootstrap_seconds,
        "minimum_contiguous_segments": MIN_CONTIGUOUS_SEGMENTS,
        "contiguous_run": contiguous_run,
        "pair_intersection": {
            "identity": "SegmentTemplate number",
            "common_segment_count": len(common_numbers),
            "common_segment_identities": [
                "n:%d" % number
                for number in common_numbers
            ],
            "contiguous_runs": run_summaries,
            "selected_run_identities": paired_identity_order,
            "sdr_segments_before_intersection": len(sdr_numbers),
            "hdr_segments_before_intersection": len(hdr_numbers),
            "sdr_segments_dropped": (
                len(sdr_numbers) - len(selected_run)
            ),
            "hdr_segments_dropped": (
                len(hdr_numbers) - len(selected_run)
            ),
        },
        "sdr": sdr_result,
        "hdr": hdr_result,
        "polls": poll_log,
        "errors": errors,
    }

    with open(evidence_out, "w", encoding="utf-8") as f:
        json.dump(result, f, ensure_ascii=False, indent=2)
        f.write("\n")

    print(json.dumps({
        "capture_method": result["capture_method"],
        "contiguous_run": contiguous_run,
        "sdr": {
            "representation": sdr_result["representation"],
            "segments": sdr_result["media_segment_count"],
            "output_bytes": sdr_result["output_bytes"],
        },
        "hdr": {
            "representation": hdr_result["representation"],
            "segments": hdr_result["media_segment_count"],
            "output_bytes": hdr_result["output_bytes"],
        },
        "errors": errors,
    }, ensure_ascii=False, indent=2))

    if errors:
        raise SystemExit(1)

capture_pair()
PY

chmod +x "$DASH_CAPTURE_SCRIPT"

rm -f \
  "$SDR_CAPTURE" "$HDR_CAPTURE" \
  "$SDR_CAPTURE.source-timestamps.mp4" \
  "$HDR_CAPTURE.source-timestamps.mp4" \
  "$SDR_CAPTURE.normalizing.mp4" \
  "$HDR_CAPTURE.normalizing.mp4" \
  "$PENDING_MANIFEST" "$DASH_CAPTURE_EVIDENCE"

python3 "$DASH_CAPTURE_SCRIPT" \
  "$SDR_MPD_URL" "$HDR_MPD_URL" \
  "$CAPTURE_SECONDS" "$MIN_CONTIGUOUS_SEGMENTS" \
  "$SDR_CAPTURE" "$HDR_CAPTURE" \
  "$WORK" "$DASH_CAPTURE_EVIDENCE"

[ -s "$SDR_CAPTURE" ] || die "direct SDR DASH capture is empty"
[ -s "$HDR_CAPTURE" ] || die "direct HLG DASH capture is empty"

ok "direct synchronized SDR/HLG live-edge DASH capture completed"

###############################################################################
# 5) EXACT-COPY / NAME-CHANGE DUPLICATE GUARD
###############################################################################

say "checking existing local videos for exact copied/renamed duplicates"

python3 - \
  "$REPO/data_video" "$OUT" \
  "$SDR_CAPTURE" "$HDR_CAPTURE" \
  "$META/exact-duplicate-scan.json" <<'PY'
import hashlib
import json
import os
import sys

root, candidate_root, sdr_path, hdr_path, outp = sys.argv[1:]

def digest(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        while True:
            b = f.read(8 * 1024 * 1024)
            if not b:
                break
            h.update(b)
    return h.hexdigest()

cand = {}
for label, path in (("sdr", sdr_path), ("hdr", hdr_path)):
    cand[label] = {
        "path": os.path.abspath(path),
        "size": os.path.getsize(path),
        "sha256": digest(path),
    }

hits = []
for dp, dns, fns in os.walk(root):
    abs_dp = os.path.abspath(dp)
    if abs_dp.startswith(os.path.abspath(candidate_root)):
        dns[:] = []
        continue
    dns[:] = [d for d in dns if d not in {".work", ".git"}]

    for fn in fns:
        full = os.path.join(dp, fn)
        try:
            size = os.path.getsize(full)
        except OSError:
            continue

        for label, info in cand.items():
            if size != info["size"]:
                continue
            if digest(full) == info["sha256"]:
                hits.append({
                    "candidate": label,
                    "existing_path": os.path.abspath(full),
                })

result = {
    "candidate": cand,
    "hits": hits,
    "errors": [] if not hits else ["exact duplicate already exists outside candidate"],
}

with open(outp, "w", encoding="utf-8") as f:
    json.dump(result, f, ensure_ascii=False, indent=2)
    f.write("\n")

print(json.dumps(result, ensure_ascii=False, indent=2))

if hits:
    raise SystemExit(1)
PY

ok "no exact-copy/name-change duplicate found"

###############################################################################
# 6) HEVC / GEOMETRY / FRAME-RATE / HDR-SDR COLOUR GATE
###############################################################################

say "probing captured HEVC streams"

ffprobe -v error -select_streams v:0 \
  -show_entries \
stream=codec_name,profile,width,height,pix_fmt,r_frame_rate,avg_frame_rate,color_range,color_space,color_transfer,color_primaries,bits_per_raw_sample,start_time,duration \
  -of json "$SDR_CAPTURE" >"$META/sdr.ffprobe.json"

ffprobe -v error -select_streams v:0 \
  -show_entries \
stream=codec_name,profile,width,height,pix_fmt,r_frame_rate,avg_frame_rate,color_range,color_space,color_transfer,color_primaries,bits_per_raw_sample,start_time,duration \
  -of json "$HDR_CAPTURE" >"$META/hdr.ffprobe.json"

ffprobe -v error -skip_frame nokey -select_streams v:0 \
  -show_frames \
  -show_entries frame=color_space,color_transfer,color_primaries \
  -of json "$SDR_CAPTURE" >"$META/sdr.keyframe-vui.json"

ffprobe -v error -skip_frame nokey -select_streams v:0 \
  -show_frames \
  -show_entries frame=color_space,color_transfer,color_primaries \
  -of json "$HDR_CAPTURE" >"$META/hdr.keyframe-vui.json"

python3 - \
  "$META/sdr.ffprobe.json" "$META/hdr.ffprobe.json" \
  "$META/sdr.keyframe-vui.json" "$META/hdr.keyframe-vui.json" \
  "$PROVIDER_EVIDENCE" \
  "$META/stream-gate.json" <<'PY'
import fractions
import json
import math
import sys

sp, hp, skp, hkp, provider_p, outp = sys.argv[1:]
s = json.load(open(sp, encoding="utf-8"))["streams"][0]
h = json.load(open(hp, encoding="utf-8"))["streams"][0]
sk = json.load(open(skp, encoding="utf-8"))["frames"]
hk = json.load(open(hkp, encoding="utf-8"))["frames"]
provider = json.load(open(provider_p, encoding="utf-8"))

errors = []
warnings = []

def fps(obj):
    for key in ("avg_frame_rate", "r_frame_rate"):
        value = obj.get(key)
        if value and value not in ("0/0", "N/A"):
            try:
                return float(fractions.Fraction(value))
            except Exception:
                pass
    return 0.0

def expect(label, obj, key, expected):
    if obj.get(key) != expected:
        errors.append(
            "%s %s=%r expected=%r"
            % (label, key, obj.get(key), expected)
        )

for label, obj in (("SDR", s), ("HLG", h)):
    expect(label, obj, "codec_name", "hevc")
    expect(label, obj, "width", 3840)
    expect(label, obj, "height", 2160)
    actual_fps = fps(obj)
    if abs(actual_fps - 50.0) > 0.01:
        errors.append("%s fps=%.6f expected=50" % (label, actual_fps))
    try:
        start_time = float(obj.get("start_time"))
    except Exception:
        start_time = float("nan")
    if not math.isfinite(start_time) or abs(start_time) > 0.001:
        errors.append(
            "%s normalized start_time=%r expected 0"
            % (label, obj.get("start_time"))
        )

# Validate decoded random-access-frame VUI across every captured fragment.
# The DVB HLG init segment currently advertises a bt2020-10 nclx transfer,
# while each HEVC media fragment carries authoritative ARIB STD-B67 VUI.
def frame_vui_gate(label, frames, expected):
    if not frames:
        errors.append("%s exposed no decoded keyframe VUI" % label)
        return {"keyframe_count": 0, "values": {}}

    values = {
        key: sorted(
            {frame.get(key) for frame in frames},
            key=lambda value: repr(value),
        )
        for key in expected
    }

    for key, allowed in expected.items():
        bad = [value for value in values[key] if value not in allowed]
        if bad:
            errors.append(
                "%s decoded keyframe %s values=%r expected one of %r"
                % (label, key, values[key], sorted(allowed))
            )

    return {
        "keyframe_count": len(frames),
        "values": values,
    }

s_keyframe_vui = frame_vui_gate(
    "SDR",
    sk,
    {
        "color_primaries": {"bt709"},
        "color_transfer": {"bt709", "bt470bg"},
        "color_space": {"bt709"},
    },
)
h_keyframe_vui = frame_vui_gate(
    "HLG",
    hk,
    {
        "color_primaries": {"bt2020"},
        "color_transfer": {"arib-std-b67"},
        "color_space": {"bt2020nc", "bt2020ncl"},
    },
)

for label, stream, decoded in (
    ("SDR", s, s_keyframe_vui),
    ("HLG", h, h_keyframe_vui),
):
    for key, decoded_values in decoded["values"].items():
        stream_value = stream.get(key)
        if stream_value not in decoded_values:
            warnings.append(
                "%s stream-summary %s=%r differs from decoded "
                "keyframe VUI=%r"
                % (label, key, stream_value, decoded_values)
            )

result = {
    "authoritative": True,
    "metadata_source": (
        "ffprobe HEVC decoded keyframe VUI across every captured fragment; "
        "stream/init summary retained separately"
    ),
    "sdr": s,
    "hdr": h,
    "decoded_keyframe_vui": {
        "sdr": s_keyframe_vui,
        "hdr": h_keyframe_vui,
    },
    "sdr_fps": fps(s),
    "hdr_fps": fps(h),
    "provider_page_sha256": provider["page"]["sha256"],
    "service_list_sha256": provider["service_list"]["sha256"],
    "errors": errors,
    "warnings": warnings,
}

with open(outp, "w", encoding="utf-8") as f:
    json.dump(result, f, ensure_ascii=False, indent=2)
    f.write("\n")

print(json.dumps(result, ensure_ascii=False, indent=2))

if errors:
    for e in errors:
        print("STREAM GATE ERROR:", e, file=sys.stderr)
    raise SystemExit(1)
PY

ok "HEVC 3840x2160p50 SDR/BT.709 and HLG/BT.2020 VUI gate passed"

###############################################################################
# 7) STRICT FULL-DECODE GATE
###############################################################################

say "strictly decoding every captured SDR frame"

if ! ffmpeg -hide_banner -nostdin \
  -v error -xerror \
  -i "$SDR_CAPTURE" \
  -map 0:v:0 -an -sn -dn \
  -f null - >"$META/sdr.full-decode.log" 2>&1
then
  tail -160 "$META/sdr.full-decode.log" || true
  die "SDR full decode failed"
fi

say "strictly decoding every captured HLG frame"

if ! ffmpeg -hide_banner -nostdin \
  -v error -xerror \
  -i "$HDR_CAPTURE" \
  -map 0:v:0 -an -sn -dn \
  -f null - >"$META/hdr.full-decode.log" 2>&1
then
  tail -160 "$META/hdr.full-decode.log" || true
  die "HLG full decode failed"
fi

[ ! -s "$META/sdr.full-decode.log" ] || {
  cat "$META/sdr.full-decode.log"
  die "SDR full decode emitted errors"
}

[ ! -s "$META/hdr.full-decode.log" ] || {
  cat "$META/hdr.full-decode.log"
  die "HLG full decode emitted errors"
}

ffprobe -v error -count_frames -select_streams v:0 \
  -show_entries stream=nb_read_frames,avg_frame_rate,r_frame_rate,duration \
  -of json "$SDR_CAPTURE" >"$META/sdr.frame-count.json"

ffprobe -v error -count_frames -select_streams v:0 \
  -show_entries stream=nb_read_frames,avg_frame_rate,r_frame_rate,duration \
  -of json "$HDR_CAPTURE" >"$META/hdr.frame-count.json"

python3 - \
  "$META/sdr.frame-count.json" "$META/hdr.frame-count.json" \
  "$DASH_CAPTURE_EVIDENCE" \
  "$CAPTURE_SECONDS" "$META/full-decode-gate.json" <<'PY'
import fractions
import json
import sys

sp, hp, dash_p, capture_s, outp = sys.argv[1:]
capture = float(capture_s)
s = json.load(open(sp, encoding="utf-8"))["streams"][0]
h = json.load(open(hp, encoding="utf-8"))["streams"][0]
dash = json.load(open(dash_p, encoding="utf-8"))
run = dash["contiguous_run"]

def count(obj):
    try:
        return int(obj["nb_read_frames"])
    except Exception:
        return -1

sc = count(s)
hc = count(h)
errors = []

# Allow a few seconds for live-manifest/segment-edge startup, but require a
# substantial complete decode from both streams.
minimum = int(max(45.0, capture - 10.0) * 50)

if sc < minimum:
    errors.append("SDR decoded frames=%d minimum=%d" % (sc, minimum))
if hc < minimum:
    errors.append("HLG decoded frames=%d minimum=%d" % (hc, minimum))
if sc != hc:
    errors.append(
        "SDR/HLG decoded frame counts differ: %d vs %d" % (sc, hc)
    )

expected_frames = int(round(run["duration_seconds"] * 50.0))
if sc != expected_frames:
    errors.append(
        "decoded frames=%d expected exactly %d from contiguous run"
        % (sc, expected_frames)
    )

if dash["sdr"]["segment_identities"] != dash["hdr"]["segment_identities"]:
    errors.append("SDR/HDR segment identity arrays are not exactly equal")
if dash["sdr"]["segment_identities"] != run["segment_identities"]:
    errors.append("asset segment identities differ from contiguous-run evidence")
if not run.get("no_gaps"):
    errors.append("contiguous-run evidence does not assert no_gaps=true")
if run["segment_count"] < dash["minimum_contiguous_segments"]:
    errors.append("contiguous-run segment count is below required minimum")

def fps(obj):
    for key in ("avg_frame_rate", "r_frame_rate"):
        value = obj.get(key)
        if value and value not in ("0/0", "N/A"):
            return float(fractions.Fraction(value))
    return 0.0

for label, obj in (("SDR", s), ("HLG", h)):
    if abs(fps(obj) - 50.0) > 0.01:
        errors.append("%s decoded fps=%.6f expected=50" % (label, fps(obj)))

result = {
    "sdr_decoded_frames": sc,
    "hdr_decoded_frames": hc,
    "minimum_required_frames_each": minimum,
    "expected_frames_from_contiguous_run": expected_frames,
    "decoded_frame_counts_exactly_equal": sc == hc,
    "sdr_fps": fps(s),
    "hdr_fps": fps(h),
    "segment_identity_arrays_exactly_equal": (
        dash["sdr"]["segment_identities"] ==
        dash["hdr"]["segment_identities"]
    ),
    "contiguous_run": run,
    "capture_seconds_requested": capture,
    "errors": errors,
}

with open(outp, "w", encoding="utf-8") as f:
    json.dump(result, f, ensure_ascii=False, indent=2)
    f.write("\n")

print(json.dumps(result, ensure_ascii=False, indent=2))

if errors:
    raise SystemExit(1)
PY

ok "every captured HEVC frame decoded without error"

###############################################################################
# 8) FULL-TIMELINE 32x18 LUMA FINGERPRINT
###############################################################################

SDR_GRID="$WORK/sdr.grid32x18.gray"
HDR_GRID="$WORK/hdr.grid32x18.gray"

say "generating full-timeline 32x18 SDR luma fingerprint"

ffmpeg -hide_banner -nostdin -y \
  -v error -xerror \
  -i "$SDR_CAPTURE" \
  -map 0:v:0 -an -sn -dn \
  -vf "scale=${GRID_W}:${GRID_H}:flags=area,format=gray" \
  -fps_mode passthrough \
  -f rawvideo "$SDR_GRID"

say "generating full-timeline 32x18 HLG luma fingerprint"

ffmpeg -hide_banner -nostdin -y \
  -v error -xerror \
  -i "$HDR_CAPTURE" \
  -map 0:v:0 -an -sn -dn \
  -vf "scale=${GRID_W}:${GRID_H}:flags=area,format=gray" \
  -fps_mode passthrough \
  -f rawvideo "$HDR_GRID"

[ -s "$SDR_GRID" ] || die "SDR fingerprint is empty"
[ -s "$HDR_GRID" ] || die "HLG fingerprint is empty"

###############################################################################
# 9) SAME-CONTENT / ALIGNMENT / DRIFT GATE
###############################################################################

say "checking SDR/HLG same-content alignment over the full captured timelines"

python3 - \
  "$SDR_GRID" "$HDR_GRID" \
  "$GRID_W" "$GRID_H" \
  "$ALIGN_MAX_OFFSET_SECONDS" "$MIN_ALIGNED_SECONDS" \
  "$META/alignment.json" <<'PY'
import json
import math
import statistics
import sys

sraw, hraw, gw_s, gh_s, maxoff_sec_s, min_aligned_sec_s, outp = sys.argv[1:]

gw = int(gw_s)
gh = int(gh_s)
n = gw * gh
fps = 50
maxoff = int(round(float(maxoff_sec_s) * fps))
min_aligned_frames = int(round(float(min_aligned_sec_s) * fps))

SPATIAL_MEDIAN_MIN = 0.72
SPATIAL_P10_MIN = 0.25
TEMPORAL_MEAN_RHO_MIN = 0.94
TEMPORAL_EDGE_RHO_MIN = 0.88
TEMPORAL_STD_RHO_MIN = 0.78
MAX_DRIFT_FRAMES = 2
MIN_SPATIAL_VALID_PAIRS = 300

def read_grid(path):
    data = open(path, "rb").read()
    if len(data) % n:
        raise SystemExit(
            "grid size not divisible by frame size: %s size=%d frame=%d"
            % (path, len(data), n)
        )
    return [
        tuple(data[i:i+n])
        for i in range(0, len(data), n)
    ]

def mean_std(frame):
    m = sum(frame) / float(n)
    v = sum((x - m) ** 2 for x in frame) / float(n)
    return m, math.sqrt(v)

def edge(frame):
    total = 0.0
    count = 0
    for y in range(gh):
        row = y * gw
        for x in range(gw - 1):
            total += abs(frame[row+x+1] - frame[row+x])
            count += 1
    for y in range(gh - 1):
        row = y * gw
        row2 = (y + 1) * gw
        for x in range(gw):
            total += abs(frame[row2+x] - frame[row+x])
            count += 1
    return total / max(1, count)

def normalize(frame):
    m, sd = mean_std(frame)
    if sd < 1.0:
        return None
    return tuple((x - m) / sd for x in frame)

def corr(a, b):
    if a is None or b is None:
        return None
    return sum(x*y for x, y in zip(a, b)) / len(a)

def ranks(values):
    order = sorted(range(len(values)), key=lambda i: values[i])
    out = [0.0] * len(values)
    pos = 0
    while pos < len(order):
        end = pos + 1
        value = values[order[pos]]
        while end < len(order) and values[order[end]] == value:
            end += 1
        r = (pos + end - 1) / 2.0
        for k in range(pos, end):
            out[order[k]] = r
        pos = end
    return out

def pearson(xs, ys):
    if len(xs) != len(ys) or len(xs) < 20:
        return None
    mx = sum(xs) / len(xs)
    my = sum(ys) / len(ys)
    vx = sum((x-mx)**2 for x in xs)
    vy = sum((y-my)**2 for y in ys)
    if vx < 1e-12 or vy < 1e-12:
        return None
    cov = sum((x-mx)*(y-my) for x, y in zip(xs, ys))
    return cov / math.sqrt(vx*vy)

def spearman(xs, ys):
    if len(xs) < 20:
        return None
    return pearson(ranks(xs), ranks(ys))

def percentile(values, q):
    vals = sorted(values)
    if not vals:
        return None
    p = (len(vals)-1)*q
    lo = int(math.floor(p))
    hi = int(math.ceil(p))
    if lo == hi:
        return vals[lo]
    return vals[lo]*(hi-p) + vals[hi]*(p-lo)

s = read_grid(sraw)
h = read_grid(hraw)

s_mean = []
s_std = []
s_edge = []
h_mean = []
h_std = []
h_edge = []

for frame in s:
    m, sd = mean_std(frame)
    s_mean.append(m)
    s_std.append(sd)
    s_edge.append(edge(frame))

for frame in h:
    m, sd = mean_std(frame)
    h_mean.append(m)
    h_std.append(sd)
    h_edge.append(edge(frame))

s_norm = [normalize(x) for x in s]
h_norm = [normalize(x) for x in h]

def pairs(offset, lo=0, hi=None, stride=1):
    if hi is None:
        hi = len(s)
    out = []
    for i in range(lo, hi, stride):
        j = i + offset
        if 0 <= j < len(h) and i < len(s):
            out.append((i, j))
    return out

def score(offset, lo=0, hi=None, stride=5):
    ps = pairs(offset, lo, hi, stride)
    if len(ps) < 50:
        return None

    sm = [s_mean[i] for i,j in ps]
    hm = [h_mean[j] for i,j in ps]
    ss = [s_std[i] for i,j in ps]
    hs = [h_std[j] for i,j in ps]
    se = [s_edge[i] for i,j in ps]
    he = [h_edge[j] for i,j in ps]

    mr = spearman(sm, hm)
    sr = spearman(ss, hs)
    er = spearman(se, he)

    vals = [x for x in (mr, sr, er) if x is not None and math.isfinite(x)]
    if len(vals) < 2:
        return None

    temporal = sum(vals) / len(vals)
    return {
        "offset": offset,
        "mean_rho": mr,
        "std_rho": sr,
        "edge_rho": er,
        "temporal": temporal,
        "pair_count": len(ps),
    }

# Coarse search every 5 frames, then refine around the winner.
coarse = []
for off in range(-maxoff, maxoff + 1, 5):
    x = score(off, stride=5)
    if x:
        coarse.append(x)

if not coarse:
    raise SystemExit("no temporal alignment candidate could be computed")

coarse_best = max(
    coarse,
    key=lambda x: (
        x["temporal"],
        x["edge_rho"] if x["edge_rho"] is not None else -2,
    ),
)

refine = []
for off in range(
    max(-maxoff, coarse_best["offset"] - 8),
    min(maxoff, coarse_best["offset"] + 8) + 1,
):
    x = score(off, stride=2)
    if x:
        refine.append(x)

best = max(
    refine,
    key=lambda x: (
        x["temporal"],
        x["edge_rho"] if x["edge_rho"] is not None else -2,
    ),
)

best_off = best["offset"]
matched = pairs(best_off, stride=1)

if len(matched) < min_aligned_frames:
    raise SystemExit(
        "aligned overlap=%d frames, minimum=%d"
        % (len(matched), min_aligned_frames)
    )

# Spatial evidence on the entire overlap, sampled every 3rd frame.
spatial = []
for i, j in matched[::3]:
    c = corr(s_norm[i], h_norm[j])
    if c is not None and math.isfinite(c):
        spatial.append(c)

spatial_median = statistics.median(spatial) if spatial else None
spatial_p10 = percentile(spatial, 0.10)

# First/last ~10s independently determine offset for drift detection.
window = min(500, len(s), len(h))

def local_best(lo, hi):
    values = []
    for off in range(
        max(-maxoff, best_off - 12),
        min(maxoff, best_off + 12) + 1,
    ):
        x = score(off, lo, hi, stride=2)
        if x:
            values.append(x)
    if not values:
        return None
    return max(values, key=lambda x: x["temporal"])

first = local_best(0, window)
last = local_best(max(0, len(s)-window), len(s))

errors = []

for name, value, threshold in (
    ("mean Spearman", best["mean_rho"], TEMPORAL_MEAN_RHO_MIN),
    ("edge Spearman", best["edge_rho"], TEMPORAL_EDGE_RHO_MIN),
    ("std Spearman", best["std_rho"], TEMPORAL_STD_RHO_MIN),
):
    if value is None or value < threshold:
        errors.append("%s=%r below %.3f" % (name, value, threshold))

if len(spatial) < MIN_SPATIAL_VALID_PAIRS:
    errors.append(
        "spatial valid pairs=%d below %d"
        % (len(spatial), MIN_SPATIAL_VALID_PAIRS)
    )
else:
    if spatial_median is None or spatial_median < SPATIAL_MEDIAN_MIN:
        errors.append(
            "spatial median=%r below %.3f"
            % (spatial_median, SPATIAL_MEDIAN_MIN)
        )
    if spatial_p10 is None or spatial_p10 < SPATIAL_P10_MIN:
        errors.append(
            "spatial p10=%r below %.3f"
            % (spatial_p10, SPATIAL_P10_MIN)
        )

drift = None
if first is None or last is None:
    errors.append("could not compute first/last drift windows")
else:
    drift = abs(first["offset"] - last["offset"])
    if drift > MAX_DRIFT_FRAMES:
        errors.append(
            "alignment drift=%d frames, maximum=%d"
            % (drift, MAX_DRIFT_FRAMES)
        )

if abs(best_off) >= maxoff - 5:
    errors.append(
        "best offset=%d landed near search boundary=%d"
        % (best_off, maxoff)
    )

result = {
    "method": "full-timeline 32x18 luma temporal Spearman + spatial NCC",
    "fps": fps,
    "sdr_frames": len(s),
    "hdr_frames": len(h),
    "best_offset_frames": best_off,
    "best_offset_seconds": best_off / float(fps),
    "aligned_overlap_frames": len(matched),
    "aligned_overlap_seconds": len(matched) / float(fps),
    "temporal": best,
    "spatial": {
        "valid_pairs": len(spatial),
        "median": spatial_median,
        "p10": spatial_p10,
    },
    "first_window": first,
    "last_window": last,
    "drift_frames": drift,
    "thresholds": {
        "mean_spearman_min": TEMPORAL_MEAN_RHO_MIN,
        "edge_spearman_min": TEMPORAL_EDGE_RHO_MIN,
        "std_spearman_min": TEMPORAL_STD_RHO_MIN,
        "spatial_median_min": SPATIAL_MEDIAN_MIN,
        "spatial_p10_min": SPATIAL_P10_MIN,
        "max_drift_frames": MAX_DRIFT_FRAMES,
        "min_aligned_frames": min_aligned_frames,
        "max_offset_frames": maxoff,
    },
    "errors": errors,
}

with open(outp, "w", encoding="utf-8") as f:
    json.dump(result, f, ensure_ascii=False, indent=2)
    f.write("\n")

print(json.dumps(result, ensure_ascii=False, indent=2))

if errors:
    for e in errors:
        print("ALIGNMENT ERROR:", e, file=sys.stderr)
    raise SystemExit(1)
PY

ok "full-timeline same-content alignment and drift gate passed"

###############################################################################
# 10) FINAL MANIFEST — VALIDATED BUT STILL UNCONSUMED
###############################################################################

say "writing final virgin-pair manifest"

SDR_SHA="$(shasum -a 256 "$SDR_CAPTURE" | awk '{print $1}')"
HDR_SHA="$(shasum -a 256 "$HDR_CAPTURE" | awk '{print $1}')"

python3 - \
  "$PENDING_MANIFEST" \
  "$SDR_CAPTURE" "$HDR_CAPTURE" \
  "$FINAL_SDR_CAPTURE" "$FINAL_HDR_CAPTURE" \
  "$SDR_SHA" "$HDR_SHA" \
  "$PROVIDER_EVIDENCE" "$SERVICE_LIST_EVIDENCE" "$RESOLVE_JSON" \
  "$DASH_CAPTURE_EVIDENCE" \
  "$META/stream-gate.json" "$META/full-decode-gate.json" \
  "$META/alignment.json" "$META/exact-duplicate-scan.json" <<'PY'
import datetime
import json
import os
import sys

(
    outp, sdr_source, hdr_source, sdr_final, hdr_final,
    sdr_sha, hdr_sha,
    provider_p, service_p, resolve_p, direct_dash_p,
    stream_p, decode_p, align_p, dup_p
) = sys.argv[1:]

provider = json.load(open(provider_p, encoding="utf-8"))
service_list = json.load(open(service_p, encoding="utf-8"))
resolve = json.load(open(resolve_p, encoding="utf-8"))
direct_dash = json.load(open(direct_dash_p, encoding="utf-8"))
stream = json.load(open(stream_p, encoding="utf-8"))
decode = json.load(open(decode_p, encoding="utf-8"))
align = json.load(open(align_p, encoding="utf-8"))
dup = json.load(open(dup_p, encoding="utf-8"))

run = direct_dash["contiguous_run"]
minimum_segments = direct_dash["minimum_contiguous_segments"]
if run["segment_count"] < minimum_segments:
    raise SystemExit("manifest refused: contiguous run below minimum")
if not run.get("no_gaps"):
    raise SystemExit("manifest refused: contiguous run contains gaps")
if direct_dash["sdr"]["segment_identities"] != direct_dash["hdr"]["segment_identities"]:
    raise SystemExit("manifest refused: SDR/HDR segment identities differ")
if decode["sdr_decoded_frames"] != decode["hdr_decoded_frames"]:
    raise SystemExit("manifest refused: decoded frame counts differ")

contiguous_run = {
    "startSegment": run["start_segment"],
    "endSegment": run["end_segment"],
    "segmentCount": run["segment_count"],
    "durationSeconds": run["duration_seconds"],
    "noGaps": True,
}

manifest = {
    "schemaVersion": 1,
    "verdict": "PAIR_VALID_VIRGIN",
    "temporalReadiness": "CONTIGUOUS_TEMPORAL_READY",
    "validatedAtUTC": datetime.datetime.now(
        datetime.timezone.utc
    ).isoformat(),
    "pair": {
        "provider": "DVB Project",
        "family": "DVB Live-Linear",
        "sharedSource": "Caminandes_E1-1080p_50fps.mp4",
        "sdrService": "03_hevc_uhd_sdr_ac4",
        "hdrService": "05_hevc_uhd_hlg_heaac",
    },
    "assets": {
        "sdr": {
            "path": os.path.abspath(sdr_final),
            "sha256": sdr_sha,
            "bytes": os.path.getsize(sdr_source),
        },
        "hdr": {
            "path": os.path.abspath(hdr_final),
            "sha256": hdr_sha,
            "bytes": os.path.getsize(hdr_source),
        },
    },
    "contiguousRun": contiguous_run,
    "providerEvidence": provider,
    "serviceListEvidence": service_list,
    "manifestEvidence": resolve,
    "directDashCaptureEvidence": direct_dash,
    "streamEvidence": stream,
    "fullDecodeEvidence": decode,
    "alignmentEvidence": align,
    "exactDuplicateEvidence": dup,
    "objectiveUse": {
        "consumed": False,
        "consumedAtUTC": None,
        "consumptionPurpose": None,
    },
    "holdoutSafety": {
        "datasetLockModified": False,
        "frozenSplitModified": False,
        "calibrationResultsModified": False,
        "approvedForFutureGateConsumption": True,
        "note": (
            "Validation only. Do not mark consumed until the existing "
            "pre-frozen/holdout gate explicitly admits this pair."
        ),
    },
}

with open(outp, "w", encoding="utf-8") as f:
    json.dump(manifest, f, ensure_ascii=False, indent=2)
    f.write("\n")

print(json.dumps({
    "verdict": manifest["verdict"],
    "temporalReadiness": manifest["temporalReadiness"],
    "contiguousRun": manifest["contiguousRun"],
    "sharedSource": manifest["pair"]["sharedSource"],
    "sdrService": manifest["pair"]["sdrService"],
    "hdrService": manifest["pair"]["hdrService"],
    "objectiveUse": manifest["objectiveUse"],
}, ensure_ascii=False, indent=2))
PY

say "atomically promoting validated assets and manifest"

python3 - \
  "$SDR_CAPTURE" "$FINAL_SDR_CAPTURE" \
  "$HDR_CAPTURE" "$FINAL_HDR_CAPTURE" \
  "$PENDING_MANIFEST" "$FINAL_MANIFEST" \
  "$PENDING" <<'PY'
import os
import sys

sdr_source, sdr_final, hdr_source, hdr_final, manifest_source, manifest_final, pending = sys.argv[1:]
pairs = [
    (sdr_source, sdr_final),
    (hdr_source, hdr_final),
    (manifest_source, manifest_final),
]

for source, _ in pairs:
    if not os.path.isfile(source) or os.path.getsize(source) <= 0:
        raise SystemExit("promotion source missing or empty: %s" % source)

backups = []
promoted = []
try:
    for index, (_, final) in enumerate(pairs):
        backup = os.path.join(
            pending,
            ".promotion-backup-%d-%d" % (os.getpid(), index),
        )
        if os.path.exists(final):
            os.replace(final, backup)
            backups.append((backup, final))

    for source, final in pairs:
        os.replace(source, final)
        promoted.append(final)
except Exception:
    for final in reversed(promoted):
        try:
            os.unlink(final)
        except FileNotFoundError:
            pass
    for backup, final in reversed(backups):
        if os.path.exists(backup):
            os.replace(backup, final)
    raise
else:
    for backup, _ in backups:
        try:
            os.unlink(backup)
        except FileNotFoundError:
            pass
PY

ok "PAIR_VALID_VIRGIN"
ok "CONTIGUOUS_TEMPORAL_READY"
printf '\nManifest:\n%s\n' "$FINAL_MANIFEST"
printf '\nThis pair is validated but remains UNCONSUMED.\n'
