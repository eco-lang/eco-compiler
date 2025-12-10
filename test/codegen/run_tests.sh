#!/bin/bash
#
# Simple test runner for eco codegen tests.
# Uses grep-based pattern matching instead of FileCheck.
#
# Usage: ./run_tests.sh [test.mlir ...]

# Don't use set -e as arithmetic expressions can return non-zero

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ECOC="${SCRIPT_DIR}/../../build/runtime/src/codegen/ecoc"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Counters
PASSED=0
FAILED=0
SKIPPED=0

# Simple CHECK pattern matching
# Returns 0 if all CHECK patterns are found in the output
check_patterns() {
    local test_file="$1"
    local output="$2"

    # Extract CHECK patterns
    local patterns=$(grep '^[[:space:]]*// CHECK:' "$test_file" | sed 's|^[[:space:]]*// CHECK:[[:space:]]*||')

    if [ -z "$patterns" ]; then
        return 0  # No patterns to check
    fi

    # Check each pattern exists in output
    while IFS= read -r pattern; do
        if [ -z "$pattern" ]; then
            continue
        fi

        # Use grep -F for literal matching (-- stops option processing)
        if ! echo "$output" | grep -qF -- "$pattern"; then
            echo "  Missing pattern: $pattern"
            return 1
        fi
    done <<< "$patterns"

    return 0
}

run_test() {
    local test_file="$1"
    local test_name=$(basename "$test_file")

    # Extract RUN line and determine emit mode
    local run_line=$(grep -m1 '^// RUN:' "$test_file" | sed 's|^// RUN: *||')

    if [ -z "$run_line" ]; then
        echo -e "${YELLOW}SKIP${NC}: $test_name (no RUN line)"
        ((SKIPPED++))
        return
    fi

    # Parse emit mode from RUN line
    local emit_mode="mlir-llvm"
    if [[ "$run_line" == *"-emit=jit"* ]]; then
        emit_mode="jit"
    elif [[ "$run_line" == *"-emit=llvm"* ]]; then
        emit_mode="llvm"
    elif [[ "$run_line" == *"-emit=mlir-llvm"* ]]; then
        emit_mode="mlir-llvm"
    elif [[ "$run_line" == *"-emit=mlir"* ]]; then
        emit_mode="mlir"
    fi

    # Run ecoc
    local output
    output=$("$ECOC" "$test_file" -emit="$emit_mode" 2>&1) || true

    # Check patterns
    if check_patterns "$test_file" "$output"; then
        echo -e "${GREEN}PASS${NC}: $test_name"
        ((PASSED++))
    else
        echo -e "${RED}FAIL${NC}: $test_name"
        echo "  Output:"
        echo "$output" | head -30 | sed 's/^/    /'
        ((FAILED++))
    fi
}

# Check dependencies
if [ ! -x "$ECOC" ]; then
    echo "Error: ecoc not found at $ECOC"
    echo "Build with: cmake --build build --target ecoc"
    exit 1
fi

# Get test files
if [ $# -gt 0 ]; then
    TEST_FILES=("$@")
else
    TEST_FILES=("$SCRIPT_DIR"/*.mlir)
fi

echo "=== Eco Codegen Tests ==="
echo ""

for test_file in "${TEST_FILES[@]}"; do
    if [ -f "$test_file" ]; then
        run_test "$test_file"
    fi
done

echo ""
echo "=== Summary ==="
echo -e "${GREEN}Passed${NC}: $PASSED"
echo -e "${RED}Failed${NC}: $FAILED"
echo -e "${YELLOW}Skipped${NC}: $SKIPPED"

if [ $FAILED -gt 0 ]; then
    exit 1
fi
