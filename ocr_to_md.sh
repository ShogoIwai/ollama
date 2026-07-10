#!/bin/sh
# ocr_to_md.sh — Vision-as-preprocessing: convert an image or PDF to
# Markdown text with a small dedicated OCR model, so a text-only agentic model
# (one whose /api/show lacks the `vision` capability) can consume the result
# without ever loading a vision tower.
#
# NOTE: currently OPTIONAL — both adopted models (qwen3.6:35b-a3b-mtp-q4_K_M and
# satgeze/qwen36-35b-uncensored-1m) are vision-capable and read images/PDF pages
# directly. This helper is retained for a future text-only model. The small OCR
# model (glm-ocr, ~7 GB) co-resides fine with a loaded ~22 GB text model on a
# 24 GB GPU, so you can OCR and infer in one sitting without a launcher swap
# (see README "Vision via OCR preprocessing"): run OCR to cache <input>.md, then
# feed the .md to the text model via direct connect.
#
# Usage:
#   ./ocr_to_md.sh <input.pdf|image>            # -> <input>.md next to the input
#   ./ocr_to_md.sh <input> <output.md>          # explicit output path
#   ./ocr_to_md.sh --force <input> [output.md]  # regenerate even if .md exists
#
# Env overrides (same style as the launchers):
#   OCR_MODEL        OCR model tag       (default: glm-ocr:bf16; glm-ocr:q8_0 is
#                    smaller if VRAM is tight)
#   OCR_DPI          PDF raster DPI      (default: 200; raise to 300 for dense figures)
#   OCR_PROMPT       OCR task prompt     (default: "Text Recognition:" — glm-ocr's
#                    exact predefined prompt; also "Formula Recognition:" /
#                    "Table Recognition:". Must match the model's expected string,
#                    or glm-ocr's renderer/parser degenerates into runaway output.)
#   OCR_NUM_PREDICT  max output tokens   (default: 8192; hard cap so a runaway page
#                    cannot loop forever)
#   OLLAMA_HOST      daemon base URL     (default: http://localhost:11434)
#
# PDF note: Ollama's vision endpoint accepts images only, so PDFs are rasterized
# per page with pdftoppm and OCR'd page by page, then concatenated.
set -eu

OCR_MODEL="${OCR_MODEL:-glm-ocr:bf16}"
OCR_DPI="${OCR_DPI:-200}"
# glm-ocr requires its exact predefined prompt and greedy decoding via the
# model's built-in template; a free-form prompt makes it degenerate into endless
# empty ``` fences. Keep this string exact (see zai-org/GLM-OCR ollama-deploy).
OCR_PROMPT="${OCR_PROMPT:-Text Recognition:}"
OCR_NUM_PREDICT="${OCR_NUM_PREDICT:-8192}"
OLLAMA_HOST="${OLLAMA_HOST:-http://localhost:11434}"

FORCE=0
ARGS=""
for arg in "$@"; do
  case "$arg" in
    --force) FORCE=1 ;;
    *) ARGS="${ARGS:+$ARGS }$arg" ;;
  esac
done
set -- $ARGS

if [ $# -lt 1 ] || [ $# -gt 2 ]; then
  echo "usage: $0 [--force] <input.pdf|image> [output.md]" >&2
  exit 2
fi

INPUT="$1"
if [ ! -f "$INPUT" ]; then
  echo "input not found: $INPUT" >&2
  exit 1
fi

# Default output: strip the input extension and append .md, in the same dir.
OUTPUT="${2:-${INPUT%.*}.md}"

if [ "$FORCE" -eq 0 ] && [ -f "$OUTPUT" ]; then
  echo "$OUTPUT already exists; skipping (use --force to regenerate)." >&2
  exit 0
fi

# Daemon reachable?
if ! curl -fsS --max-time 3 "${OLLAMA_HOST}/api/tags" >/dev/null 2>&1; then
  echo "No Ollama daemon at ${OLLAMA_HOST}." >&2
  echo "Start one first (a bare 'ollama serve' is enough for OCR; do NOT run the" >&2
  echo "22 GB text launcher at the same time — keep VRAM free for the OCR model)." >&2
  exit 1
fi

# OCR model present?
if ! curl -fsS --max-time 3 "${OLLAMA_HOST}/api/tags" 2>/dev/null \
     | jq -e --arg m "$OCR_MODEL" '.models[]?.name | select(. == $m)' >/dev/null 2>&1; then
  echo "OCR model '${OCR_MODEL}' is not pulled." >&2
  echo "Pull it once (manual operator step): ollama pull ${OCR_MODEL}" >&2
  exit 1
fi

# Build the list of page images to OCR. For a PDF, rasterize to a temp dir.
WORKDIR=""
cleanup() { [ -n "$WORKDIR" ] && rm -rf "$WORKDIR"; }
trap cleanup EXIT INT TERM

case "$INPUT" in
  *.pdf|*.PDF)
    command -v pdftoppm >/dev/null 2>&1 || { echo "pdftoppm not found (poppler-utils)" >&2; exit 1; }
    WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/ocr2md.XXXXXX")"
    echo "Rasterizing PDF at ${OCR_DPI} DPI..." >&2
    pdftoppm -png -r "$OCR_DPI" "$INPUT" "${WORKDIR}/page" >&2
    # pdftoppm zero-pads and sorts naturally with -1/-01 etc; glob + sort -V.
    PAGES="$(ls "${WORKDIR}"/page*.png 2>/dev/null | sort -V)"
    ;;
  *)
    # Single image; OCR it directly.
    PAGES="$INPUT"
    ;;
