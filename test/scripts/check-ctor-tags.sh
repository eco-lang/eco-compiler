#!/bin/sh
# check-ctor-tags.sh — fail if the compiler's reserved constructor-tag numbers drift from the runtime's.
#
# SD-18: compiler/src/Compiler/IR/Runtime/CtorTag.elm hard-codes two numbers, and takes a third from
# HeapLimits.elm, that must equal the C++ runtime's (its module doc: "Nothing in the compiler checks
# that they agree"):
#   dictRBNode       == CTOR_DICT_RBNODE  (elm-kernel-cpp core/Utils.cpp, http/HttpExports.cpp)
#   constantTag      == CONSTANT_TAG      (runtime/src/allocator/Heap.hpp)
#                    == value_enc::ConstantTag (runtime/src/codegen/Passes/EcoToLLVMInternal.h)
#   nullConsCapacity == NULL_CONS_MAX     (runtime/src/allocator/Heap.hpp; the codegen copy
#                                          value_enc::NullConsMax is already static_asserted).
#                       nullConsCapacity is HeapLimits.maxNullaryCtorIndex, the limit canonicalization
#                       enforces, so that literal is the one read.
# A mismatch is a silent miscompile (wrong tag in eco.case / Dict comparison), so check textually.
# Scans the repository only.
#
# Usage: test/scripts/check-ctor-tags.sh [REPO_ROOT]
set -eu
root=${1:-$(cd "$(dirname "$0")/../.." && pwd)}
fail=0

# elm_const NAME [FILE]: the literal on the line after "NAME =" in FILE (default CtorTag.elm) under
# compiler/src/Compiler/IR/Runtime/.
elm_const() {
    awk -v n="$1" '$0 ~ "^" n " =$" {getline; print $1; exit}' \
        "$root/compiler/src/Compiler/IR/Runtime/${2:-CtorTag.elm}"
}

# cpp_const FILE REGEX: the first number after the matched name (#define X v / X = v;).
cpp_const() {
    grep -E "$2" "$1" | head -n 1 | sed -E 's/.*(#define[ \t]+[A-Za-z_]+|=)[ \t]*(0[xX][0-9A-Fa-f]+|[0-9]+).*/\2/'
}

# same LABEL A B: compare two C/Elm integer literals numerically.
same() {
    if [ -z "$2" ] || [ -z "$3" ]; then
        echo "check-ctor-tags: $1: could not read a value (compiler '$2', runtime '$3')" >&2
        fail=1
        return
    fi
    a=$(printf '%d' "$2")
    b=$(printf '%d' "$3")
    if [ "$a" != "$b" ]; then
        echo "check-ctor-tags: $1: compiler $2 != runtime $3" >&2
        fail=1
    fi
}

rbnode=$(elm_const dictRBNode)
consttag=$(elm_const constantTag)
# CtorTag.nullConsCapacity must be defined as HeapLimits.maxNullaryCtorIndex, whose literal is compared.
if [ "$(elm_const nullConsCapacity)" != "HeapLimits.maxNullaryCtorIndex" ]; then
    echo "check-ctor-tags: CtorTag.nullConsCapacity is not HeapLimits.maxNullaryCtorIndex" >&2
    fail=1
fi
nullmax=$(elm_const maxNullaryCtorIndex HeapLimits.elm)

heap="$root/runtime/src/allocator/Heap.hpp"
venc="$root/runtime/src/codegen/Passes/EcoToLLVMInternal.h"

same "dictRBNode vs core/Utils.cpp CTOR_DICT_RBNODE" "$rbnode" \
    "$(cpp_const "$root/elm-kernel-cpp/src/core/Utils.cpp" 'CTOR_DICT_RBNODE[ \t]*=')"
same "dictRBNode vs http/HttpExports.cpp CTOR_DICT_RBNODE" "$rbnode" \
    "$(cpp_const "$root/elm-kernel-cpp/src/http/HttpExports.cpp" 'CTOR_DICT_RBNODE[ \t]*=')"
same "constantTag vs Heap.hpp CONSTANT_TAG" "$consttag" \
    "$(cpp_const "$heap" '^#define[ \t]+CONSTANT_TAG[ \t]')"
same "constantTag vs EcoToLLVMInternal.h ConstantTag" "$consttag" \
    "$(cpp_const "$venc" 'constexpr[ \t]+int64_t[ \t]+ConstantTag[ \t]*=')"
same "nullConsCapacity vs Heap.hpp NULL_CONS_MAX" "$nullmax" \
    "$(cpp_const "$heap" '^#define[ \t]+NULL_CONS_MAX[ \t]')"

if [ "$fail" -ne 0 ]; then
    exit 1
fi
echo "check-ctor-tags: OK (dictRBNode=$rbnode constantTag=$consttag nullConsCapacity=$nullmax)"
