#!/usr/bin/env bash
# Concatenates the token/component layers after the @tailwind directives
# (plain `tailwindcss` CLI doesn't resolve cross-file @import without
# postcss-import, so this is done as a build step instead) and compiles.
set -euo pipefail
cd "$(dirname "$0")/../../../"

{
  echo '@tailwind base;'
  echo '@tailwind components;'
  echo '@tailwind utilities;'
  echo
  cat static/css/src/fonts.css
  echo
  cat static/css/src/tokens.css
  echo
  cat static/css/src/legacy.css
  echo
  cat static/css/src/shell.css
} > static/css/src/input.css

npx tailwindcss -i static/css/src/input.css -o static/css/tailwind.css --minify
