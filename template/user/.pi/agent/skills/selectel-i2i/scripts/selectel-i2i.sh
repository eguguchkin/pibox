#!/usr/bin/env bash
# i2i-редактирование картинки через Selectel AIG (qwen/qwen-image-3).
# Единственный рабочий способ на Selectel: POST /v1/images/generations
# с полем input_references (data-URL). Эндпоинт /v1/images/edits не реализован.
#
# Использование:
#   selectel-i2i.sh <вход.png|jpg> "<промпт-инструкция>" [выход.png] [модель]
#
# Пример:
#   selectel-i2i.sh ref.png "change the apple color from red to green, keep everything else exactly the same" out.png
set -euo pipefail

[ $# -ge 2 ] || { echo "usage: $0 <image> <prompt> [output.png] [model]" >&2; exit 2; }

IMG=$1
PROMPT=$2
OUT=${3:-edited.png}
MODEL=${4:-qwen/qwen-image-3}
BASE=${SELECTEL_AIG_BASE:-https://api.selectel.ru/aig/v1}

[ -f "$IMG" ] || { echo "not a file: $IMG" >&2; exit 1; }
KEY=${SELECTEL_AIG_KEY:?set SELECTEL_AIG_KEY}

MIME=$(file -b --mime-type "$IMG")
case "$MIME" in image/png|image/jpeg|image/webp) ;; *) echo "unsupported type: $MIME" >&2; exit 1;; esac

TMP=$(mktemp)
trap 'rm -f "$TMP"' EXIT
python3 - "$IMG" "$PROMPT" "$MODEL" "$MIME" > "$TMP" <<'PY'
import base64, json, sys
img, prompt, model, mime = sys.argv[1:5]
b64 = base64.b64encode(open(img, 'rb').read()).decode()
json.dump({
    'model': model,
    'prompt': prompt,
    'input_references': [{'type': 'image_url',
                          'image_url': {'url': f'data:{mime};base64,{b64}'}}],
}, sys.stdout)
PY

RESP=$(curl -s -X POST "$BASE/images/generations" \
  -H "Authorization: Bearer $KEY" \
  -H "Content-Type: application/json" \
  --data-binary @"$TMP")

printf '%s' "$RESP" > "$TMP.json"
python3 - "$TMP.json" "$OUT" <<'PY'
import base64, json, sys
r = json.load(open(sys.argv[1]))
if 'error' in r and r.get('error'):
    sys.exit(f"API error: {json.dumps(r['error'], ensure_ascii=False)[:300]}")
b64 = r['data'][0].get('b64_json')
if not b64:
    sys.exit(f"no image in response: {json.dumps(r, ensure_ascii=False)[:300]}")
open(sys.argv[2], 'wb').write(base64.b64decode(b64))
print(sys.argv[2])
PY
