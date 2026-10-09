#!/usr/bin/env bash
# Fetch the model the `embed_smol` feature bakes into the binary
# (src/llm.rs: include_bytes!("../models/smol.gguf")) and verify its sha256.
# The file isn't in the repo; without it `cargo build --features embed_smol` fails.
#
#   scripts/fetch_model.sh            # → models/smol.gguf (skips if already verified)
#   scripts/fetch_model.sh smol --force
#
# The pinned file is SmolLM2-135M-Instruct Q8_0 (~145 MB) — the decision brain
# EvoLua was developed against. scripts/verify_model_pin.sh checks this pin too.
set -eu
cd "$(dirname "$0")/.."

variant=smol; force=0
for a in "$@"; do
  case "$a" in
    smol) variant=smol ;;
    --force) force=1 ;;
    *) echo "usage: $0 [smol] [--force]" >&2; exit 2 ;;
  esac
done

case "$variant" in
  smol)
    URL="https://huggingface.co/bartowski/SmolLM2-135M-Instruct-GGUF/resolve/main/SmolLM2-135M-Instruct-Q8_0.gguf"
    SHA="5a1395716f7913741cc51d98581b9b1228d80987a9f7d3664106742eb06bba83"
    DEST=models/smol.gguf
    ;;
esac

sha256() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1"; else shasum -a 256 "$1"; fi | awk '{print $1}'
}

if [ -f "$DEST" ] && [ "$force" -eq 0 ]; then
  if [ "$(sha256 "$DEST")" = "$SHA" ]; then
    echo "$DEST already present and verified"
    exit 0
  fi
  echo "$DEST exists but its sha256 differs from the pin — re-run with --force to replace it" >&2
  exit 1
fi

mkdir -p "$(dirname "$DEST")"
tmp="$DEST.part"
trap 'rm -f "$tmp"' EXIT
curl -fL --retry 3 -o "$tmp" "$URL"
got=$(sha256 "$tmp")
if [ "$got" != "$SHA" ]; then
  echo "checksum mismatch: expected $SHA, got $got" >&2
  exit 1
fi
mv "$tmp" "$DEST"
echo "$DEST verified ($SHA)"
