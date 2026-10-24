#!/bin/sh
# check-ctor-tags.sh — fail if the compiler's reserved constructor-tag numbers drift from the runtime's.
#
# SD-18: compiler/src/Compiler/Data/CtorTag.elm hard-codes three numbers that must equal the C++
# runtime's (its module doc: "Nothing in the compiler checks that they agree"):
#   dictRBNode       == CTOR_DICT_RBNODE  (elm-kernel-cpp core/Utils.cpp, http/HttpExports.cpp)
#   constantTag      == CONSTANT_TAG      (runtime/src/allocator/Heap.hpp)
#                    == value_enc::ConstantTag (runtime/src/codegen/Passes/EcoToLLVMInternal.h)
#   nullConsCapacity == NULL_CONS_MAX     (runtime/src/allocator/Heap.hpp; the codegen copy
#                                          value_enc::NullConsMax is already static_asserted)
# A mismatch is a silent miscompile (wrong tag in eco.case / Dict comparison), so check textually.
# Scans the repository only.
#
# Usage: test/scripts/check-ctor-tags.sh [REPO_ROOT]
set -eu
root=${1:-$(cd "$(dirname "$0")/../.." && pwd)}
fail=0

# elm_const NAME: the literal on the line after "NAME =" in CtorTag.elm.
elm_const() {
    awk -v n="$1" '$0 ~ "^" n " =$" {getline; print $1; exit}' \
        "$root/compiler/src/Compiler/Data/CtorTag.elm"
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
nullmax=$(elm_const nullConsCapacity)

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
