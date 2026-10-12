#!/usr/bin/env bash
# Build the GitHub Pages site into _site/:
#   site/index.html, style.css, favicon.svg  → copied as they are (the landing page)
#   README.md, README.tr.md                   → readme.html, readme.tr.html
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

# render one Markdown file: render <src.md> <out.html> <root> <crumb> [lang] [title] [alt]
#   lang  = en | tr (the menu follows it)
#   alt   = the same page in the other language, when one exists (the language switch);
#           defaults to the other language's README
render() {
  local src=$1 out=$2 root=$3 crumb=$4 lang=${5:-en} title=${6:-} alt=${7:-}
  local tr=""; [ "$lang" = tr ] && tr=true
  if [ -z "$alt" ]; then
    if [ "$lang" = tr ]; then alt="$root/readme.html"; else alt="$root/readme.tr.html"; fi
  fi
  pandoc "$src" \
    --from gfm+attributes --to html5 --standalone \
    --template site/doc.html --lua-filter site/links.lua \
    --toc --toc-depth=2 --wrap=none \
    --metadata root="$root" --metadata crumb="$crumb" --metadata source="$src" --metadata lang="$lang" \
    ${tr:+--metadata tr=true} --metadata alt="$alt" \
    --metadata title="${title:-$(sed -n '1s/^# *//p' "$src")}" \
    --output "$out"
}

render README.md    "$OUT/readme.html"    . "README"      en "README"          "./readme.tr.html"
render README.tr.md "$OUT/readme.tr.html" . "README (TR)" tr "README (Türkçe)" "./readme.html"
for f in docs/*.md; do
  name=$(basename "$f" .md)
  lang=en; alt=""
  case "$name" in
    *.tr) lang=tr; [ -f "docs/${name%.tr}.md" ] && alt="${name%.tr}.html" ;;
    *)    [ -f "docs/$name.tr.md" ] && alt="$name.tr.html" ;;
  esac
  render "$f" "$OUT/docs/$name.html" .. "docs" "$lang" "" "$alt"
done

echo "site built in $OUT/:"
find "$OUT" -type f | sort
