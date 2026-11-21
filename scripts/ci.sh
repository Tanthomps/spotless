#!/usr/bin/env bash
# Spotless CI, run on this Mac instead of GitHub Actions (ci.yml is manual-only now).
#
#   scripts/ci.sh            UI + Rust core checks (what CI ran, plus the player crate)
#   scripts/ci.sh --ui       svelte-check + UI self-checks only
#   scripts/ci.sh --rust     cargo tests only
#
# Same checks as .github/workflows/ci.yml. The player crate's wall-clock audio tests, which a
# shared runner couldn't keep time for, run here too. Network tests stay #[ignore]d.
set -euo pipefail
cd "$(dirname "$0")/.."
export PATH="$HOME/.cargo/bin:$PATH"

do_ui=1 do_rust=1
case "${1:-}" in
  --ui) do_rust=0 ;;
  --rust) do_ui=0 ;;
  "") ;;
  *) echo "usage: scripts/ci.sh [--ui|--rust]" >&2; exit 2 ;;
esac

start=$SECONDS
if [[ $do_ui == 1 ]]; then
  echo "== ui: install"
  (cd ui && pnpm install --frozen-lockfile >/dev/null)
  echo "== ui: svelte-check"
  (cd ui && pnpm check)
  echo "== ui: self-checks"
  (cd ui && pnpm test)
fi

if [[ $do_rust == 1 ]]; then
  echo "== rust: libmpv"
  LIBDIR="$(scripts/macos/fetch-libmpv.sh --arch arm64 | tail -1)"
  export LIBRARY_PATH="$LIBDIR" DYLD_FALLBACK_LIBRARY_PATH="$LIBDIR"
  echo "== rust: cargo test (core crates + player)"
  cargo test --locked -p encore-core -p innertube -p encore-ffi -p player
fi

echo "== CI passed in $((SECONDS - start))s"
