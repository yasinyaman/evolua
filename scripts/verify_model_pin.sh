#!/usr/bin/env bash
# Check every pinned model in the ladder (lua/core/modelmgr.lua) against the
# sha256 Hugging Face publishes for that file — the `x-linked-etag` header of
# its resolve URL (the LFS object id). Nothing is downloaded. Run it before
# changing a pin, or in CI to catch an upstream re-upload.
#
#   scripts/verify_model_pin.sh        # exit 0 = every pin matches
set -u
cd "$(dirname "$0")/.."
LADDER=lua/core/modelmgr.lua

pairs=$(awk -F'"' '/url = "/ { u = $2 } /sha = "/ { if (u != "") print u, $2; u = "" }' "$LADDER")
if [ -z "$pairs" ]; then
  echo "no pinned url+sha pairs found in $LADDER"
  exit 1
fi

fail=0
while read -r url sha; do
  got=$(curl -sI --max-time 30 "$url" | tr -d '\r' \
        | awk -F'"' 'tolower($0) ~ /^x-linked-etag:/ { print $2 }')
  name=${url##*/}; name=${name%%\?*}
  if [ -z "$got" ]; then
    echo "?? $name — no x-linked-etag (offline, or not an LFS file?)"
    fail=1
  elif [ "$got" = "$sha" ]; then
    echo "ok $name"
  else
    echo "!! $name — pinned $sha, upstream $got"
    fail=1
  fi
done <<< "$pairs"
exit $fail
