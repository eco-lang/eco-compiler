# Bytecode Remaining Failures Analysis

## Test Results

| Mode | Passed | Failed | Bytecode-only |
|------|--------|--------|---------------|
| Text MLIR | 925 | 18 | — |
| Bytecode | 895 | 48 | 31 |

## Root Causes

### Root Cause 1: Terminator ops in block body (11 tests — Category A)

**Evidence**: `CaseSingleCtorBoolTest_extractBool_$_3` function:
- Text round-trip: `eco.project.custom` + `eco.return` (2 ops)
- Bytecode round-trip: `eco.project.custom` + `eco.yield` + `eco.return` (3 ops!)

The Elm AST's `MlirBlock.body` sometimes contains ops with `isTerminator = True`
(like `eco.yield`). The text printer (Pretty.elm line 179) **skips** these:
```elm
if op.isTerminator then ( linesRev, envAcc ) else ...
```

But the bytecode encoder includes ALL ops from `blk.body ++ [blk.terminator]`,
emitting the extra terminator. This causes `eco.yield` to appear outside its
parent `eco.case`.

**Fix**: Filter terminators from `blk.body` in the bytecode encoder:
```elm
allOps = List.filter (\op -> not op.isTerminator) blk.body ++ [ blk.terminator ]
```

**Affected tests**: All 11 "eco.yield expects parent eco.case" failures including
CaseSingleCtorBoolTest, ClosureCapture06Test, CaseNestedCtorTest, etc.

### Root Cause 2: String escape handling (10+ tests — Category C partial)

**Evidence**: `StringEscapesTest` diff:
- Text: `{value = "line1\0Aline2"}` (hex escape, `\n` → `\0A`)
- Bytecode: `{value = "line1\\nline2"}` (literal `\n` not converted)

The text printer (`Pretty.elm`) calls `escapeForMlir` which:
1. Converts `\uXXXX` to UTF-8 via `convertUnicodeEscapesToUtf8`
2. Escapes unescaped quotes

The bytecode encoder stores raw StringAttr values from the Elm AST without
applying `escapeForMlir`. MLIR's bytecode writer/reader handles strings as
raw UTF-8 bytes, so escape sequences like `\n` are stored as TWO characters
(backslash + n) instead of one byte (0x0A).

**Fix**: Apply escape conversion when collecting StringAttr values for bytecode:
```elm
EStringAttr s -> encodeOwnedString st (escapeForMlir s)
```
Wait — actually the opposite. The raw Elm AST strings have `\n` as two chars.
The text printer converts them to real newlines via `escapeForMlir`. For bytecode,
we should also convert: the string value in the bytecode should be the ACTUAL
UTF-8 string, not the escaped representation.

Actually: `escapeForMlir` converts `\uXXXX` → UTF-8 chars and `\n` → stays `\n`.
MLIR text format interprets `\0A` as a hex byte. But the bytecode format stores
raw bytes. So the string should contain the ACTUAL newline byte (0x0A), not the
escape sequence.

The correct fix: apply string unescaping when storing strings in the bytecode.
Convert `\n` → 0x0A, `\t` → 0x09, `\"` → 0x22, etc. This is what the C++
MLIR writer does when it writes a StringAttr to bytecode.

**Affected tests**: StringEscapesTest, StringEscapeSingleQuoteTest,
StringWordsLinesTest, StringTrimTest, StringEmptyTest, and many elm-json/elm-bytes
tests that use string operations.

### Root Cause 3: Duplicate kernel function symbols (1 test — Category D)

**Evidence**: `EqualityIntPapWithStringChainTest` bytecode round-trip shows 2
definitions of `Elm_Kernel_Utils_equal` while text shows 1.

This is likely from the `moduleBodyRegion` function splitting the module body
ops incorrectly, or from the codegen generating duplicate kernel declarations
that the text printer deduplicates but bytecode doesn't.

**Fix**: Deduplicate kernel declarations before encoding, or investigate why
the bytecode produces a duplicate.

### Root Cause 4: Branch successor operand encoding (1 test)

`CaseSingleCtorBoolMultiTypeTest`: `branch has 0 operands for successor #0,
but target block has 1`. This is likely from `eco.jump` ops that pass arguments
to successor blocks. The bytecode encoder's successor encoding may not encode
the operands passed to the successor block.

**Fix**: When encoding successor blocks in `encodeOp`, also encode the operands
for each successor (currently we only encode the block index, not the arguments).
Need to investigate MLIR's bytecode format for block arguments on successors.

## Proposed Fix Priority

1. **Root Cause 1 (terminators in body)**: Simple one-line fix, affects 11 tests
2. **Root Cause 2 (string escaping)**: Moderate fix, affects 10+ tests
3. **Root Cause 4 (successor operands)**: Small fix, affects 1-2 tests
4. **Root Cause 3 (duplicate symbols)**: Investigate further, affects 1 test
