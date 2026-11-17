#!/usr/bin/env bash
# ./install.sh [bindir]              create a command per providers/*.env (symlink to bin/ccx)
# ./install.sh --uninstall [bindir]  remove those symlinks
set -euo pipefail

here=$(cd -P "$(dirname "$0")" && pwd)
ccx=$here/bin/ccx
uninstall=0
if [ "${1:-}" = --uninstall ]; then uninstall=1; shift; fi
bindir=${1:-$HOME/.local/bin}
mkdir -p "$bindir"

# Drop every existing link to this ccx first, so the command of a provider that
# was removed or renamed goes away too.
for target in "$bindir"/*; do
  if [ -L "$target" ] && [ "$(readlink "$target")" = "$ccx" ]; then
    rm "$target"
    [ "$uninstall" = 0 ] || echo "removed $target"
  fi
done
[ "$uninstall" = 0 ] || exit 0

chmod +x "$ccx"
for f in "$ccx" "$here"/providers/*.env; do
  n=$(basename "$f" .env)
  case $n in _*) continue ;; esac
  target=$bindir/$n
  if [ -e "$target" ] || [ -L "$target" ]; then
    echo "skip   ${n}: ${target} exists and is not a ccx link" >&2; continue
  fi
  other=$(command -v "$n" 2>/dev/null || true)
  [ -z "$other" ] || echo "warn   ${n}: ${other} is also on PATH; whichever comes first wins" >&2
  ln -s "$ccx" "$target"
  echo "linked $target -> bin/ccx"
done

case ":$PATH:" in *":$bindir:"*) ;; *) echo "note: ${bindir} is not on PATH" >&2 ;; esac
