#!/usr/bin/env bash
# Build the GitHub Pages site into _site/:
#   site/index.html, style.css, favicon.svg  → copied as they are (the landing page)
#   README.md                                 → readme.html
#   docs/*.md                                 → docs/*.html
#   docs/assets/*                             → assets/*
# Needs pandoc (the Pages workflow installs it; Ubuntu runners have it).
#
#   scripts/build_site.sh            # → _site/
#   OUT=/tmp/x scripts/build_site.sh
set -euo pipefail
cd "$(dirname "$0")/.."
OUT=${OUT:-_site}
command -v pandoc >/dev/null || { echo "pandoc is required (https://pandoc.org)"; exit 1; }

rm -rf "$OUT"
mkdir -p "$OUT/docs" "$OUT/assets"
cp site/index.html site/style.css site/favicon.svg "$OUT/"
cp docs/assets/* "$OUT/assets/" 2>/dev/null || true
touch "$OUT/.nojekyll"

# render one Markdown file: render <src.md> <out.html> <root> <crumb> [title]
render() {
  local src=$1 out=$2 root=$3 crumb=$4 title=${5:-}
  pandoc "$src" \
    --from gfm+attributes --to html5 --standalone \
    --template site/doc.html --lua-filter site/links.lua \
    --toc --toc-depth=2 --wrap=none \
    --metadata root="$root" --metadata crumb="$crumb" --metadata source="$src" \
    --metadata title="${title:-$(sed -n '1s/^# *//p' "$src")}" \
    --output "$out"
}

render README.md "$OUT/readme.html" . "README" "README"
for f in docs/*.md; do
  name=$(basename "$f" .md)
  render "$f" "$OUT/docs/$name.html" .. "docs"
done

echo "site built in $OUT/:"
find "$OUT" -type f | sort
