#!/bin/sh
# Builds the browser worker with only the standard library's stubs and stages
# it into the Swift target. Needs Node; pnpm comes through npx, pinned.
set -eu

root="$(cd "$(dirname "$0")/.." && pwd)"
pnpm="npx -y pnpm@$(node -p "require('$root/package.json').packageManager.split('@')[1]")"
resources="$root/Swift/Sources/Pyright/Resources"

cd "$root"

# The browser package reaches pyright-internal by path, not as a dependency.
$pnpm install --frozen-lockfile --filter "browser-basedpyright..." --filter "pyright-internal..."
cd packages/browser-pyright
TYPESHED_STDLIB_ONLY=1 $pnpm run build

cp dist/pyright.worker.js "$resources/pyright.worker.js"
cp "$root/LICENSE.txt" "$resources/LICENSE.txt"
ls -lh "$resources/pyright.worker.js"
