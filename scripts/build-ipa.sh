#!/usr/bin/env bash
# Local unsigned IPA for SideStore (same steps as .github/workflows/sideload-ios.yml, on this Mac).
#   scripts/build-ipa.sh          rebuild the Swift app only (UI changes; reuses the cached Rust core)
#   scripts/build-ipa.sh --core   also rebuild the Rust core (after changes in crates/)
# Output: ~/Downloads/Spotless.ipa
set -euo pipefail
cd "$(dirname "$0")/.."
export PATH="$HOME/.cargo/bin:$PATH"
BUNDLE_ID="${BUNDLE_ID:-com.tanthomps.spotless}"
PROJECT_DIR=ios/Encore
OUT="${OUT:-$HOME/Downloads/Spotless.ipa}"
WORK="${TMPDIR:-/tmp}/spotless-build"
mkdir -p "$WORK"

if [[ "${1:-}" == "--core" || ! -d ios/EncoreCore/build/EncoreCoreFFI.xcframework ]]; then
  export ENCORE_CACHE="$HOME/Library/Caches/encore"
  LIBRARY_PATH="$(scripts/macos/fetch-libmpv.sh --arch arm64 | tail -1)"
  export LIBRARY_PATH
  scripts/build-ios-core.sh --release --device
fi

(cd "$PROJECT_DIR" && xcodegen generate --quiet)
ARCHIVE="$WORK/Spotless.xcarchive"
rm -rf "$ARCHIVE"
xcodebuild archive -quiet \
  -project "$PROJECT_DIR/Encore.xcodeproj" -scheme Encore -configuration Release \
  -destination generic/platform=iOS -archivePath "$ARCHIVE" \
  -clonedSourcePackagesDirPath "$WORK/spm" -derivedDataPath "$WORK/dd" \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" DEVELOPMENT_TEAM="" \
  PRODUCT_BUNDLE_IDENTIFIER="$BUNDLE_ID" CURRENT_PROJECT_VERSION="$(date +%Y%m%d%H%M)"

STAGE="$WORK/ipa"
rm -rf "$STAGE"; mkdir -p "$STAGE/Payload"
APP="$STAGE/Payload/Spotless.app"
ditto "$ARCHIVE/Products/Applications/Encore.app" "$APP"
rm -f "$APP/embedded.mobileprovision"
find "$APP" -name _CodeSignature -type d -prune -exec rm -rf {} +
rm -f "$OUT"
(cd "$STAGE" && zip -qry -X "$OUT" Payload)
echo "built $OUT ($(du -h "$OUT" | cut -f1))"
