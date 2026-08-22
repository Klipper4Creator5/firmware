#!/usr/bin/env bash
# Download a Mainsail release into assets/ and point config.env at it.
#   ./fetch-mainsail.sh            latest
#   ./fetch-mainsail.sh v2.13.2    a specific tag
set -euo pipefail
cd "$(cd "$(dirname "$0")/.." && pwd)"
TAG="${1:-latest}"
if [ "$TAG" = "latest" ]; then
    URL=https://github.com/mainsail-crew/mainsail/releases/latest/download/mainsail.zip
else
    URL="https://github.com/mainsail-crew/mainsail/releases/download/$TAG/mainsail.zip"
fi
mkdir -p assets
echo ">> $URL"
curl -fL --progress-bar -o assets/mainsail.zip "$URL"
unzip -l assets/mainsail.zip | tail -3
echo
echo "Now set in config.env:"
echo '  MAINSAIL_ZIP="$PWD/assets/mainsail.zip"'
