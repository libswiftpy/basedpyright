#!/bin/sh
# Builds the browser worker with only the standard library's stubs and packs
# it into the Swift target. Needs macOS and Node; pnpm comes through npx, pinned.
set -eu

root="$(cd "$(dirname "$0")/.." && pwd)"
pnpm="npx -y pnpm@$(node -p "require('$root/package.json').packageManager.split('@')[1]")"
resources="$root/Swift/Sources/Pyright/Resources"

cd "$root"

# The browser package reaches pyright-internal by path, not as a dependency.
$pnpm install --frozen-lockfile --filter "browser-basedpyright..." --filter "pyright-internal..."
cd packages/browser-pyright
TYPESHED_STDLIB_ONLY=1 $pnpm run build

compression_tool -encode -a lzma -i dist/pyright.worker.js -o "$resources/pyright.worker.js.lzma"
cp "$root/LICENSE.txt" "$resources/LICENSE.txt"
ls -lh "$resources/pyright.worker.js.lzma"
