#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."

./scripts/build_app.sh release
open "build/iTrans.app"
