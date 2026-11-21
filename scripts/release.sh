#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."

APP_NAME="iTrans"
INFO_PLIST="Resources/Info.plist"
APP_PATH="build/${APP_NAME}.app"
DIST_DIR="dist"

VERSION="${1:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${INFO_PLIST}")}"
BUILD_NUMBER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "${INFO_PLIST}")"

DMG_PATH="${DIST_DIR}/${APP_NAME}-${VERSION}.dmg"
ZIP_PATH="${DIST_DIR}/${APP_NAME}-${VERSION}.zip"
CHECKSUM_PATH="${DIST_DIR}/SHA256SUMS.txt"

echo "==> Releasing ${APP_NAME} ${VERSION} (build ${BUILD_NUMBER})"

./scripts/build_app.sh release

ACTUAL_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${APP_PATH}/Contents/Info.plist")"
if [ "${ACTUAL_VERSION}" != "${VERSION}" ]; then
    echo "error: bundled version ${ACTUAL_VERSION} does not match requested ${VERSION}" >&2
    exit 1
fi

echo "==> Verifying code signature"
codesign --verify --deep --strict "${APP_PATH}"

mkdir -p "${DIST_DIR}"
rm -f "${DMG_PATH}" "${ZIP_PATH}" "${CHECKSUM_PATH}"

echo "==> Creating ZIP archive"
ditto -c -k --sequesterRsrc --keepParent "${APP_PATH}" "${ZIP_PATH}"

echo "==> Creating DMG"
STAGE="$(mktemp -d)"
trap 'rm -rf "${STAGE}"' EXIT

mkdir -p "${STAGE}/${APP_NAME}"
cp -R "${APP_PATH}" "${STAGE}/${APP_NAME}/"
ln -s /Applications "${STAGE}/${APP_NAME}/Applications"

if [ -f "Resources/AppIcon.icns" ]; then
    cp "Resources/AppIcon.icns" "${STAGE}/${APP_NAME}/.VolumeIcon.icns"
    if command -v SetFile >/dev/null 2>&1; then
        SetFile -a C "${STAGE}/${APP_NAME}"
    fi
fi

rm -f "${DMG_PATH}"
if ! diskutil image create from "${STAGE}/${APP_NAME}" \
    --format UDZO \
    --volumeName "${APP_NAME}" \
    "${DMG_PATH}" >/dev/null 2>"${STAGE}/dmg.log"; then
    cat "${STAGE}/dmg.log" >&2
    exit 1
fi

echo "==> Writing checksums"
(
    cd "${DIST_DIR}"
    shasum -a 256 "$(basename "${DMG_PATH}")" "$(basename "${ZIP_PATH}")" > "$(basename "${CHECKSUM_PATH}")"
)

echo
echo "==> Release artifacts"
ls -lh "${DMG_PATH}" "${ZIP_PATH}" "${CHECKSUM_PATH}"
echo
cat "${CHECKSUM_PATH}"
