#!/bin/sh

# Bootstrap verification: stages 3 + 4
# Stage 3: eco-boot.js compiles itself → eco-boot-2.js
# Stage 4: eco-boot-2.js compiles itself → eco-boot-3.js (fixed-point check)

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
COMPILER_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BUILD_KERNEL_DIR="$COMPILER_DIR/build-kernel"

cd "$BUILD_KERNEL_DIR"

# Stage 3: eco-boot.js compiles itself
echo "Stage 3: eco-boot.js → eco-boot-2.js"
node bin/eco-boot-runner.js make \
    --optimize \
    --kernel-package eco/compiler \
    --local-package eco/kernel="$COMPILER_DIR/../eco-kernel-cpp" \
    --output=bin/eco-boot-2.js \
    "$COMPILER_DIR/src/Terminal/Main.elm"
node "$COMPILER_DIR/scripts/replacements.js" bin/eco-boot-2.js

# Generate minimal runner for eco-boot-2 (kernel IO is inlined, no XHR needed)
cat > bin/eco-boot-2-runner.js <<'RUNNER'
const { Elm } = require("./eco-boot-2.js");
Elm.Terminal.Main.init();
RUNNER

# Stage 4: fixed-point check
echo "Stage 4: eco-boot-2.js → eco-boot-3.js"
node bin/eco-boot-2-runner.js make \
    --optimize \
    --kernel-package eco/compiler \
    --local-package eco/kernel="$COMPILER_DIR/../eco-kernel-cpp" \
    --output=bin/eco-boot-3.js \
    "$COMPILER_DIR/src/Terminal/Main.elm"
node "$COMPILER_DIR/scripts/replacements.js" bin/eco-boot-3.js

# Verify fixed point
if diff -q bin/eco-boot-2.js bin/eco-boot-3.js > /dev/null 2>&1; then
    echo "Fixed point reached — eco-boot-2.js == eco-boot-3.js"
else
    echo "ERROR: eco-boot-2.js and eco-boot-3.js differ!" >&2
    exit 1
fi
