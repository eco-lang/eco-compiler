#!/bin/sh
# Fetch UnicodeData.txt for a Unicode version into runtime/third_party/unicode/<version>/ and print
# its sha256 (README.md and the generator's UCD constant record it).
#
#   runtime/third_party/unicode/update.sh 17.0.0
#
# See design_docs/char-case-mapping.md, "Updating to a new Unicode version".
set -eu

ver=${1:?usage: update.sh <unicode version, e.g. 17.0.0>}
here=$(cd "$(dirname "$0")" && pwd)
mkdir -p "$here/$ver"
curl -fsSL -o "$here/$ver/UnicodeData.txt" "https://www.unicode.org/Public/$ver/ucd/UnicodeData.txt"
sha256sum "$here/$ver/UnicodeData.txt"
