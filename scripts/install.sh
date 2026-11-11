#!/usr/bin/env bash
# Install the prebuilt static extension into Raycast's extensions folder.
# No `npm run dev`, no watcher, no node_modules needed at runtime.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST="$ROOT/dist"
EXTENSIONS_DIR="${RAYCAST_EXTENSIONS_DIR:-$HOME/.config/raycast/extensions}"
TARGET="$EXTENSIONS_DIR/keystroke-typer-human"

# dist/ is committed-ready; only rebuild if it is missing.
if [[ ! -f "$DIST/package.json" ]]; then
  echo "dist/ 不存在，先执行构建…"
  (cd "$ROOT" && npm run build)
fi

mkdir -p "$TARGET"
rsync -a "$DIST/" "$TARGET/"

# These two files mark the extension as "in development" and make Raycast wait
# for a `ray develop` watcher. Removing them turns it into a normal local extension.
rm -f "$TARGET/cli.pid" "$TARGET/dev.log"

chmod +x "$TARGET/assets/type-keystrokes-helper"

echo "已安装到: $TARGET"
echo "内容:"
ls -1 "$TARGET"
echo
echo "下一步: 在 Raycast 里执行 Reload Extensions（或重启 Raycast），然后搜索 Type Text Like a Human。"
echo "提示: 运行时不依赖本项目的 node_modules，也不需要 npm run dev。"
