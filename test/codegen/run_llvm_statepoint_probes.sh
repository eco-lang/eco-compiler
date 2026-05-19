#!/bin/bash
#
# LLVM-upstream regression probe runner.
#
# The fixtures `llvm_statepoint_struct_return_{1..8}.mlir` drive
# eco-boot-native directly through SelectionDAG to detect when LLVM
# learns to lower `gc.statepoint` calls returning wider LLVM structs.
# As of LLVM 21, N=1..3 lower cleanly and N=4..8 trip a SelectionDAG
# StatepointLowering assertion (CallEnd != CALLSEQ_END at
# StatepointLowering.cpp:354), which is why
# EcoUnboxedAggCrossSpec.cpp caps kMaxDirectFields at 3.
#
# Run this after bumping LLVM; if any of the XFAIL'd cases (N=4..8)
# start XPASSing, kMaxDirectFields can be raised.

set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DRIVER="${SCRIPT_DIR}/../../build/runtime/src/codegen/eco-boot-native"

if [ ! -x "$DRIVER" ]; then
    echo "Error: eco-boot-native not found at $DRIVER"
    echo "Build with: cmake --build build --target eco-boot-native"
    exit 1
fi

PASS_EXPECTED=(1 2 3)
FAIL_EXPECTED=(4 5 6 7 8)

unexpected=0
for n in "${PASS_EXPECTED[@]}"; do
    fixture="$SCRIPT_DIR/llvm_statepoint_struct_return_${n}.mlir"
    obj="$(mktemp --suffix=.o)"
    if ("$DRIVER" -emit=obj "$fixture" -o "$obj") >/dev/null 2>&1; then
        echo "PASS:  N=$n (expected)"
    else
        echo "FAIL:  N=$n (expected pass, got assertion crash)"
        unexpected=1
    fi
    rm -f "$obj"
done

for n in "${FAIL_EXPECTED[@]}"; do
    fixture="$SCRIPT_DIR/llvm_statepoint_struct_return_${n}.mlir"
    obj="$(mktemp --suffix=.o)"
    if ("$DRIVER" -emit=obj "$fixture" -o "$obj") >/dev/null 2>&1; then
        echo "XPASS: N=$n (LLVM appears to have fixed the bug — bump kMaxDirectFields)"
        unexpected=1
    else
        echo "XFAIL: N=$n (expected SelectionDAG StatepointLowering assertion)"
    fi
    rm -f "$obj"
done

if [ $unexpected -eq 0 ]; then
    echo ""
    echo "All probes behaved as expected for LLVM 21 baseline."
    exit 0
else
    echo ""
    echo "Unexpected probe outcome — see notes above."
    exit 1
fi
