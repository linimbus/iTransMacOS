#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
APP_NAME="iTrans"
APP_DIR="build/${APP_NAME}.app"

echo "==> Building Swift package (${CONFIG})"
swift build -c "${CONFIG}"

BIN_PATH="$(swift build -c "${CONFIG}" --show-bin-path)"

echo "==> Assembling ${APP_DIR}"
rm -rf "${APP_DIR}"
mkdir -p "${APP_DIR}/Contents/MacOS" "${APP_DIR}/Contents/Resources"

cp "${BIN_PATH}/${APP_NAME}" "${APP_DIR}/Contents/MacOS/${APP_NAME}"
cp "Resources/Info.plist" "${APP_DIR}/Contents/Info.plist"
if [ -f "Resources/AppIcon.icns" ]; then
    cp "Resources/AppIcon.icns" "${APP_DIR}/Contents/Resources/AppIcon.icns"
fi
printf 'APPL????' > "${APP_DIR}/Contents/PkgInfo"

echo "==> Codesigning (ad-hoc)"
codesign --force --deep --sign - "${APP_DIR}" >/dev/null 2>&1 || echo "    codesign skipped"

echo "==> Done: ${APP_DIR}"