esac

if [ -z "$PAGES" ]; then
  echo "no page images produced from $INPUT" >&2
  exit 1
fi

# OCR each page via /api/generate (non-streaming). The vision endpoint takes a
# base64 image in the "images" array. python3 assembles the request/response so
# base64 and JSON quoting stay robust.
: > "$OUTPUT"
N=0
TOTAL="$(printf '%s\n' "$PAGES" | wc -l | tr -d ' ')"
for IMG in $PAGES; do
  N=$((N + 1))
  echo "OCR page ${N}/${TOTAL}: $(basename "$IMG")" >&2
  OLLAMA_HOST="$OLLAMA_HOST" OCR_MODEL="$OCR_MODEL" OCR_PROMPT="$OCR_PROMPT" \
  OCR_NUM_PREDICT="$OCR_NUM_PREDICT" IMG="$IMG" python3 - <<'PY' >> "$OUTPUT"
import base64, json, os, sys, urllib.request

host    = os.environ["OLLAMA_HOST"].rstrip("/")
model   = os.environ["OCR_MODEL"]
prompt  = os.environ["OCR_PROMPT"]
npred   = int(os.environ["OCR_NUM_PREDICT"])
img     = os.environ["IMG"]

with open(img, "rb") as f:
    b64 = base64.b64encode(f.read()).decode("ascii")

# Greedy/deterministic decoding is what GLM-OCR expects (do_sample: false); a
# finite num_predict is a hard safety cap against runaway repetition.
payload = {
    "model":  model,
    "prompt": prompt,
    "images": [b64],
    "stream": False,
    "options": {
        "temperature":    0,
        "top_p":          1,
        "repeat_penalty": 1,
        "num_predict":    npred,
    },
}
req = urllib.request.Request(
    host + "/api/generate",
    data=json.dumps(payload).encode("utf-8"),
    headers={"Content-Type": "application/json"},
)
try:
    with urllib.request.urlopen(req, timeout=600) as r:
        resp = json.load(r)
except Exception as e:
    sys.stderr.write(f"OCR request failed for {img}: {e}\n")
    sys.exit(1)

text = resp.get("response", "")

# glm-ocr (with this Ollama build's parser) tends to emit the clean transcription
# once, then ECHO it wrapped in a ```markdown ... ``` block — and on sparse pages
# that echo degenerates into an endless run of ``` fences or a repeated line.
# Keep the leading clean transcription: cut at the first fenced-code marker line
# (normal OCR prose does not start a line with ```), and defensively stop if any
# line repeats many times in a row (runaway guard).
import re
out, prev, run = [], None, 0
for line in text.splitlines():
    if re.match(r"^\s*```", line):        # first code fence = start of the echo/runaway
        break
    if line == prev:
        run += 1
        if run >= 5:                       # 6+ identical consecutive lines = runaway
            break
    else:
        run = 0
    prev = line
    out.append(line)

sys.stdout.write("\n".join(out).rstrip())
sys.stdout.write("\n")
PY
  # Page separator between pages (not after the last), for multi-page PDFs.
  if [ "$N" -lt "$TOTAL" ]; then
    printf '\n\n---\n\n' >> "$OUTPUT"
  fi
done

echo "Wrote ${OUTPUT} (${TOTAL} page(s), model=${OCR_MODEL})." >&2
