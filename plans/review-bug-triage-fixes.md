---
status: partial
updated: 2026-10-28
remaining: "Parts 2-8 not started; Part 1 (32-bit Char) implemented 2026-10-28, bootstrap fixed point (4b/8c/9b) not yet run for it"
---

# Fixes for the review-bug triage

Every test that fails on 2026-10-28 pins a confirmed bug from the recomment-bug triage
(`compiler/recomment-bugs-triage.tsv`, VERIFIED section): 62 compiler elm-tests, 16 native E2E
tests (`test/elm/src`) and 45 node tests (`test/scripts`). This plan gives an implementation-ready
fix for each. A fix is done when its listed tests pass and no other test changes state.

Each item below was lowered on 2026-10-28: root cause confirmed in the current code, the fix
specified, and (except where marked unvalidated) prototyped in a private copy and run against its
failing tests and the full elm-test suite (no new failures in any group). The prototype diffs are
kept, outside git, in `snapshots/review-bug-triage-fixes/` (one diff per part, plus the extra
private tests); other `/tmp/lw-*` paths below were scratch trees and are not kept; they are a
reference for implementation, not a patch to apply blindly, since the parts overlap (below).

## Status

| Part | Items | Confidence | Validated |
|---|---|---|---|
| 1 Char 32-bit (DONE 2026-10-28, bootstrap pending) | one change set | compiler high; dialect/runtime/kernels medium | compiler side prototyped (astral unit tests pass; codegen checkers updated); C++ is a design only |
| 2 Parser + 5.1 | Unicode identifiers; `andThen` | high (JS host), medium-high (native) | yes; private compiler rebuilt, self-compiles, E2E source compiles |
| 3a Mono | 3.1 aliases, 3.2 local rename, 3.5 nested destructure | high, high, medium-high | pipeline tests pass (both engines for 3.1/3.2) |
| 3b Optimizer | 3.3 let rec type, 3.4 lambda boundaries, 3.6 entry main, 3.7 accessors, 3.8 erased tail call | high, high, high (wiring medium-high), medium-high, high | unit tests pass; E2E sources compile to correct MLIR (not run) |
| 4 Literals/MLIR | 4.1-4.7 | high except 4.2 native (medium) and 4.3b C++ (medium-high, design only) | Elm side prototyped; compiled bytecode decoded and checked |
| 5 Reports | 5.2-5.10 | high (5.3 native isatty medium) | unit tests pass; `cli-errors` 1-10 pass on a rebuilt compiler |
| 6-7 Builder, host | 6.1-6.8, 7.1-7.4 | high (7.4 `MVar.drop` medium) | unit tests, `builder-cli`, `cli-builder` and both handler suites pass |

Not run anywhere yet: the native E2E binary, the C++ changes (Part 1 runtime/dialect/kernels, 4.3b
`EcoControlFlowToSCF`, 5.3 native isatty), and a bootstrap. These are the remaining risk.

## Decisions needed before implementing

1. **4.2 hex literals at or above 2^63** mean their 64-bit two's-complement value on every target
   (`0xFFFFFFFFFFFFFFFF` is `-1`), unlike Elm-on-JS (a huge double).
2. **4.2 inexact literals:** the JS-hosted compiler rejects an Int literal needing more than 53
   significant bits ("INEXACT INTEGER") instead of rounding it silently.
3. **3.6 entry main:** a root module without `main` now fails ("No main function found") instead of
   compiling another module's `main`.
4. **6.8b / 7.4:** `File.lock` in the JS host locks within one process only (Node has no portable
   file lock); `MVar.drop` answers waiting readers with an error (crash) instead of a silent hang.

## Overlaps and order

- Do **Part 2** first. Its `Primitives.andThen` fix (5.1) also fixes the three `Json/DecodeTest`
  cases, so 6.1 then needs only its new `ObjectFirstField` error, not the local `andThenCommit`.
- **5.3 and 7.x both edit `compiler/bin/eco-io-handler.js`** (5.3 adds `Console.isTerminal`); merge
  by hand.
- **4.1** keys char cases by decoded value; **Part 1** makes those values 32-bit. Either order works;
  Part 1 also fixes the i16 sign-extension in the char switch lowering found under 4.3b.
- **4.7** (U+FFFF) changes `Parse/StringTests.elm`, which pins the old output.
- **5.8** moves 4 golden fingerprints (`let-family`, `pipe-chains`, `call-shapes`,
  `access-update-accessor`); confirm with a bootstrap byte-identity check.
- **Part 1** is the largest and needs the three-stage bootstrap described in its section and a
  wipe of `~/.eco` package artifacts and `eco-stuff` caches; do it last.

## Gate

For each part: elm-tests, `full`, stress, JS E2E, the node suites in `test/scripts` and the
bootstrap (4b/8c/9b), each run once. Only the part's listed tests change state (to passing),
plus the pinned-behaviour tests each section names as updated.

## Part 2 (do first): the parser classifies characters, plus 5.1 `andThen`

Prototype: `/tmp/lw-parser/src` (full diff `snapshots/review-bug-triage-fixes/part2-parser.diff`, generator
`snapshots/review-bug-triage-fixes/part2-unicode-gen.py`, extra tests `snapshots/review-bug-triage-fixes/part2-VariableUnicodeExtraTest.elm`).

### Part 2: the parser classifies characters

#### Root cause
- `Compiler/Parse/Variable.elm` `getUpperWidthHelp` (~473), `getLowerWidthHelp` (~550),
  `getInnerWidthHelp` (~631) treat a unit 0xC0..0xF7 as a UTF-8 lead byte and decode it with
  the next 1-3 units via `chr2/chr3/chr4` (~686-790), read with `P.unsafeIndex` ignoring `end`
  (crash on `é` at end of input). They then call elm/core `Char.isUpper/isLower/isAlpha`, which
  are **ASCII-only**, so even a correct decode could never accept `é`. Plan diagnosis right but
  incomplete: "use the predicates Elm uses" is not possible with elm/core; a Unicode table is
  needed. The module docstring (lines 30-45) documents the bug as behaviour.
- Upstream Elm (`Parse/Variable.hs`) decodes real UTF-8 bytes and uses GHC `Data.Char`:
  first char of upper = `isUpper` (Lu|Lt), of lower = `isLower` (Ll), inner = `isAlpha`
  (Lu|Ll|Lt|Lm|Lo) or ASCII digit/`_`. Non-ASCII digits are NOT inner chars; an Lo letter
  (e.g. CJK) cannot start a name but may continue one.
- Host string model:
  - JS (guida.js): `P.unsafeIndex` = `String.uncons (String.dropLeft i s)`; elm/core's `uncons`
    joins a surrogate pair, so at a high surrogate it returns a Char with code > 0xFFFF, and
    `P.getCharWidth` gives 2. Columns already step 1 per character there.
  - Native eco: Char is ONE UTF-16 unit (`StringOps::uncons`, runtime/src/allocator/StringOps.cpp:1006
    returns `charAt(str,0)` as u16, rest offset +1; `Elm_Kernel_Char_toUpper` ASCII-only). So
    `unsafeIndex` at an astral char yields the lone high surrogate and `getCharWidth` gives 1:
    natively every `col + 1` per `getCharWidth` step counts an astral char as 2 columns (Space
    comments, String/char literals, Shader, Kernel/Docs/Json scanners). Positions stay correct
    (units on both hosts; `String.slice` is unit-based on both), only columns drift.
  - Same source works on both only if surrogate joining is done explicitly by the parser.
- Other `Compiler/Parse/*` sites: no other lead-byte logic (grep 0xC0/0xE0/0xF0 only in
  Variable). Keyword/Pattern/Number/ModuleName consume `getInnerWidth*`; String/Space/Shader
  use `P.getCharWidth` (native column drift above).

#### Fix
1. New module `Compiler/Parse/Unicode.elm` (generated, ~570 lines; script in gen.py):
   `isUpper` (Lu,Lt: 648 ranges), `isLower` (Ll: 656), `isAlpha` (L*: 646), over code points
   >= 0x80, flat `Array Int` of sorted inclusive [lo,hi] pairs + binary search. Surrogates (Cs)
   are in no class. Unicode version: whatever generates it (prototype 14.0 from Python); state it
   in the module doc. (elm-review: add type annotations on the `let` bindings in `search`.)
2. `Primitives.elm`: add and expose
   ```elm
   codePointAt : String -> Int -> Int -> Int -> ( Int, Int )   -- src pos end code -> (cp, width)
   codePointAt src pos end code =
       if code > 0xFFFF then ( code, 2 )                         -- JS: uncons joined the pair
       else if 0xD800 <= code && code <= 0xDBFF && pos + 1 < end then
           let low = Char.toCode (unsafeIndex src (pos + 1)) in
           if 0xDC00 <= low && low <= 0xDFFF then
               ( 0x10000 + (code - 0xD800) * 0x400 + (low - 0xDC00), 2 )   -- native pair
           else ( code, 1 )                                      -- lone high surrogate
       else ( code, 1 )                                          -- BMP or lone low surrogate
   charWidthAt : String -> Int -> Int -> Char -> Int
   charWidthAt src pos end word = Tuple.second (codePointAt src pos end (Char.toCode word))
   ```
   Never reads at or past `end`.
3. `Variable.elm`: `get{Upper,Lower,Inner}WidthHelp` gain an `end` param
   (`src pos end word`). ASCII fast path unchanged; any other code `< 0x80` -> 0; else
   `nonAsciiWidth Unicode.isUpper|isLower|isAlpha src pos end code`
   = `let (cp,w) = P.codePointAt ... in if isClass cp then w else 0`. Delete `chr2/3/4`,
   `unpack`, `import Bitwise`. Callers already advance `col + 1` per char: unchanged.
   Lone surrogates -> width 0 (not an identifier char; e.g. stops the name and becomes a
   parse error / bad end).
4. Call sites for the new `end` arg: `Elm/ModuleName.elm:270` (`chompInner`, `end` in scope);
   `Parse/Number.elm` `isDirtyEnd src pos end word` (4 calls) and `stepHex src pos end word acc`
   (+ its one call in `chompHexHelp`).
5. Native column fix: replace `P.getCharWidth word` with `P.charWidthAt src pos end word` at
   Parse/Space.elm:312,408, Parse/String.elm:150,336,416, Parse/Shader.elm:163,
   Elm/Kernel.elm:306, Elm/Docs.elm:688, Json/Decode.elm:1130, Json/String.elm:108 (all have
   `src pos end` in scope; compiled as-is). Keep `getCharWidth` exported or remove if unused.

#### Also changes
- Docs: Variable module docstring paragraph (lines ~30-45) and doc comments on the three
  `*WidthHelp`/`getInnerWidth` functions; Primitives module doc (`pos`/`end` units paragraph,
  mention `codePointAt`); Number.elm docs naming `getInnerWidthHelp`.
- Tests: `VariableNonAsciiTest` header "EXPECTED TO FAIL" text; add the extra cases (prototype
  file `snapshots/review-bug-triage-fixes/part2-VariableUnicodeExtraTest.elm`, 9 cases): `Été` upper, astral letter
  inner (`x𝒜y`) and first (`𝒜b`), `xÃ$` -> bad end at 1:3, `x𝒜$` -> bad end at 1:3 (one
  column per char), CJK can't start lower but can continue, Greek lower, lone surrogate rejected.
- Remove "EXPECTED TO FAIL" from `test/elm/src/NonAsciiIdentifierTest.elm`.
- No invariant rows touch the parser (checked invariants.csv).
- Note found: `/work/compiler/tests/tests -> /work/compiler/tests` is a self-symlink inside
  the tests dir (breaks a `cp -r` of tests: elm-test-rs "could not guess module name"). Harmless
  via the build-xhr link, but worth deleting.

#### Risks
- Native host: relies on `unsafeIndex` returning a raw unit; handled by `codePointAt` for both
  models. If native ever switches Char to code points, the `code > 0xFFFF` arm covers it.
- Perf: ASCII path is unchanged (one extra arg); table lookup only for non-ASCII (~10 probes).
  `Array` literal of ~1950 Ints per table built once (top-level CAF; on native a const thunk).
- Accepting more identifiers can't break existing valid programs (previously-valid non-ASCII
  names were only the bogus byte-group ones like `Âb`/`xÃ$`, which upstream rejects too).
- Unicode version mismatch vs upstream GHC (8.x, ~Unicode 9-12): only newly assigned letters
  differ; acceptable, document.

#### Validation
- Full elm-test-rs suite on the private copy (both fixes): 59 baseline failures -> 50; diff is
  exactly the 9 targeted tests fixed (VariableNonAscii x3, AndThenConsumed x2, Json decode
  ObjectField/ObjectColon/ArrayEnd x3 — see Part 5.1 — plus none new). Extra test file 9/9 pass.
- Private guida.js built from the copy: `test/elm/src/NonAsciiIdentifierTest.elm` compiles to JS
  (private HOME copy of ~/.eco/~/.elm, packages re-verified OK); self-compile of the whole
  compiler (Terminal/Main.elm, 289 modules) with the private guida.js succeeds.
- NOT validated: native (eco) build — column fix for astral chars and surrogate joining are
  reasoned from StringOps.cpp, not run. Raise by running the E2E `NonAsciiIdentifierTest` and
  a native compile of a file with an astral char in a comment followed by an error (column).

#### Confidence
High for JS; medium-high for native (needs the E2E run above).

### Part 5.1: `Parse/Primitives.andThen` consumed-then-fail

#### Root cause
`compiler/src/Compiler/Parse/Primitives.elm:315-343`: in the `Cok a s` arm the second parser's
result falls through `result -> result`, so its `Eerr` stays `Eerr` and an enclosing `oneOf`
backtracks to the start after input was consumed. Upstream Haskell `Parse.Primitives` bind runs
the continuation with `cok cok cerr cerr` (Eerr promoted to Cerr). Module doc (lines 37-39)
documents the bug as behaviour. Plan diagnosis correct.

#### Fix
```elm
Cok a s ->
    case callback a of
        Parser parserB ->
            case parserB s of
                Cok a_ s_ -> Cok a_ s_
                Eok a_ s_ -> Cok a_ s_
                Cerr r c t -> Cerr r c t
                Eerr r c t -> Cerr r c t
```
Update the module doc paragraph ("`andThen` does so for success only ...") to say `andThen`,
`loop` and `inContext` all promote.

#### Also changes
- Doc text above; remove "EXPECTED TO FAIL" from `PrimitivesAndThenConsumedTest`.
- Fixes three more existing failing unit tests as a side effect (`Compiler/Json/Decode` uses
  these Primitives): "bad field after a comma is ObjectField", "missing colon is ObjectColon at
  the 1", "missing ] is ArrayEnd" — check whether the plan lists them elsewhere and drop the
  duplicate item.
- node `cli-errors` trailing-comma case: verified by hand that `x = [1, 2, ]` now gives
  upstream's "UNFINISHED LIST ... I was expecting to see another list entry after that last
  comma" with the caret on `]` (before: "partway through parsing a list" caret on the `,`).

#### Risks
Any grammar written relying on backtracking after a consumed prefix inside `oneOf` would now
commit. Checked empirically: no regression in the full unit suite (incl. Parse/*Tests,
SourceBuilder, Docs, Json), package re-verification, and a full self-parse/compile of the
compiler. Grammar parity with upstream (which always committed) makes remaining surprises
unlikely; parsers needing backtracking must use explicit `oneOfWithFallback`/lookahead as
upstream does.

#### Validation
Prototype applied; `PrimitivesAndThenConsumedTest` 2/2 pass; full suite no new failures;
self-compile + E2E NonAscii compile with private guida.js OK; trailing-comma message checked.

#### Confidence
High.

## Part 1: Char becomes a 32-bit code point

Prototype: `/tmp/lw-char/src` (compiler), `/tmp/lw-char/root/tests` (tests);
diffs `/tmp/lw-char/compiler-src.diff`, `snapshots/review-bug-triage-fixes/part1-char-compiler-tests.diff`.

### Root cause

- Compiler: `Compiler/AST/MonoAbi.elm:55` `ecoChar = I16`; everything else (Types, Ops,
  Expr, Functions, LogicalTypes, BytesFusion, KernelAbi) takes Char's type from it or from `I16` arms.
  `Expr.decodeCharLiteral` (Expr.elm ~8077-8160) already decodes surrogate escapes to the
  full code point -> `value = 128512 : i16` (ExprAstralCharTest). `Patterns.decodeChrPatternCode`
  (Patterns.elm:1304) folds ALL hex digits of `😀` into one number (0xD83D00DE00).
- Dialect: `Ops.td:212` `def Eco_Char : I<16>`; `eco.char.fromInt` lowering clamps to 0xFFFF
  (EcoToLLVMArith.cpp:909-933); kernel `Elm_Kernel_Char_fromCode` clamps too (CharExports.cpp:11-15),
  all Char kernels mask `& 0xFFFF`.
- Runtime: `ElmChar.value` u16 (Heap.hpp:440-446), `Unboxable.c` u16 (Heap.hpp:248), `allocChar(u16)`
  (HeapHelpers.hpp:360), eval-buffer char slots `uint16_t` / `raw & 0xFFFF`.
- Kernels: String toList/uncons/foldl/foldr/map/filter/any/all iterate UTF-16 units (StringExports.cpp:262-366,
  StringOps.cpp:980-1052, StringOps.hpp:1247-1360).
- Plan diagnosis correct but the invariant list is incomplete (19 rows name `i16`, not 8), and five
  existing elm-core E2E tests + two "expected to pass" E2E tests pin the OLD behaviour (see Tests).

### Fix

Single change set (compiler + dialect + runtime + kernels must land together: kernel/runtime LLVM
declarations are typed by the compiler's MLIR). Ordered:

#### 1. Invariants (`design_docs/invariants.csv`) — every row naming `i16`
REP_ABI_001, REP_SSA_001, REP_BOUNDARY_001 (`11→i16`), REP_BOUNDARY_002 (`i16→11`), REP_BOUNDARY_003,
CGEN_003, CGEN_005, CGEN_015 (rewrite: "maps MChar to i32 (Eco_Char) holding a Unicode scalar/code point 0..0x10FFFF;
Char constants and ops use i32"), CGEN_026, CGEN_034, CGEN_049, CGEN_056, CGEN_058, CGEN_059 ("Char as zext i32"),
CGEN_065 (logical type string), REP_AGG_001 (struct field types), KERN_006, HEAP_035, LSS_011.
Rows naming "11=Char" without width (REP_HEAP_002, REP_CLOSURE_001, MONO_006, CGEN_027, HEAP_019) unchanged.
Add a sentence to REP_HEAP_002: "a kind-11 slot holds the code point zero-extended to 64 bits".
Command to re-check: `grep -n 'i16' design_docs/invariants.csv`.

#### 2. Compiler (VALIDATED in prototype)
- `Compiler/AST/MonoAbi.elm` `ecoChar = I32` (+ doc comments lines 52, 68).
- `Compiler/Generate/MLIR/Types.elm`: `isUnboxable` arm `I16 -> True` → `I32 -> True`; `mlirTypeToKind`
  `I16 -> 3` → `I32 -> 3`; docs lines 18, 131, 269, 288. (`aggSlotTypeString`/`mlirTypeToString` keep both arms.)
- `Expr.elm`: default-value arm (~400) and `mlirTypeToApproxMonoType` (~4700) `I16` → `I32`; docs 368, 643, 1849, 4686.
- `Functions.elm`: placeholder-constant arms (2010, 2114) `I16` → `I32`.
- `LogicalTypes.elm`: `mlirTypeToLogical` `I32 -> LI16` (rename constructor `LChar` optional), wire string `"i16"` → `"i32"`
  (no runtime consumer of the string: `grep -rn '"i16"' runtime/src` empty).
- `Patterns.elm` `decodeChrPatternCode`: replace the fold with `decodeUnicodeEscapeChars` that decodes the first 4 hex
  digits and, if a high surrogate is followed by `\uXXXX`, combines the pair (same formula as `Expr.decodeSurrogatePair`).
  Doc comment line 1281 updated. (Ideally share one helper with Expr's `decodeUnicodeEscape`.)
- `Ops.elm` `arithConstantChar` unchanged (uses `Types.ecoChar`). `Ops.elm:501` text arm unchanged.
- BytesFusion: `Emit.elm:786,1952` docs only; `Reify.elm:2503` `freshVar "i16"` is `bf.read.i16` (Bytes Int), NOT Char — leave.
  `ReadI16`/`LenI16` are Bytes i16 — leave.
- `Patterns.elm:1366` doc `i16 for "chr"` → `i32`.
- Not touched (verified): I32 is also used for ctor tags (`Patterns.elm:245,359,381`) and BytesFusion counters; these never reach
  `isUnboxable`/`mlirTypeToKind`/`mlirTypeToApproxMonoType` (no new failures in 7,124 codegen tests besides checkers hard-coding i16).

#### 3. Dialect + lowering (`runtime/src/codegen`) — unvalidated
- `Ops.td:212` `def Eco_Char : I<32>` (comment "Unicode code point"); doc text lines 34, 257, 290, 591, 758, 1001, 1026,
  1076, 1203, 1305, 1440, 1695, 2728, 2743, 2752, 2842.
- `eco.string.code_unit_at` (Ops.td:1194): no compiler emitter (`grep code_unit_at compiler/src` empty). Retype result as
  `I<32>` named "code unit" (not Eco_Char) or delete op + `eco_string_code_unit_at` + test/codegen/string_code_unit_at.mlir. Recommend delete if unused.
- Introduce one helper `inline bool isEcoCharType(Type t){ return t.isInteger(32); }` in `EcoToLLVMInternal.h` and replace every
  `isInteger(16)` / `getIntegerType(16)` / `IntegerType::get(ctx,16)` / `getI16Type` that means Char in:
  EcoOps.cpp (16: case scrutinee width 16→32 + messages 414-425, slot kind 594-598 & 765-769, CGEN_003 773, papExtend result 880-918),
  EcoControlFlowToSCF.cpp (12: 263-276, 437-445), EcoToLLVMHeap.cpp (30), EcoToLLVMClosures.cpp (33, incl. PK mapping 1350 and the
  eval result-slot load i16→i32), EcoToLLVMValueAgg.cpp (12), EcoToLLVMControlFlow.cpp (15), EcoToLLVMRuntime.cpp (15: `I16_TY`→`I32_TY`
  for eco_alloc_char*/dbg/getters; rename `eco_*_i16` runtime getters to `_char` or `_i32`), EcoToLLVMTypes.cpp (7, aggregate struct field),
  EcoToLLVMArith.cpp (CharToInt zext i32→i64; CharFromInt: `select(ult(code, 0x110000), trunc_i32(code), 0xFFFD)` — Elm semantics),
  EcoToLLVMErrorDebug.cpp:100, EcoListTemplate.cpp:187,659,762, EcoListCursor.cpp (2), EcoPAPSimplify.cpp (3), EcoGCPrepare.cpp (3),
  EcoBackend.cpp (10), RuntimeSymbols.cpp (renamed getters). EXCLUDE `BF/*` and `BFToLLVM.cpp` (bytes i16).
- Audit command: `grep -rn 'isInteger(16)\|IntegerType(16)\|getI16Type\|, *16)\|i16' runtime/src/codegen | grep -v '/BF'` must be empty after.

#### 4. Runtime (`runtime/src/allocator`) — unvalidated
- `Heap.hpp`: `ElmChar { Header; u32 value; u32 padding; }`; `Unboxable.c` → `u32` (size stays 8).
  Comment "Boxed Unicode code point".
- Writers of `.c` must write the whole word: add `inline Unboxable unboxedChar(u32 cp){ Unboxable u; u.i = cp; return u; }`
  (HeapHelpers.hpp:394) and use it everywhere `u.c = x` is written (JsArrayExports 111/140/639/683/764/936, JsonExports 708/1621,
  ListExports 248, HeapHelpers 394) — readers that use `.i`/raw bits for kind 3 then see clean high bits.
- `HeapHelpers.hpp:360` `allocChar(u32)`; `RuntimeExports.cpp` 1484/1825/1835/1966: drop `static_cast<u16>`; 2329-2331, 2382, 2818,
  3032-3037: result slot `uint32_t`; 2552, 2729-2730: `u32` memcpy; 2561, 2753: mask `0xFFFFFFFFu`; getters 4494-4892 return `uint32_t`
  (`RuntimeExports.h` 684-743 too); `eco_dbg_print_char` already int32.
- Debug printing: `print_char(u16)` (3128) → `print_char(u32)` emitting UTF-8 of the code point (Elm prints the char itself);
  3175/3655 casts; `output_format("'%c'")` at 3287/3309/3335/3362 → call `print_char`.
- GC: kind 11 handling is width-agnostic (never traced) — no change; `AllocatorCommon.hpp:477` uses sizeof(ElmChar) (unchanged 16).
- `Scheduler.cpp:964`, `ListOps.cpp:700`: fine once `.c` is u32.

#### 5. Kernels (`elm-kernel-cpp/src`) — unvalidated
Keep `uint64_t c_raw` parameters (statepoint zext note, CharExports.cpp:17-27) and mask `& 0xFFFFFFFFu`; return `uint32_t`.
- `core/CharExports.cpp`: `fromCode`: `code < 0 || code > 0x10FFFF ? 0xFFFD : code` (surrogate codes pass through, as JS);
  `toCode` returns the code point; `toLower/toUpper/toLocale*` on full code point (Char.cpp still ASCII-only — pre-existing divergence).
- `core/UtilsExports.cpp:83,150-170`, `KernelExports.h:226-288`: `*_Char(uint16_t…)` → `uint64_t` + mask (or `uint32_t`);
  `JsArrayExports.cpp:844,849,931`, `ListExports.cpp:299`, `Json wrap_Char` (JsonExports.cpp:1837), `MVar.put` Char variant.
  Find all: `grep -rn '_Char\b\|uint16_t\|u16' elm-kernel-cpp/src | grep -iv 'string\|utf\|bytes\|ctor'`.
- `core/Utils.cpp:115,145,165,262-263,346-347,492,577`: u16 → u32 (compare by code point = Elm's `<` on chars? NOTE: JS compares
  Chars as strings (UTF-16 order); code-point order differs from UTF-16 order only between U+E000..U+FFFF and astral. Choose code-point
  order (consistent with `eco.char.lt` intrinsic which compares the integers) and document the divergence.)
- `core/String.cpp:46-60` `consCellChar/elemChar` → u32; `fromList` (62+) encodes each cp: ≤0xFFFF one unit, else pair; the ASCII
  `acc` gate stays valid (cp ≥ 0x80 forces UTF-16).
- `StringOps.hpp/.cpp`: `fromChar(u32)` (1247), `cons(u32, str)` (1262: encode 1 or 2 units), `toList` (980: iterate code points),
  `uncons` (1006: if unit0 is high and unit1 is low → cp, rest offset 2), `all/any` templates (1343/1355) over code points.
  Add `inline u32 nextCodePoint(const u16* p, size_t len, size_t& i)` and `appendCodePoint(std::vector<u16>&, u32)` helpers.
- `StringExports.cpp:262-366` map/filter/any/all/foldl/foldr: iterate `snapshotChars` by `nextCodePoint`; foldr walks back combining
  a low surrogate with a preceding high; `callCharToCharClosure`/`callCharToBoolClosure`/`callFoldClosure` take/return `uint32_t`;
  map/filter re-encode via `appendCodePoint`; `materializeString` gate unchanged.
- `String.reverse`: keep pairs together (Elm JS `_String_reverse` does).
- `String.cons` export (StringExports.cpp:52): mask 0xFFFFFFFF, encode.
- `parser/ParserExports.cpp:156-177` `isSubChar`: pass `codePoint` (drop `& 0xFFFFu`, fix comment); `-2` for '\n' unchanged.
- regex/json/bytes/http: no Char producers (regex returns Strings; bytes/http 0xFFFF hits are UTF-8/ctor constants). JsonExports
  708/1621 generic slot copies only.

#### String kernel semantics (match elm/core JS)
| function | Elm (JS) with astral | Eco after |
|---|---|---|
| length, slice, left/right/drop*, indexes/indices, split, contains, startsWith | UTF-16 units | unchanged (units) |
| toList, foldl, foldr, map, filter, any, all | one Char per code point (pair combined) | same |
| uncons | pair → one Char, rest drops 2 units | same |
| cons, fromChar, fromList | Char's 1–2 units appended | encode cp ≤0xFFFF as 1 unit, else pair |
| reverse | pairs kept in order | same |
| Char.toCode / fromCode | full cp; fromCode out of 0..0x10FFFF → U+FFFD | same (kernel + `eco.char.fromInt` lowering) |
| Char.toUpper/toLower | full Unicode | ASCII-only (pre-existing, out of scope) |
| lone surrogate | JS glues a high with ANY next unit (foldl) / low with ANY prev (foldr) | combine ONLY valid high+low; a lone surrogate is a Char of its unit value — keeps `fromList (toList s) == s` (documented divergence) |
| String.toUpper/toLower/trim/words/lines | units / JS | unchanged |

### Also changes

- Docs: `design_docs/theory/value-representation.md` (Char = code point in i32; String UTF-16; conversion in String kernels),
  `design_docs/theory/backend/eco-dialect.md`, `design_docs/theory/runtime/data-structures.md`, `runtime.md`,
  `design_docs/theory/compiler/mlir-generation.md`, `THEORY.md`, `design_docs/kernel-boundary/audit-01-basics-bitwise-char-utils.md`
  (grep `i16\|UTF-16 code unit\|Char is` in each).
- Compiler test checkers that hard-code i16 (prototype: blanket `I16→I32`/`"i16"→"i32"` then restore the string-helper `I16` arm —
  do by hand in the real change): TestLogic/Generate/CodeGen/{BooleanConstants, KernelDeclAbiPolicy, BoxingValidation, CaseScrutineeType,
  PapExtendResult, PapExtendSaturatedResultType, UnboxedBitmap, ProjectionContainerType, EcoUnboxSanity, CharTypeMapping, SsaTypeConsistency,
  ConstructResultType, OperandTypeConsistency, DestructorTypeProjection, PartialApplicationRouting, CallAbiConsistency, CaseKindScrutinee,
  JumpTarget, Invariants}.elm and `Compiler/Generate/MLIR/KernelAbiTest.elm` (test names "…with i16 ABI").
- Strengthen `ExprAstralCharTest`/`PatternsAstralCharTest`: with i32 Char the "no out-of-range i16 constant" check is vacuous; add
  "MLIR contains `value = 128512 : i32`" (prototyped) and rename "fits its i16 constant" → "is its code point"; drop "EXPECTED TO FAIL".
- E2E flips (test/elm/src): `CharAstralCodeTest` → emoji 128512, clef 119070 (+ add `fromCode -1`/`0x110000` → 65533);
  `AstralCharLiteralTest` → `astral: 128512` (doc says clamp — rewrite); `AstralCharCasePatternTest` CHECKs stay
  (`clamped: "grin"` still right since fromCode 0x1F600 == literal) but rename/redoc ("clamped" → "fromCode").
- E2E flips (test/elm-core/src): StringAstralFoldTest → 1/3/3; StringAstralMapTest → map_const_len 3; StringAstralToListFromListTest →
  tolist_len 3; StringAstralUnconsTest → 128512 / rest_len 1; StringAstralReverseTest stays True but add `String.reverse "a😀b" == "b😀a"`.
  StringAstralLengthTest unchanged (units). Update their "G1/E*" docs. The plan's "expected to pass" list must include these.
- New E2E (plan item 5): toList "a😀b" length 3 with emoji intact; toCode/fromCode round trip 0x1F600/0x10FFFF; fromList re-encode;
  astral Char unboxed in record, tuple, closure capture, list head, custom field, Array (JsArray push/set), Debug.log of an astral Char
  (prints `'😀'`), `Parser.chompIf` on an emoji, String.foldr/any/all/filter with astral, lone-surrogate round trip.
- test/codegen/*.mlir using i16 as Char (35 files): box_char_unicode, char_roundtrip, char_fromInt (new FFFD semantics), char_toInt,
  unbox_char, construct_tuple2_char, expect_unboxed_char, wrapper_primitive_return_char, dbg_*, eco-case-scrutinee-{invalid-chr,types},
  pap_slot_kinds_verify, papcreate_kinds_20_21, wide_* (+ `gen_wide_fixtures.py`), construct_*, project_fields, box_unbox*,
  unbox_roundtrip, joinpoint_mixed_arg_types, order_from_sign, compare_case_rewrite_jit, eval_desc_sat_sizes, sd4_tuple3…,
  verify_constants_boxed, expect_unboxed_passthrough, string_code_unit_at. CHECK `project_unboxed_i32.mlir` — it may pin i32 as
  NOT-Char (would now be kind 3). test/bf-codegen untouched.
- C++ unit tests using u16 Char: test/kernel/KernelExportsTest.cpp, test/allocator/{AllocatorCommonTest, HeapGenerators, HeapHelpersTest,
  HPointerLayoutTest, ParallelMinorTest, RegionMinorTest, WideClosureTest, EcoApplyClosureEvalChainTest, AllocatorTest, RuntimeExportsTest,
  Utf8StringTest, EcoApplyClosureTypedTest, GCPressureTest, StringOpsTest}.cpp, HeapSnapshot.hpp.
- `compiler/src/Compiler/MonoSolver/KernelSetFacts.elm` evidence strings cite line numbers of edited kernels (re-audit line cites if a
  checker enforces them).

### Risks

- ABI ordering / bootstrap: old stage-0 native compiler emits i16 Char MLIR, which the new dialect rejects. Bootstrap order:
  (1) old native eco (+ its OLD runtime/backend, e.g. a kept `eco-opt-prev`/snapshot toolchain) compiles the NEW compiler source →
  stage-1 (emits i32, runs on old runtime; compiler sources contain no astral chars — `grep -P '[\x{10000}-\x{10FFFF}]' compiler/src` empty,
  only an escaped `"\\u{1F60A}"` string in Reporting/Error/Syntax.elm — so stage-1's old Char semantics are harmless);
  (2) stage-1 + NEW backend/kernels → stage-2; (3) stage-2 → stage-3; gate B==C. Alternatively stage 0 = JS-hosted compiler rebuilt
  from new source (no dialect involved) if it does not OOM. ~/.eco package artifacts and kernel copy must be wiped (memory: E2E stale caches)
  because cached .mlir/typed artifacts carry i16.
- i32 now means Char wherever a classifier sees it: ctor tags (`eco.get_tag` i32) and BF counters are i32. They never feed construct/box/
  papCreate today (checkers green), but add a verifier note; `isEcoCharType` must not be applied inside BF lowering.
- Perf: `toList/foldl/map` gain a surrogate test per unit (branch-predictable); ASCII/UTF-8 fast paths (`utf8Bytes`) can skip it
  (bytes < 0x80 never surrogates). String.fromList ASCII gate unchanged. Expect FLAT; measure on the bootstrap wall.
- Unboxable.c widening: any writer of `.c` that does not clear bits 32..63 leaks garbage into raw-`.i` readers (eval buffer, hashing) —
  hence the `unboxedChar` helper rule and auditing `grep -rn '\.c = '`.
- Char ordering: `eco.char.lt` and `Utils_lt_Char` compare code points; JS compares UTF-16 strings. Differs only for astral vs U+E000..U+FFFF.
- Debug output of non-ASCII chars changes (UTF-8 instead of `%c` truncation): E2E CHECK lines with chars could change; grep `CHECK:.*'`.

### Validation

- Compiler: prototype in `/tmp/lw-char`. `ExprAstralCharTest` + `PatternsAstralCharTest` (strengthened to require
  `value = 128512 : i32`) PASS (2/2). Neighbours: all `tests/Compiler/Generate/MLIR/**` + 59 `TestLogic/Generate/CodeGen/*Test.elm`:
  7,104 pass / 20 fail before checker updates — all 20 are checkers/KernelAbiTest hard-coding i16 (CaseKindScrutinee, CaseScrutineeType,
  BoxingValidation ×4, PapExtendResult, UnboxedBitmap ×4, KernelAbiTest ×2, CharTypeMapping ×5…); after updating checkers the affected
  suites pass 850/850. Generated code is internally consistent (no kind/type mismatch reported beyond the hard-coded width).
- Full elm-tests suite not run; JS compiler / E2E / C++ not built (rules). Dialect, runtime, kernels: design only, UNVALIDATED.

### Confidence

- Compiler side: high (validated). Kernel String semantics: high (matches elm/core JS, table above). Dialect/runtime/kernel sweep:
  medium — mechanical but wide (≈230 sites); raise by: building with `-Wconversion` on the touched files, the codegen lit suite,
  the new E2E set, a stress run with astral-heavy strings under ECO_HEAP_VALIDATE, and the B==C bootstrap gate.

## Part 3a: monomorphization (items 3.1, 3.2, 3.5)

Prototype tree: `/tmp/lw-mono-a/src` (full diff against /work: `snapshots/review-bug-triage-fixes/part3-mono-a.diff`).
Probe tests: `snapshots/review-bug-triage-fixes/part3-mono-a-tests/{MonoATest,VariantsTest}.elm` (module `TestLogic.Lw.*`).
Default engine is `EngineSolver` (`Compiler/Eco/Config.elm:541`), so `Compiler/MonoSolver/Translate.elm` is the
path the E2E tests take. `Compiler/Monomorphize/Specialize.elm` is the subst engine.

Regression run (full elm-test-rs suite, private root, patched): 14,441 passed / 58 failed. The 58 failures are a
strict subset of the unpatched failures; the only change is that `NestedUnboxDestructTypeTest` "solver engine
(default)" now passes. The other 58 are tests other plan items pin.

---

### 3.1 Multi-parameter Holey aliases

#### Root cause
`Compiler/Monomorphize/Analysis.elm:516-545` (`convertCanTypeNameToMVarId`, `TAlias` arm) gives every alias formal
`TypeIds.firstMVarId`, both in `innerNameToId` and as the `paramId` of each `(paramId, argType)` pair.
`TypeSubst.applySubstPureI`'s Holey arm (`TypeSubst.elm:965`) and `Zonk.canTypeToMonoWithI` (`Zonk.elm:179`) insert
each arg under its `paramId`, so the last argument wins. Probed: `Box (Pair Int Float)` gives ctor shape
`(Float, Float)` and `RBox (Rec Int Float)` gives `{first: Float, second: Float}`. Both engines get it wrong, because
the bug is in the ctor-shape table (`computeCtorShapesForGraph`, called from `Prune.elm:331`).

The plan's diagnosis needs one correction. The Holey arms of Zonk and TypeSubst are already correct: they substitute
by `paramId`. Only Analysis mints the colliding ids. `AssignMVarIds.elm:1366` mints a distinct id per formal
(`ensureBinder`), so ordinary annotations are not affected.

#### Fix
Change only `Analysis.convertCanTypeNameToMVarId`'s `TAlias` arm. Mint one id per formal by position
(`firstMVarId`, `Id.succ` …):
```elm
formalIds = args |> foldl (\(n,_) (acc,next) -> ((n,next)::acc, Id.succ next)) ([], TypeIds.firstMVarId) |> first |> reverse
innerNameToId = foldl (\(n,pid) acc -> Dict.insert n pid acc) nameToId formalIds
Can.TAlias canonical name (List.map2 (\(_,pid) (_,t) -> (pid, convertCanTypeNameToMVarId nameToId t)) formalIds args) ...
```
Positional ids may overlap the union's own var ids (also 0..). That is safe for two reasons. First, an alias body
mentions only its own formals. Second, both Holey arms evaluate the args under the *outer* subst (the fold reads
`subst`, not the accumulator), and nested aliases do the same.
Update the doc comment at Analysis.elm:477-484 ("every one of them … gets the same id").

#### Also changes
Nothing else. No invariant row names this. MONO_013 (ctor layouts match fields) is the invariant this bug broke.

#### Risks
Only ctor shapes for constructors whose fields use multi-parameter aliases change, and those were wrong before.
Single-parameter aliases produce the same output as before. There is no hot path: the code runs once per custom
type in the graph.

#### Validation
Probe `MonoATest` "holey shapes", on both the solver and the subst engine: `Box: [MTuple [MInt,MFloat]]`,
`RBox: [MRecord {first: MInt, second: MFloat}]`. The full suite shows no regressions. The E2E
`HoleyAliasTwoParamsTest` was not run (needs a cmake rebuild plus the shared runtime, which the rules forbid).

#### Confidence
High. An E2E run of `HoleyAliasTwoParamsTest` would raise it. The test includes a `GBox x y` case that crosses
parameters (`Pair x y`, `Rec y x`), which the fix handles because the args are converted with the outer `nameToId`.

---

### 3.2 Non-tail-recursive local function used at two types

#### Root cause
- **Solver engine (DEFAULT):** `Compiler/MonoSolver/Translate.elm` `buildLocalDefs` (~6372-6393), called from
  `translateLocalMultiLet` (~5797). Each instance is re-translated by `retranslateAtInstance` *after*
  `Engine.popLocalMulti`. A self-reference inside the right-hand side therefore comes out as
  `MonoVarLocal "sumL" <Float fn type>`: the right type, but the bare name, which is the Int instance. The tail-def
  path already applies `renameSelfReferences` (Translate.elm:4692); the `MonoDef` path does not.
- **Subst engine:** `Specialize.renameMonoDef` (Specialize.elm:5405) renames only `MonoTailDef`, as the plan says.

Probed: `sumL$1 -> sumL:…` in both engines.

#### Fix
1. Move `renameSelfReferences` (Translate.elm:4760-4818) to `Compiler/Monomorphize/MonoTraverse.elm` as
   `renameLocal : String -> String -> MonoExpr -> MonoExpr`, unchanged. It renames `MonoVarLocal`, `MonoTailCall`
   and closure captures bottom-up via `mapExpr`. Expose it and add it to `@docs`.
2. In Translate, replace the two uses with `MonoTraverse.renameLocal`:
   - line 4692 (tail def, unchanged behaviour);
   - in `buildLocalDefs`, `Mono.MonoDef inst.freshName (MonoTraverse.renameLocal name inst.freshName e)`.
3. In Specialize, change `renameMonoDef`'s `MonoDef oldName expr` arm to
   `Mono.MonoDef newName (Traverse.renameLocal oldName newName expr)`.
   The `MonoTailDef` arm can stay as is, since `renameTailCalls` covers tail calls. A non-tail self-reference
   inside a tail def is a separate, unprobed gap in the subst engine. Option: switch that arm to `renameLocal` too.

#### Also changes
None required. CGEN_056 is the invariant the bug violates. MONO_011 (hygiene) holds after the fix.

#### Risks
- **Polymorphic recursion:** an annotated local calling itself at another type would be renamed to its own instance
  and get a wrong name. The existing tail-def path makes the same assumption, and the old behaviour was wrong in
  that case too. Elm forbids shadowing, so name matching is exact.
- **Instance 0:** `renameLocal` with `old == new` is the identity (early return).
- **LSS:** `flushLocalMultiEnrich` runs after `buildLocalDefs` and matches uses by name. The group's own uses
  inside its right-hand sides are explicitly not overlaid (doc ~5853), so the renamed self-uses are unaffected.
- **Cost:** one extra `mapExpr` per non-first instance, which is negligible.

#### Validation
Probe `MonoATest` "local rec" (solver) and "subst local rec": `sumL$1 -> sumL$1:…` in both engines. The full suite
shows no regressions. The E2E `LocalMultiNonTailRecTest` was not run.

#### Confidence
High. An E2E run would raise it. Suggested pinning unit test: assert that every `MonoVarLocal` beginning with `sumL`
inside `MonoDef "sumL$1"` is named `sumL$1`.

---

### 3.5 Nested constructor destructure of a `number` value

#### Root cause (plan diagnosis is wrong)
Typed-optimizer output is as designed. The `_v0 = o` root carries `o`'s scheme type `Outer number`. The `y`
destructor has `number1`, which is generalized because Elm generalizes let-destructure bindings. The solver handles
a destructured number name per use: `Translate.elm` ~5180-5245, `buildRefinedDestructorWith` →
`refineRootInstance`. For each recorded use type, `refineRootInstance` rebuilds a root instance (`_v0$vk`) with the
destructured slot set to that type.

The navigation helpers support a constructor field only when its declared type is a **bare type parameter**:
- `customSlot`, `unboxSlot` (navigate);
- `replaceCustomSlot`, `replaceUnboxSlot` (replace).

`Outer a = Outer (Inner a)` has field type `Inner a`, so `refineRootInstance` returns `Nothing`. No Float instance is
built, and `y` keeps the eager Int.

Single-level unbox and tuple destructures already work (probed). The bug also hits:
- the direct form `(Outer (Inner y)) = Outer (Inner 1)`;
- `Two (Inner a) Int` (Normal ctor, `HintCustom` path);
- `y = case o of Outer (Inner z) -> z`, whose Float copy had `path MInt, destructor MFloat`.

#### Fix (Translate.elm only, plus one Analysis helper)
1. **`Analysis.instantiateCtorField : List Name -> List Mono.MonoType -> Can.Type Name -> Mono.MonoType`** (new,
   exposed). It gives the declared field type with the union params substituted by `typeArgs`: fresh ids per var,
   then `convertCanTypeNameToMVarId` and `TypeSubst.applySubstPure`, the same as `buildCompleteCtorShapes`.
2. **`customSlot` / `unboxSlot`:** return `Analysis.instantiateCtorField unionData.vars typeArgs fieldCanType` for any
   field type, instead of requiring `Can.TVar`.
3. **`replaceCustomSlot` / `replaceUnboxSlot`:** call
   `rebindTypeArgs home typeName unionData.vars typeArgs fieldCanType leaf`, where:
   - `rebindTypeArgs` runs `matchParams fieldCanType leaf Dict.empty`, then
     `mCustom home typeName (map2 (\v t -> Dict.get v bound |> withDefault t) vars typeArgs)`.
   - `matchParams : Can.Type Name -> MonoType -> Dict Name MonoType -> Maybe (Dict …)` is a structural match:
     - `TVar` binds; a conflicting rebinding gives `Nothing`.
     - `TType` vs `MCustom` zips the args; `TType [a]` vs `MList` matches `a`; `TType []` matches anything.
     - `TTuple` vs `MTuple`, and `TRecord` vs `MRecord` field by field.
     - `TLambda` binds nothing.
     - A `Filled` alias matches through its body.
     - A `Holey` alias matches its body into its formals, then matches each arg against its formal's binding.
     - Any other shape mismatch gives `Nothing`.

   The prototype code is in the diff (`rebindTypeArgs`, `matchParams`).
4. Update the doc comments of the four helpers and `refineRootInstance`, which say "bare type parameter".

#### Also changes
- Rewrite the docstring of `NestedUnboxDestructTypeTest` (it blames the typed optimizer) and remove its
  "EXPECTED TO FAIL" note.
- Correct the E2E test's header too.
- MONO_026 (Unbox wrapper type) and MONO_029 (layout connectivity) are now satisfied for these paths. No row edit is
  needed.

#### Risks
- `matchParams` returns `Nothing` in the same places the old code did (unmatched shapes), so the fallback (no
  refined instance, eager type) is unchanged.
- A `TLambda` field never rebinds params, which is conservative.
- The subst engine is NOT fixed by this. Its nested destructure gives `y$v1: path MInt, destructor MFloat` (probed,
  unpatched as well). It is not on the default path; list it as a follow-up if the subst engine must stay a valid
  diff twin.
- **Cost:** only on destructured number-multi names, so it is cold.

#### Validation
- `TestLogic/Monomorphize/NestedUnboxDestructTypeTest` now passes.
- Probe `VariantsTest` (solver): nested, nestedDirect, single, tuple and normal all give `MFloat`/`MFloat`. The case
  variant's Float copy now reads `o$v1 : Outer Float` with `z : MFloat` (it was a path/destructor mismatch before).
  The remaining `MInt` `z` is the consistent, unused eager Int copy.
- The full suite shows no regressions.
- The E2E `NestedUnboxLetDestructFloatTest` was not run.

#### Confidence
Medium-high. These would raise it:
- the E2E run, which checks the `Elm_Kernel_Basics_add_Float` signature crash is gone;
- adding the nested-Normal (`Two (Inner a) Int`) and case variants as unit cases;
- deciding whether the subst engine needs the same treatment.

---

#### E2E / rebuild note
`guida.js` is built by `elm make` in `build/compiler/build-xhr` (compiler/CMakeLists.txt:140-177), but the E2E
programs also need the native backend and runtime from the shared build. Under the brief's rules, none of the three
E2E programs was run.

## Part 3b: typed optimizer and entry/accessor passes (items 3.3, 3.4, 3.6, 3.7, 3.8)

Prototype: `/tmp/lw-mono-b/src` (full patch: `snapshots/review-bug-triage-fixes/part3-mono-b.diff`, 9 files). It is the source for every "Validation" below.
Gates run on the prototype:
- Full elm-test-rs suite on prototype vs pristine `/work/compiler/src` (same harness, `--fuzz 1`): 14,445/54 vs 14,440/59.
  `diff` of the `✗` lists = exactly the 5 target tests fixed, **0 new failures** (the 54 remaining failures are pre-existing other-item regressions).
- Stage-1 `guida.js` rebuilt from the copy (`elm make` in the shadow root + `scripts/replacements.js`, ~25 s), then the 6 E2E tests compiled with
  `GUIDA_JS_PATH=... node compiler/bin/index.js make` in a private copy of `test/elm`. They could not be **run**: `ecoc --emit=jit` has no runtime
  symbols, and the test binary is off-limits. So the MLIR was checked by hand (`ecoc --emit=mlir`), and the old `guida.js` was compared on the same inputs.

---

### Item 3: annotated `let rec` stores the result type

#### Root cause
Confirmed. `Compiler/LocalOpt/Typed/Expression.elm:1292` (`optimizePotentialTailCallDef`, `Can.TypedDef` arm) passes the TypedDef's last field
to `optimizePotentialTailCall` as `defType`. In Can that field is the **result** type (annotation minus args), so `TailDef`/`Def` get typed
`Int` instead of `Int -> Int -> Int`. The `Def` arm and `getDefNameAndType` (l.1123) already rebuild the full type.

#### Fix
```elm
Can.TypedDef (A.At region name) _ typedArgs body _ ->
    let
        ( _, defType ) =
            getDefNameAndType exprTypes def
        ...
```
`getDefNameAndType` gives `buildFunctionType (map second typedArgs) resultType`. This is the only call site of the arm, and it serves both
`optimize` (l.657) and `optimizeTail` (l.983), so both are fixed.

#### Also changes
Nothing else. `optimizePotentialTailCall` already peels `length args` off `defType` to get `bodyType`. Before, that peeled the wrong type.

#### Risks
Low. This is the type the `Def` arm already produces. Downstream code that worked around the bad type: none found (the E2E failures show it was simply wrong).

#### Validation
Unit `Compiler/LocalOpt/Typed/ExpressionTest`: 2/2 fail before, pass after. Full suite: no regressions.
E2E with old guida.js: `AnnotatedLetRecPolyTailTest` emits invalid MLIR (`ecoc`: CGEN_003 papExtend i64 vs !eco.value). `AnnotatedLetRecFnResultTest`
**segfaults the compiler** (rc 139). With the fix, both compile and both `.mlir` files parse and verify under `ecoc --emit=mlir`. Not run.

#### Confidence
High. To raise it further: run the two E2E tests under `full`.

---

### Item 4: NormalizeLambdaBoundaries renaming and VarDebug

#### Root cause
Confirmed, three defects in `Compiler/LocalOpt/Typed/NormalizeLambdaBoundaries.elm`:
1. `extractAndUnifyBranchParams` (l.885) starts every case boundary at `emptyRenameCtx`, so nested boundaries both mint `a_hl_0`. The
   bottom-up order (inner first) then lets the outer rename `b -> a_hl_0` land under the inner merged lambda's own `a_hl_0` parameter, which
   captures it. This is the actual capture in `LambdaBoundaryCaptureTest`: `a + b` becomes `100 + 100`.
2. `renameExpr` does not stop at binders (lambda params, let/TailDef names, destructor names).
3. `renameExpr` renames `VarDebug` (l.199, the Debug **function** name, e.g. `log`) and `VarCycle` (a global). `log -> log_hl_0` gives
   `@Elm_Kernel_Debug_log_hl_0`, a stub kernel returning `Empty`.

Note: defect 2 alone does **not** fix the capture test. Defect 1 (the shared supply) is what fixes it. Both are needed for soundness.

#### Fix
- **One supply per graph node.** `normalizeExpr`, `normalizeDef`, `normalizeDeciderExpr` and `normalizeChoiceExpr` become
  `... -> RenameCtx -> ( result, RenameCtx )`, threaded left to right with a `mapCtx` helper (plus `normMap` for the `Data.Map` field maps,
  rebuilt with `Data.Map.fromList A.toValue`).
  - `normalizeNode` starts each `Define`, `TrackedDefine` or `Port*` node at `emptyRenameCtx`. A `Cycle` threads one ctx through all of its
    values and then all of its functions.
  - `normalizeLambdaBodyFixpoint`, `tryNormalizeCaseBoundary` and `extractAndUnifyBranchParams` take the ctx and return the advanced one, replacing
    `emptyRenameCtx` at l.885. (Inside its fold, rename the lambda's ctx binder, e.g. `c0`, to avoid Elm shadowing.)
- **`renameExpr` is capture-aware and leaves globals alone:**
  - `VarDebug` and `VarCycle` keep their name.
  - `Function`/`TrackedFunction`: rename the body with `removeNames params env`.
  - `Let def body`: `renameDef env def`, then the body with `removeNames [defName def] env`.
  - `TOpt.Def`: keep the binder name and rename only the bound expression (no more renaming of binders).
  - `TailDef`: rename the body with `removeNames (name :: params) env`.
  - `Destruct (Destructor n path _) body`: rename the path root with `env` and the body with `env` minus `n`. `renameDestructor` keeps `n`.
  - New helpers: `defName`, and `removeNames names env = List.foldl Dict.remove env names`.
- Update the module docstring and the `renameExpr` docstring ("binder does not stop the renaming" is now false; uniqueness is now per node).

#### Also changes
Only this module (the exposed API `normalizeLocalGraph` is unchanged). No invariant row names this pass.

#### Risks
- Fresh names are now `x_hl_N` with N growing per node rather than restarting, so they are textually different from before. Nothing keys on
  the `_hl_0` spelling: no test or grep hit besides the two regression tests.
- A source identifier that literally contains `_hl_<n>` could still collide. This was pre-existing and is now narrower. To close it, have the
  supply skip names free in the body.
- Cost: one extra tuple per node visited. This pass is small next to mono, so I expect no measurable effect (not timed).

#### Validation
Unit `NormalizeLambdaBoundariesTest` and `NormalizeLambdaBoundariesDebugNameTest` fail before and pass after. Full suite: no regressions.
E2E MLIR diff against the old guida.js:
- `LambdaBoundaryCaptureTest`: `eco.int.add %c100, %c100` becomes `eco.int.add %c100, %arg2` (b).
- `DebugLogLambdaBoundaryTest`: the call to the bogus `@Elm_Kernel_Debug_log_hl_0` (and its stub func) becomes the real `eco.dbg %2, %arg1`, which yields the argument.

Not run.

#### Confidence
High.

---

### Item 6: EntryPrep picks the entry `main` by name

#### Root cause
Confirmed. `Compiler/Monomorphize/EntryPrep.elm` `insertFlagsDecoderNode` (~l.110) and `findEntryPointId` (~l.185) take the first `Define` named
`main` in graph key order across all modules. `Builder/Generate.buildMonoGraphFromMerged` (l.852) calls `Steps.prepare` with no root
information. In the old compiler's MLIR the entry is `@EntryAuxWithMain_main_$_0` ("helper").

#### Fix
- `EntryPrep`:
  - `Assigned` gains `entryHome : Maybe ModuleName.Canonical`.
  - New exposed `assignIn : (Bool,Bool) -> Maybe ModuleName.Canonical -> Name -> TOpt.GlobalGraph Name -> Assigned`. `assign flags = assignIn flags Nothing`, so test callers keep compiling.
  - `findEntryPointId : Maybe ModuleName.Canonical -> Name -> DMap.Dict String TOpt.Global (TOpt.Node id) -> Maybe (Global, Can.Type id)`:
    with `Just home` it does an exact `findNodeAnnotationType (Global home name)`; with `Nothing` it keeps the old scan. It becomes polymorphic in `id`, and so does `findNodeAnnotationType`.
  - `insertFlagsDecoderNode entryHome name graph` uses `findEntryPointId` (removes the duplicate scan), then `insertDecoderFor home tipe graph` (the old body).
- Callers: `Monomorphize/Monomorphize.elm:112` and `MonoSolver/Monomorphize.elm:147` pass `assigned.entryHome`. MonoDiff goes through these two.
- `Pipeline/Steps.elm`: add `prepareRoot ecoConfig rootHome graph = EntryPrep.assignIn (assignFlagsFor ecoConfig) (Just rootHome) "main" graph`, exposed and documented (and import `Compiler.Elm.ModuleName`). `prepare`/`prepareEntry` are unchanged (used by TestPipeline and PackageCompilation).
- `Builder/Generate.elm`: `buildMonoGraphFromMerged` takes `pkg` (`artifacts.pkg` at l.808) and calls
  `Steps.prepareRoot ecoConfig (ModuleName.Canonical pkg (rootModuleName (firstRoot roots)))`. It adds the helpers `firstRoot` (pattern on
  `NE.Nonempty first _`; `NE` has no `head`) and `rootModuleName` (`Inside n` / `Outside n ...`). This is the same `pkg` + root-name keying as the JS
  path's `gatherMains`/`lookupMain`.

#### Also changes
- Docstrings in EntryPrep (module, `assign`, `findEntryPointId`) and MonoSolver l.125.
- PORT_007 already says "the entry's annotation". No row change is needed, though a clause such as "entry = root module's main" could be added
  to PORT_007 or a MONO row if wanted.

#### Risks
- Multi-root `eco make A.elm B.elm` to native: this uses the first root. Before, it used the first `main` anywhere, so this is no worse.
- A root without `main` that imports a module with `main` now fails with "No main function found" instead of silently compiling the wrong
  program. That is intended.
- Bootstrap/self-compile: the compiler's root `Terminal.Main` is in the project pkg. Inside roots are keyed with `artifacts.pkg`, as on the JS
  path. Not bootstrapped. Check with the `full` + eco-boot gates.

#### Validation
Full suite: no regressions (no unit test covers this).
E2E `EntryMainOfRootModuleTest` with the new guida.js: the MLIR entry is `@EntryMainOfRootModuleTest_main_$_0` with string literals "which"/"root";
the old one gives `@EntryAuxWithMain_main_$_0`/"helper". Not run.

#### Confidence
High for the fix. Medium-high for the Generate wiring until a bootstrap/self-compile confirms the root keying.

---

### Item 7: ResolveAccessorValues and accessors in lists

#### Root cause
Confirmed, but the diagnosis is broader than the plan says. It is not about "elements after the first". `rewriteExpr` passes
`maybeExpected = Nothing` for **every** list element, call argument, record-update value and capture
(`Compiler/Monomorphize/ResolveAccessorValues.elm`, the MonoList/MonoCall/MonoRecordUpdate/MonoClosure arms). A function-field accessor is
always deferred (`accessorTypeNeedsDefer`), so `MonoAccessorValue` survives and `Generate.MLIR.Expr` crashes. The old guida.js throws on
`AccessorFunctionFieldInListTest` (rc 1).

#### Fix
In `rewriteExpr`:
- `MonoList _ items t`: expected type for each item = `elemType` from `MList _ elemType` (`MList` has 2 fields).
- `MonoCall`: argument `i` gets the expected type `paramTypes (List.length args) (Mono.typeOf funcExpr1)`, using
  `zip expected args`. The new helper `paramTypes count ty` reads the params of `MFunction _ _ params result` through the stages
  (pre-staging types are curried) and returns `Nothing` past the known ones.
- `MonoRecordUpdate _ updates (MRecord _ ft)`: value `n` gets the expected type `Dict.get n ft`.
- Captures stay `Nothing`: the capture triple's third field is a `Bool`, not a type. Tail-call args are unchanged.

An expected type such as `Ops -> (Int -> Int)` then matches `maybeAccessorSigFromExpected` (one record param, MVar-free), and the placeholder becomes
`\record -> record.op`.

#### Also changes
Update the module docstring's sentence "Many positions are rewritten with no expected type at all, among them call arguments, list elements,
record update values ..." to name only captures and tail-call args. MONO_015 (accessor as argument) is unaffected and only strengthened.

#### Risks
More placeholders now become closures: one new `AnonymousLambda` id each from the existing counter, which is already threaded. Where the
expected type has MVars or is not a single-record function, it is still left as before, so there is no new crash surface. Call args on an
accessor callee are rewritten before the `VI_Accessor` direct-access path, which ignores the argument rewrite result shape. Fine.

#### Validation
Full suite: no regressions. E2E `AccessorFunctionFieldInListTest`: old compiler crashes; new one compiles and produces 190 lines of valid MLIR
(`ecoc --emit=mlir` ok). Not run, so `[11,20]` is not verified.

#### Confidence
Medium-high. To raise it: run the E2E. Also possibly add a call-argument and record-update variant, for example `List.map .op` with a
function field, and `{ r | f = .op }`.

---

### Item 8: erased mutually recursive let loses its tail call

#### Root cause
The plan's diagnosis is **wrong**: it is not "tail-call detection per member". In `Compiler/LocalOpt/Erased/Expression.elm` `optimizeTail`, the
`Can.LetRec` arm with 2+ defs folds `optimizeDef` around `optimize cycle body` (~l.709) instead of `optimizeTail cycle rootName argNames body`.
So the **enclosing** function's self-call in the let body loses `TailCall`. The members of a mutual group are correctly plain `Def`s; this matches
stock Elm and the typed twin (`Typed/Expression.elm:997` uses `optimizeTail`).

#### Fix
In that arm, replace `(optimize cycle body)` with `(optimizeTail cycle rootName argNames body)`. The `optimize` LetRec arm is unchanged
(not tail context).

#### Also changes
Plan text for item 8 should be corrected to this. Nothing else.

#### Risks
None found. This is the same shape as the single-def arm and the typed twin. JS output for such functions now loops instead of recursing,
which is intended.

#### Validation
Unit `Compiler/LocalOpt/Erased/ExpressionTest`: the mutual case fails before and passes after; the control passes both. Full suite: no regressions.

#### Confidence
High.

## Part 4: decision trees, literals and MLIR encoding

Prototype: `/tmp/lw-literals/src` (full diff: `snapshots/review-bug-triage-fixes/part4-literals.diff`, 12 files, all Elm).
Shadow root: `/tmp/lw-literals/root`; extra private tests: `snapshots/review-bug-triage-fixes/part4-LiteralsTest.elm` (32 cases).
Private JS-hosted compiler built from the copy: `/tmp/lw-literals/guida.js` (`elm make src/Terminal/Main.elm` + `scripts/replacements.js`, about 5 min).

Full elm-test suite on the prototype: 14,486 pass, 45 fail. All 15 target tests pass. The one new failure,
`Parse.StringTests` `\u{FFFF}`, pins the old bug and must be updated (item 7). The remaining failures are in
Parts 2, 3, 5 and 6 (none in a touched module).

---

### Item 1: Char/String case keys by decoded value

#### Root cause
- `Compiler/AST/DecisionTree/Test.elm:120-124`: `testToComparable` keys `IsChr c` as `"H" ++ c` and `IsStr s` as `"S" ++ s`, using the escaped text.
- `Compiler/LocalOpt/{Typed,Erased}/DecisionTree.elm` `toRelevantBranch` (Typed ~577/589, Erased ~534/546) compare `chr == testChr` / `str == testStr` by text.
- Result: `'a'` and `'\u{0061}'` (text `a`) become two tests, and `eco.case` gets duplicate tag 97.
- The plan's diagnosis is correct. `Nitpick.PatternMatches` also compares by text. Leave it alone: making it value-aware would turn the second pattern into a REDUNDANT PATTERN *error*. The E2E test expects the program to compile and print `a: 1`, which is also upstream Elm's behaviour.

#### Fix
- `Compiler/Elm/String.elm`: export a new `valueKey : String -> String`. It decodes escaped literal text to code points and joins them with `,` as decimal numbers.
  - Escapes handled: `\uXXXX`, `\n`, `\r`, `\t`, `\<c>`, and raw characters.
  - A high surrogate followed by a low one (from escapes or raw text) combines into one code point. This keeps the key the same across hosts and before or after Part 1.
- `Test.elm`: `IsChr c -> "H" ++ ES.valueKey c` and `IsStr s -> "S" ++ ES.valueKey s`. Update the doc comment.
- Both `DecisionTree.elm`s: `if ES.valueKey chr == ES.valueKey testChr` (and the same for `str`). Add `import Compiler.Elm.String as ES`.
- The payload text is unchanged: the first spelling seen is emitted, so the JS/MLIR emitters are untouched.

#### Also changes
- `GlobalOpt/AbiCloning.elm:3365` renders trees with `testToComparable`. That output is a key/debug string only, so changed keys are fine there.
- No invariant row covers this.
- Part 1 should make `Generate/MLIR/Patterns.elm decodeChrPatternCode` (line 1284) use the same decoder. Today it folds `😀` to a garbage number.

#### Risks
- `valueKey` runs once per pattern comparison. Patterns are short and these paths are cold.
- No artifact format change: `Test` serialization still writes the text.

#### Validation
- Private unit tests: `a` vs `a`, raw astral vs surrogate pair, escapes, and `ab` vs `a,b`.
- `CaseCharEscapedDuplicateTest` compiled with the private guida.js gives `eco.case ... [97, 98, 0]` (it was `[97, 97, 98, 0]`).
- The E2E run itself was not done: the ecoc JIT lacks the runtime symbols.

#### Confidence
High. To raise it: run E2E `CaseCharEscapedDuplicateTest` through the harness.

---

### Item 2: Exact 64-bit Int literals on the JS host + VarInt

#### Root cause (wider than the plan says)
1. **`Parse/Number.elm`**:
   - `chompInt` (`10*n+d`) and `stepHex` (`16*acc+d`) accumulate in a JS double, which is inexact above 2^53. `0xFFFFFFFFC0000000` becomes 1.8446744072635810e19, not -2^30.
   - **Natively it is also broken**: the hex accumulator wraps negative, and `chompHexHelp`/`chompHexInt` use a negative value as the "not a digit / error" sentinel. So `0xFFFFFFFFFFFFFFFF` and `0x8000000000000000` give a false `NumberHexDigit` error or stop mid-literal on the native compiler.
2. **`Mlir/Bytecode/VarInt.elm`**:
   - `encodeSignedVarInt` uses `Bitwise.xor (value*2) -1`, which is 32-bit on JS and wrong below -2^30.
   - `encode9Bytes` takes its high bytes from `floor(toFloat v / 2^k)`, which is inexact natively for |v| > 2^53.

How a literal flows:
- `Number.Int Int text` → `Src.Int Int String` → **`Can.Int Int` (text dropped)** → `Opt.Int` / `TOpt.Int`
- `TOpt` serializes with `BE.int64`; `Opt` uses `BE.int`, a float64.
- → `Mono.LInt Int` → `Ops.arithConstantInt` → `IntAttr (Just I64) Int` → `AttrType EIntegerAttr` → `encodeSignedVarInt`
- The text printer uses `String.fromInt`.
- The only place the exact text exists is the parser.

#### Design (chosen): keep `Int` in every AST; define a literal's value as its digits mod 2^64 in two's complement; make it exact or reject it at parse time
- An exactly typed pair carried through Src/Can/Opt/TOpt/Mono/IntAttr (plus constant folding and codecs) would touch more than 10 modules and both artifact formats. Not worth it.
- Natively every i64 is exact.
- On JS, a double holds any i64 value with ≤ 53 significant bits. That covers the common large literals: all-ones `-1`, `minInt` `-2^63`, sign-extended masks, and every value in the three E2E tests.
- Only values with more than 53 significant bits (for example `0x7FFFFFFFFFFFFFFF`) cannot be represented on the JS host. They get a clear compile error instead of silent rounding.

New module `Compiler/Data/Int64.elm`:
- `hostIs64 = Bitwise.shiftLeftBy 32 1 /= 1`.
  - JS shifts count mod 32; native counts mod 64 (CGEN_085).
  - It must be evaluated at run time. The front end folds no Bitwise call (`KernelIntrinsics` only maps it to `eco.int.shl`), and LLVM folds it with i64 semantics in the native build, so the bootstrap is safe.
- `toWords : Int -> (hi u32, lo u32)`:
  - Native: `shiftRightBy 32`, then mask.
  - JS: `floor(v / 2^32)` and subtraction, which is exact for whole doubles.
- `fromWords hi lo : Maybe Int`:
  - Native: always `Just`.
  - JS: `Nothing` unless converting back gives the same words.
- `fromLiteral : String -> Maybe Int`:
  - Folds decimal or `0x` text into the word pair with `mulAdd m d`.
  - The pair arithmetic is done in 16/32-bit pieces, and every intermediate stays below 2^37.

`Parse/Number.elm`:
- In `number`, the `OkInt` branch:
  - Fast path: if `0 <= n <= 2^53`, keep `n`. Every ordinary literal, on both hosts, takes this path.
  - Otherwise use `Int64.fromLiteral text`. `Nothing` becomes `P.Cerr row col (toError E.NumberInexactOnHost)`.
- `chompHexHelp` classifies by character (`hexDigitValue`, which replaces `stepHex`), not by the sign of the value.
- `chompHexInt` errors when there are no digits or a dirty end, decided by position, not `answer < 0`.
- `chompHex`'s contract for `Parse/String.eatUnicode` is unchanged: -1/-2 sentinels, and a wrapped code becomes `BadUnicodeCode`.

`Reporting/Error/Syntax.elm`:
- New `Number` variant `NumberInexactOnHost`.
- Encoder tag 10 and the matching decoder.
- Report "INEXACT INTEGER".

`VarInt.elm`:
- `encodeSignedVarInt`:
  - If |v| < 2^52, use `encodeVarInt (2v)` or `encodeVarInt (-2v-1)`, which are exact.
  - Otherwise zigzag on the words: shift left 1 across the words, then xor with `0xFFFFFFFF` for negatives, then `u32`.
  - Write with the new `encodeWords9 hi lo` (`0x00` plus two LE u32).
- `encode9Bytes` uses `Int64.toWords`.
- Delete `shiftRightBy` and `powOf2`, and rewrite the module and function docs (they describe the 2^53 limits).

#### Also changes
- `tests/Parse/NumberTests.elm` doc says "literals too large for an Int, where an error is reported". Add cases from `Lw/LiteralsTest.elm`:
  - `0xFFFFFFFFC0000000` → `Int -1073741824`
  - `0xFFFFFFFFFFFFFFFF` → `-1`
  - `18446744073709551615` → `-1`
  - `0x7FFFFFFFFFFFFFFF` → `Err NumberInexactOnHost` (JS-only expectation; the suite runs on JS)
- Consider a CGEN/front-end invariant row: "an Int literal's value is its digits mod 2^64 as two's complement; the JS-hosted compiler rejects values it cannot hold exactly."
- **JS backend**: a negative Int literal now reaches `JS.ExprInt` (e.g. `-0xFFFFFFFFFFFFFFFF` = `negate (-1)`). `Builder.elm` prints `ExprPrefix PrefixNegate` followed by an atomic `ExprInt -1` as `--1`, which is a JS syntax error (official Elm has the same bug: elm-test-rs emitted `--9223372036854775808` here).
  - Fix in `Generate/JavaScript/Expression.elm` `Opt.Int`: emit `n < 0` as `ExprPrefix PrefixNegate (ExprTrackedInt .. (negate n))`, so it prints `-(-1)` in context. This is not prototyped.

#### Risks / decision for the user
- **Semantic change for the JS target**: a hex literal ≥ 2^63 now means its i64 value (`0xFFFFFFFFFFFFFFFF` = `-1`) where official Elm-on-JS gives a huge double. This is consistent with Eco's 64-bit Int, but it is a JS-backend divergence.
- A literal with more than 53 significant bits is now a compile error on the JS-hosted compiler; before, it was silently rounded. The native compiler accepts it.
- Alternative if the error is unwelcome: keep it only for the MLIR target. That needs the target known at parse time, which it is not today.
- Bootstrap: the native compiler's parser behaviour changes only for literals that were already broken. The `hostIs64` branches are **untested natively**. A bootstrap self-compile (A==B) plus a native run of `HexLiteralNegativeI64Test` is required.
- Perf: the fast path is one range check per literal.

#### Validation
- `VarIntTest` 4/4, `Parse/NumberTests` all pass.
- Private tests (JS host) pass: 13 `fromLiteral` cases, 7 parser cases, zigzag of `-2^63` (→ `00 FF×8`) and `±2^60`, `encodeVarInt -1` / `2^40+5`.
- Private guida.js on `HexLiteralNegativeI64Test` gives bytecode decoded by `ecoc --emit=mlir` as `arith.constant -1073741824 / -2147483648 / -4294967296 : i64`.
- E2E not run (JIT harness).

#### Confidence
- High for the JS host.
- Medium for the native branches (unexecuted). Raise it with a bootstrap and a native E2E run.

---

### Item 3: Int case patterns of 2^32 or more

#### 3a Root cause (Elm)
- `Mlir/Bytecode/AttrType.elm encodeDenseElem` writes bytes 0-3 via 32-bit `shiftRightZfBy` and zeros for bytes 4-7.
- Its doc admits it assumes every value is non-negative and below 2^31.

#### 3a Fix (prototyped)
- Per width:
  - 1 byte: `unsignedInt8 (and v 0xFF)`
  - 2 bytes: `unsignedInt16 LE (and v 0xFFFF)`
  - 4 bytes: `unsignedInt32 LE (u32 v)`
  - 8 bytes: fast path `0 <= v <= 0x7FFFFFFF` writes `[u32 LE v, u32 LE 0]`; otherwise `Int64.toWords` gives `[lo, hi]`.
- Import `Compiler.Data.Int64`.
- Keys already use full `String.fromInt`.
- Hot path (`slot_kinds` are small): one comparison per element.

#### 3a Validation and confidence
- `AttrTypeTest` dense cases 2/2 pass.
- Private guida.js on `IntCaseLargeLiteralTest`, decoded, gives `[5000000000, 7, 0]` (it was `[705032704, 7, 0]`).
- Confidence: high.

#### 3b Root cause (C++, `runtime/src/codegen/Passes/EcoControlFlowToSCF.cpp`)
- `CaseToScfIndexSwitchPattern` (374-532) turns int cases whose tags are all ≥ 0 into `scf.index_switch` over `arith.index_cast(i64)`.
- Upstream SCF→CF lowering casts the index to **i32** for `cf.switch`. That truncates both the case values and the **scrutinee**: `705032704` matches tag `5000000000`, and `2^32+7` would match `7` even when every tag is small.
- The CF fallback (`EcoToLLVMControlFlow.cpp lowerIntegerOrCharCase`, 262) already switches on i64. The 2-way `CaseToScfIfPattern` (242-260) compares in i64 and is fine.
- Related latent bug (Part 1 overlap): the char path does `arith.index_cast` of an **i16** scrutinee, which sign-extends. A char ≥ U+8000 then becomes negative and never matches its non-negative tag. Use `arith::IndexCastUIOp`, or after Part 1 an i32 code point.

#### 3b Fix (design, unvalidated)
1. Add a helper:
   ```cpp
   static bool intTagsFitI32Switch(CaseOp op) { for (int64_t t : op.getTags()) if (t < 0 || t > INT32_MAX) return false; return true; }
   ```
2. In `CaseToScfIndexSwitchPattern`, replace the "tag < 0 → failure" loop with `if (isIntegerCase(op) && !intTagsFitI32Switch(op)) return failure();`.
3. In `CaseToScfIfChainPattern` (~585), replace the `hasNegativeTag` test with `if (intTagsFitI32Switch(op)) return failure();`, so negative or > INT32_MAX tags use the i64 compare chain (`buildIntIfChain`, already i64). Update the comments and pattern docs ("negative-int cases" becomes "tags outside [0, INT32_MAX]").
4. Guard the scrutinee on the index_switch int path, before `IndexCastOp`:
   ```cpp
   int64_t sentinel = 0; { llvm::SmallDenseSet<int64_t> s(tags.begin(), tags.end()-1); while (s.contains(sentinel)) ++sentinel; } // ≤ N probes, ≤ INT32_MAX
   auto maxC = rewriter.create<arith::ConstantOp>(loc, rewriter.getI64IntegerAttr(INT32_MAX));
   auto inRange = rewriter.create<arith::CmpIOp>(loc, arith::CmpIPredicate::ule, intVal, maxC); // negatives fail too
   auto sentC = rewriter.create<arith::ConstantOp>(loc, rewriter.getI64IntegerAttr(sentinel));
   intVal = rewriter.create<arith::SelectOp>(loc, inRange, intVal, sentC);
   ```
   - The sentinel is the first non-negative value that is not a non-default case value, so out-of-range scrutinees reach the default region.
   - Cost: one `cmp` and one `select`, with no region duplication.
5. Char path: use `arith::IndexCastUIOp` instead of `IndexCastOp` (it needs `UnboxOp` to i16 as today).
6. Update invariant CGEN_048 (`invariants.csv:323`): "int eco.case lowers to scf.index_switch only when all tags lie in [0, 2^31-1], with the scrutinee clamped to a non-case sentinel when outside that range; otherwise to an i64 scf.if chain."
7. Add a lit test under `test/codegen/`:
   - `eco.case %x : i64 [5000000000, 7, 0] {case_kind="int"}` lowers to an `scf.if` chain with `arith.cmpi eq ... : i64`, and no `index_switch`.
   - `[3, 7, 0]` lowers to `index_switch` preceded by `arith.cmpi ule` + `arith.select`.

#### 3b Risks and confidence
- Dense small-tag switches keep the jump table, so the perf cost is two instructions per switch.
- Large-tag cases become if-chains (rare).
- There is no other `IndexSwitchOp` creator for int (`EcoToLLVM.cpp:99` rebuilds existing ones; check that it copies operands unchanged).
- Confidence: medium-high, unvalidated. Raise it with the lit test, E2E `IntCaseLargeLiteralTest` with `--target full`, and the codegen suite.

---

### Item 4: Attribute-table key collisions

#### Root cause
- `AttrType.attrToKey`, `ArrayAttr Nothing` branch: `"aa:" ++ String.join "," (List.map attrToKey items)`.
- So `["a,s:b"]` and `["a","b"]` both give `aa:s:a,s:b`.
- `dictToKey` has the same flaw (`k ++ "=" ++ key`, joined by `,`): a string value containing `,x=s:` can alias another dictionary. The plan does not mention this.

#### Fix (prototyped)
- New `lengthPrefixed attr = String.fromInt (String.length key) ++ ":" ++ key`.
  - `aa:` becomes `"aa:" ++ String.concat (List.map lengthPrefixed items)`.
  - `dictToKey` becomes `"d:{" ++ concat (len(k) ++ ":" ++ k ++ lengthPrefixed v) ++ "}"`.
- Update the `attrToKey` doc.

#### Also changes
- The order of entries in the output may shift if the table orders by key. Semantics are unchanged; JS-host and native outputs still agree because both run the same source.
- Separate latent bug, left in place and documented: `TypedFloatAttr` keys with `String.fromFloat`, so `0.0` and `-0.0` share one entry and a `-0.0` constant can become `+0.0`. Fix (follow-up): key `-0` specially (`if f == 0 && 1/f < 0 then "-0"`).

#### Risks
- Keys are compared on every lookup (see the `singleDigitValues` comment). The length prefix adds a few characters only to `aa`/`d` keys; `slot_kinds` (`da#`) is untouched.

#### Validation
- `AttrTypeTest` `,` case passes.
- Private guida.js on `StringCasePatternCommaTest`, decoded, gives `string_patterns` with 2 elements on the 3-alternative cases and 3 on the 4-alternative cases.

#### Confidence
High.

---

### Item 5: Infinite float literals in JS + `Name.jsArray`

#### Root cause
- `Generate/JavaScript/Expression.elm:129-141`: `float == toFloat (floor float)` holds for `Infinity`, and the text `"Infinity"` has no `e` or `.`, so `.0` is appended (`NaN` does not match).
- `Compiler/Data/Name.elm:510`: `jsArray = "JsArray"`, but core's module is `Elm.JsArray`, so the check `moduleName == Name.jsArray` in `generateCoreCall` (694) never fires.
- That is the only use of `Name.jsArray` (KernelAbi and KernelFacts use literals).

#### Fix (prototyped)
- Condition becomes `not (isInfinite float) && not (isNaN float) && float == toFloat (floor float) && ...`. The short-circuit also avoids `floor Infinity` on the native host.
- `jsArray = "Elm.JsArray"`, with the doc changed to "the name of elm/core's module `Elm.JsArray`". Update the `generateCoreCall` doc.
- The inlined forms (`[x]`, `arr[i]`) match `_JsArray_singleton` / `_JsArray_unsafeGet`.

#### Risks
- JsArray inlining now fires for every core `Array` user in JS output. That is a perf gain, and upstream Elm has the same behaviour.
- `-1e400` stays `ExprPrefix negate` of `Infinity` and prints `-Infinity`.

#### Validation
- `ExpressionTest` 2/2 pass.
- `TestLogic/Generate/JavaScript/InfiniteFloatLiteralTest` passes.

#### Confidence
High.

---

### Item 6: Text MLIR printer (`Mlir/Pretty.elm`)

#### Root cause
- `ppOp` concatenates `regionsStr` before `attrsStr`. With a `callee`, the `<{..}>` properties must come before the regions.
- `ppAttr UnitAttr = ""`, so it prints nothing inside arrays.
- `ppRegion` starts every block from `Dict.fromList args`, which drops the enclosing scope.
- `ppModule` prints each top-level op with an empty environment.

#### Fix (prototyped)
1. In `ppOp`, `( propsStr, plainAttrsStr ) = if Dict.member "callee" op.attrs then ( attrsStr, "" ) else ( "", attrsStr )`. The order becomes `succ, props, regions, plainAttrs`.
2. `UnitAttr -> "unit"` in `ppAttr`. Dictionary entries still print the bare key via `render`.
3. `ppRegion : Int -> SsaEnv -> MlirRegion -> String`:
   - Each block's environment is `outerEnv` plus its arguments.
   - `ppOp` passes its own `env`, which holds the values defined before the op.
4. `ppModule` folds over the body, threading `env` with each op's results.
   - `ppTopLevelOp` is unchanged (empty environment). The `Backend.elm` streaming path uses it, but real top-level ops (`func.func`, globals) take no operands.
5. Update the module doc paragraph on operand lookup and the `ppRegion`/`ppOp` docs (module header done in the prototype).

#### Risks
- Text-MLIR output changes only where it was previously unparseable or under-typed.
- `PrettyTextRoundTripTest` still passes.

#### Validation
- `PrettyTest` 4/4 pass.
- `PrettyTextRoundTripTest` passes.

#### Confidence
High.

---

### Item 7: U+FFFF in strings

#### Root cause
`Compiler/Elm/String.elm:69` uses `if code < 0xFFFF`, so 0xFFFF takes the surrogate-pair path and comes out as `퟿\uDFFF`.

#### Fix (prototyped)
`code <= 0xFFFF`, and fix the `Chunk` doc paragraph.

#### Also changes
**`tests/Parse/StringTests.elm` lines 16 and 51 pin the bug** (`Ok ("\\uD7FF\\uDFFF", False)`). Change it to `Ok ("\\uFFFF", False)` and fix the doc bullet. This test went red in the full-suite run.

#### Validation
- `Compiler/Elm/StringTest` passes.
- Node `test/scripts/cli-jsout.test.js` with `GUIDA_JS_PATH=/tmp/lw-literals/guida.js` passes (1/1).

#### Confidence
High.

## Part 5: error reports (items 5.2-5.10)

Prototype tree: `snapshots/review-bug-triage-fixes/part5-reports.diff (prototype tree was /tmp/lw-reports/){src,src-xhr,bin}` (diff each against `/work/compiler/...` to get the patch).
Validation done:
- Full elm-test-rs suite, prototype vs. unpatched shadow root, same tree. Baseline: 14,440 pass / 59 fail. Prototype: 14,452 / 47.
  All 16 target unit tests now pass. The only new failures are 4 golden fingerprints (item 8, expected; new values below).
- `test/scripts/cli-errors.test.js`, run against a guida.js rebuilt from the prototype (`elm make` in the shadow root, then
  `scripts/replacements.js`, about 17 s) and a copied `compiler/bin` (patched handler) through `GUIDA_JS_PATH`:
  tests 1-10 go from all failing to all passing. Test 11, the trailing comma, is Part 5 item 1 and is not in this group.

Upstream (Haskell elm/compiler) reference points used: `Reporting.Result` is an applicative that collects errors, and
`indexedTraverse` / `mapTraverseWithKey` / `Map.mergeA` all collect. `Dups.unions = List.foldl' union Map.empty`, so the
accumulator comes first. `whatIsNext` uses `span`/`takeWhile`. `Docs.checkNames` uses `Map.mergeA` in `Result`. A let is
constrained as `constrainDef rtv def =<< constrain rtv body expected`, so the body is checked against the outer expectation.
`Json.expectationToReport` has `region = if sr == er then region else ...`, a self-referential binding (`<<loop>>` in
upstream). The intended value is the whole region.

---

### Item 2: hcat + Pattern order

#### Root cause
- `Text/PrettyPrint/ANSI/Leijen.elm` `hcatHelp` (about line 421). The `[ doc ] -> doc` case drops `acc`, and the general
  case `P.append doc acc` builds the documents in reverse. Two bugs.
- `Compiler/Reporting/Error/Pattern.elm` `delist`: `P.Ctor _ "[]" [] -> FiniteList revEntries` leaves the entries
  reversed. The doc comment even says "Its entries are in reverse order". `hcat` used to mask this.

#### Fix
```elm
hcatHelp docs acc =
    case docs of
        [] -> acc
        doc :: ds -> hcatHelp ds (P.append acc doc)
```
```elm
        P.Ctor _ "[]" [] ->
            FiniteList (List.reverse revEntries)
```

#### Also changes
Update the doc comments: the Leijen module header (line 20, "hcat keeps only the last"), the `hcat`/`hcatHelp` docs,
`Compiler/Reporting/Doc.elm` (lines 44 and 822-825), the Pattern.elm `patternToDoc` and `Structure` docs, and the
"EXPECTED TO FAIL" headers in DocHcatTest, LeijenTest and PatternFiniteListTest.
Other `hcat` users now get every document. Check with `grep -rn "D.hcat\|P.hcat" compiler/src`: every one of them was
silently broken before, and the full suite shows no regressions.

#### Risks
Some error-report text now contains content it used to drop. That is intended and matches upstream. No hot path.

#### Validation
DocHcatTest, PatternFiniteListTest and the LeijenTest hcat case pass. cli-errors test 1 passes. Full suite has no regressions.

#### Confidence
High.

### Item 3: Leijen reset + System/IO.isTerminal

#### Root cause
1. `Leijen.renderPretty` (about line 154). A `tagged` string never writes a reset before itself, so styles carry over.
   `outer` never closes a trailing styled string.
2. Not in the plan: `plain` sets `defaultStyle` (every field off), and that still counts as "styled". So `D.toString`
   (`renderPretty (plain doc)`) writes `ESC[0m` sequences. That breaks `DocHcatTest` (`"abc\e[0m"`) as soon as the reset
   is added. It is also what leaks codes into the pipe path (cli-errors test 10 comment). Upstream `plain` removes styling
   entirely.
3. `System/IO.elm:252` `isTerminal = Task.succeed True`. No host exposes isatty to the compiler today:
   - `compiler/bin/eco-io-handler.js` has no Console op for it. It has only `Console.write`, `Console.readLine` and
     `Console.readAll` (around lines 194-232).
   - The native kernel `eco-kernel-cpp/src/eco-kernel/Console.{hpp,cpp}`, `ConsoleExports.cpp` and `Eco/Kernel/Console.js`
     have none either.
   - The only isatty users live in `system-kernel-cpp` (`Terminal.cpp` `::isatty(1)`; `Terminal.js`
     `require('tty').isatty(fd)`). That is eco/system, not the compiler's kernel.
4. Callers ignore the handle. `Builder/Reporting/Exit/Help.toHandle` asks without the handle.
   `Terminal/Terminal/Error.exitWith` writes to stderr.

#### Fix
Leijen: track the current style, not a Bool, and treat `defaultStyle` as unstyled. Prototype:
```elm
type alias RenderAcc = { style : Maybe Style, newline : Bool, list : List (SimpleDoc -> SimpleDoc) }

tagged = \style str acc ->
    if style == defaultStyle then untaggedStep str acc
    else if acc.style == Just style then { acc | list = SText str :: acc.list }      -- same style: no SGR churn
    else { acc | style = Just style
               , list = SText str :: SSGR (styleToSgrs style)
                        :: (if acc.style == Nothing then acc.list else SSGR [Ansi.Reset] :: acc.list) }
untagged = untaggedStep   -- old untagged body, `acc.styled` -> `acc.style /= Nothing`, sets style = Nothing
outer = \{ style, list } -> List.foldl (<|) SEmpty (if style == Nothing then list else SSGR [Ansi.Reset] :: list)
```

isTerminal (the interface takes the handle):
- `System/IO.elm`: `isTerminal : Handle -> Task Never Bool`; `isTerminal (Handle fd) = Eco.Console.isTerminal (Eco.Console.Handle fd)`.
- `src-xhr/Eco/Console.elm`: expose `isTerminal : Handle -> Task Never Bool` = `Eco.XHR.jsonTask "Console.isTerminal"
  (object [("handle", int h)]) Decode.bool |> Task.onError (\_ -> Task.succeed False)`. Add the `Json.Decode` import.
- `compiler/bin/eco-io-handler.js`: add a new case before `Console.readAll`:
  ```js
  case "Console.isTerminal": { const { handle } = args; let value = false;
    if (handle === 0 || handle === 1 || handle === 2) { try { value = require("tty").isatty(handle); } catch (e) {} }
    respond(200, JSON.stringify({ value })); break; }
  ```
- Native (NOT built, unvalidated design):
  - `eco-kernel-cpp/src/Eco/Console.elm`: `isTerminal (Handle h) = Eco.Kernel.Console.isTerminal h`.
  - `Console.hpp/.cpp`: `uint64_t isTerminal(uint64_t handle)` returns `makeBinding<isTerminalBody>(tuple2(unboxedInt(handle), unit, mask 0x1))`.
    The body does `succeedBool(fd==1 ? ::isatty(_eco_stdout_fd()) : fd==2 ? ::isatty(_eco_stderr_fd()) : fd==0 ? ::isatty(0) : false)`.
    Windows: `_isatty(_fileno(...))`. Keep it a binding, per KERNEL_TASK_IO_001.
  - `ConsoleExports.cpp`: `HPtr Eco_Kernel_Console_isTerminal(HPtr handle)`. Add its declaration in `KernelExports.h`.
  - `Eco/Kernel/Console.js`: `_Console_isTerminal = function(h){ return __Scheduler_binding(cb => cb(__Scheduler_succeed(h<=2 && require('tty').isatty(h)))) }`.
- Callers: `Help.toHandle` uses `IO.isTerminal handle`. `Terminal/Terminal/Error.exitWith` (line 90) uses `IO.isTerminal IO.stderr`.

#### Also changes
- Docs: the Leijen `renderPretty` and `plain` docs ("Three consequences..."), `Doc.toString`/`toLine` docs ("reset escape
  sequences remain"), the `System.IO` module doc line 33, the `Help.elm` lines 18 and 198, and the eco-io-handler header op list.
- Editing `Console.cpp` / `ConsoleExports.cpp` changes their sha256. `kernel-license-manifest.txt` rows for
  `Eco.Console.{log,readAll,readLine,write}` (LSS_022) will fail `check-kernel-license-manifest.sh`. Re-audit those rows
  (update `audited:` and the line numbers in `KernelSetFacts.elm` evidence), then `--update`. Do not just regenerate.
  The new kernel has no function positions, so it can stay rowless (default poison is harmless).
- The kernel copy in `~/.eco/<ver>` is stale after kernel edits (memory: E2E stale caches). Wipe it before E2E.
- Memory rule: src-xhr and eco-kernel-cpp signatures must match.

#### Risks
- A Process stream handle (>2) answers False, so plain output. That is fine.
- The elm-test harness has no eco-io. `isTerminal` is only called from IO paths, never from unit tests.
- Output escapes change: there are no resets between same-style runs, there is a reset at the end, and plain text has
  none. Only LeijenTest pins exact escapes.

#### Validation
- The two LeijenTest reset cases pass, and DocHcatTest passes with the defaultStyle change.
- cli-errors test 10 (piped output, no `\x1b[`) passes on the JS host with the patched handler.
- The native side is designed only: not compiled, no E2E.

#### Confidence
- High for Leijen and the JS host.
- Medium for native. To raise it, build eco-kernel-cpp and run `eco make` piped vs. on a tty with the native binary.

### Item 4: whatIsNext

#### Root cause
`Compiler/Reporting/Render/Code.elm` `whatIsNext` (about lines 390-397) and `detectKeywords` (about line 418) use
`List.filter isInner/isSymbol` over the rest of the line. Upstream takes only the leading run (`takeWhile`).

#### Fix
Add a local `takeWhile : (a -> Bool) -> List a -> List a` (plain recursion; lines are short). Use it in place of
`List.filter` in the three places: the `Upper`, `Operator` and `detectKeywords` cases.

#### Also changes
The docs of `Next` ("not always one token") and of `whatIsNext` (the `foo bar` → `"foobar"` example) and
`detectKeywords`. The test header.

#### Risks
None known. Reports now pick RESERVED WORD and the other titles as upstream does.

#### Validation
CodeWhatIsNextTest passes 4/4. cli-errors tests 2 and 3 pass.

#### Confidence
High.

### Item 5: Result traversals (plan diagnosis incomplete)

#### Root cause
- `Compiler/Reporting/Result.elm`: `indexedTraverse` (line 361) is a `foldr` of `andThen`, so it stops at the first
  failure from the end. `mapTraverseWithKey` (line 326) uses `loop`, which stops at the first failure.
- Also `Canonicalize/Environment/Dups.detect` (line 74) is a `Dict.foldl` of `andThen`. It does not go through
  `mapTraverseWithKey`, so fixing the traversals alone still fails cli-errors test 5 (`f (a, a) (b, b)` reports only `a`).
  `detectLocated` uses `mapTraverseWithKey` and is fixed by it.

#### Fix
Add one tail-recursive, stack-safe collector to Result.elm. Route `traverse`, `indexedTraverse` and
`mapTraverseWithKey` through it:
```elm
collectAll : (a -> RResult i w x b) -> List a -> RResult i w x (List b)
collectAll func xs = RResult (\i w -> collectAllHelp func xs i w (Ok []))

collectAllHelp func xs i w acc =            -- acc : Result (OneOrMore x) (List b), values reversed
    case xs of
        [] -> case acc of Ok rev -> ROk i w (List.reverse rev)
                          Err es -> RErr i w es
        x :: rest ->
            let (RResult k) = func x in
            case k i w of
                ROk i1 w1 v  -> collectAllHelp func rest i1 w1 (Result.map ((::) v) acc)
                RErr i1 w1 e -> collectAllHelp func rest i1 w1 (case acc of Ok _ -> Err e
                                                                             Err es -> Err (OneOrMore.more es e))
traverse = collectAll
indexedTraverse func xs = collectAll identity (Index.indexedMap func xs)
mapTraverseWithKey toComparable f dict =
    collectAll (\( k, a ) -> map (Tuple.pair k) (f k a)) (DataMap.toList dict)
        |> map (List.foldl (\( k, b ) acc -> DataMap.insert toComparable k b acc) DataMap.empty)
```
Delete `mapTraverseWithKeyHelp`. `traverse` semantics are unchanged: it threads first to last, collects in order, and
leaves info/warnings from the last step. It also becomes stack-safe, because the old one nested one closure frame per element.

`Dups.detect`:
```elm
detect toError dict =
    ReportingResult.traverse
        (\( name, values ) -> ReportingResult.map (Tuple.pair name) (detectHelp toError name values))
        (Dict.toList dict)
        |> ReportingResult.map Dict.fromList
```

#### Also changes
- Result.elm module doc (lines 28-29: "loop, mapTraverseWithKey and indexedTraverse also stop") and the docs of both
  functions. `indexedTraverse` now runs first to last, where it used to run last to first.
- `Dups.detect` doc.

#### Risks
- Warning order from `indexedTraverse` users flips to source order, which matches upstream.
- Passes that relied on stop-at-first-error now see later errors. This is what the plan wants, and it is how upstream behaves.
- `loop` is still stack-safe and unchanged.

#### Validation
ResultTraverseErrorsTest passes 2/2. cli-errors tests 4 and 5 pass. Full suite has no regressions.

#### Confidence
High.

### Item 6: Dups order

#### Root cause
`Dups.unions` (line 207) is `List.foldl union Dict.empty dicts`. Elm's `foldl` passes `(elem, acc)`, so this computes
`union later acc`, and later occurrences come first. Upstream `foldl'` passes `acc` first.

#### Fix
`List.foldl (\dict acc -> union acc dict) Dict.empty dicts`.

#### Also changes
The `unions` doc ("a later tracker's occurrences come before"). Callers: `Module.elm:465` (exports),
`Environment/Local.elm:553-554` and `660`. They all just get source order now.

#### Risks
None. Only region order in duplicate reports changes.

#### Validation
DupsUnionsOrderTest passes. cli-errors test 7 passes.

#### Confidence
High.

### Item 7: Docs checkNames

#### Root cause
`Compiler/Elm/Docs.elm` `checkNames` (line 706). All three `Dict.merge` steps ignore the accumulator (`_`), so only the
last key's result survives.

#### Fix
Thread the accumulator with `apply`, so errors come in key order, as in upstream `mergeA`:
```elm
keepBoth acc next = ReportingResult.ok (\_ r -> r) |> ReportingResult.apply acc |> ReportingResult.apply next
loneExport name export_ acc = keepBoth acc (onlyInExports name export_)
checkBoth n _ r acc = keepBoth acc (isUnique n r)
loneDoc name regions acc = keepBoth acc (onlyInDocs name regions)
```

#### Also changes
The `checkNames` doc, if it describes the old behaviour, and the DocsTest header.

#### Risks
None. Docs generation only.

#### Validation
DocsTest passes. cli-errors test 8 (`make --docs` fails) passes.

#### Confidence
High.

### Item 8: let-body mismatch region

#### Root cause
`Type/Constrain/Typed/Expression.elm`:
- `letSpineGo` (lines 600-628) constrains the body against `NoExpectation (VarN exprVar)`.
- `applyLetFrame` (line 658) then adds `CEqual frame.region Lambda (VarN exprVar) frame.expected`.

So a mismatch is blamed on the whole `let`, with category `Lambda`, which renders as "anonymous function". Upstream
passes `expected` to the body.

#### Fix
- `letSpineGo`: in all three arms, recurse with `expected`, not `NoExpectation (VarN exprVar)`. The frame still records
  `exprVar` for the node.
- `applyLetFrame`: `CEqual frame.region Lambda (VarN frame.exprVar) (NoExpectation (expectedType frame.expected))`, with
  ```elm
  expectedType : E.Expected Type -> Type   -- NoExpectation t | FromContext _ _ t | FromAnnotation _ _ _ t -> t
  ```
  The CEqual only binds the fresh node var. It can never fail, so it never reports. This is the same pattern as the
  `If` branch at line 1288.

The let node var now equals the expected type, not the body's own variable. These are identical whenever the program
type-checks.

#### Also changes
- The `constrainLetSpine` doc ("reported at the whole let").
- Golden fingerprints in `compiler/tests/TestLogic/Type/Constrain/GoldenConstraintTest.elm` move. These four are exactly
  the corpus entries with a let:

  | entry | new value |
  |---|---|
  | `let-family` | `(3899926726,1369469687)` (was `(3480157346,776512907)`) |
  | `pipe-chains` | `(2678310403,64681076)` (was `(1069070543,2887143088)`) |
  | `call-shapes` | `(1746417324,3223559557)` (was `(132171800,639265737)`) |
  | `access-update-accessor` | `(3026365807,1043082062)` (was `(2324415555,136880178)`) |

  Update them, and record in the commit that the constraint shape changed on purpose.
- The fallback arm at line 1706 (`Can.Let def body -> constrainWithIds rtv body expected`) already does the right thing.

#### Risks
- Typed optimizer / mono consumers read the let node's var. For well-typed programs the solved type is unchanged, so the
  generated code should be unchanged.
- To confirm, run the bootstrap/fixed-point gate (front-end change), or at least E2E `full`.

#### Validation
ExpressionTest passes. cli-errors test 9 ("The body is a string of type") passes. No other regressions apart from the 4 goldens.

#### Confidence
High for the report. Medium-high for codegen neutrality: a bootstrap byte-identity check would raise it.

### Item 9: Json single-row crash

#### Root cause
`Compiler/Reporting/Error/Json.elm` `expectationToReport` (line 470): `if sr == er then crash "region"`. This is a
transliteration of upstream's self-referential `region = if sr == er then region else ...`.

#### Fix
`if sr == er then A.Region start end else A.Region start start`. Drop the now-unused `Utils.Crash` import if nothing
else in the file uses it.

#### Also changes
The function doc (line 456) and the module doc (line 55).

#### Risks
None.

#### Validation
JsonSingleRowTest passes. cli-errors test 6 (`"elm-version": 19`) passes.

#### Confidence
High.

### Item 10: Canonical codec

#### Root cause
`Compiler/AST/Canonical.elm`:
- The encoder (lines 1339 and 1345) writes `Update` and `Record` keys with `(A.toValue >> BE.string)`, dropping the region.
- The decoder (lines 1490 and 1494) reads `A.locatedDecoder BD.string`.

#### Fix
Use `BE.assocListDict (A.locatedEncoder BE.string) ...` at both encoder sites.

#### Also changes
Drop the "does not round-trip" paragraph in the `fieldUpdateEncoder` doc (line 1101) and the module doc (line 58), and
the note in `Compiler/Reporting/Error/Type.elm` around line 2924.

#### Risks
- Changes the byte format. `exprEncoder` is reached only through `fieldUpdateEncoder`, which only
  `Reporting/Error/Type.elm:3228` uses (error serialization).
- `Interface` / artifacts use `annotation`/`union`/`alias`/`type` encoders, not expressions, so no artifacts.dat
  invalidation is expected. Wiping `~/.eco` caches anyway is cheap insurance.

#### Validation
CanonicalCodecTest passes.

#### Confidence
High.

## Parts 6 and 7: JSON, package metadata, builder and the JS I/O host

Prototype: `/tmp/lw-builder/src` (copy of `compiler/src`), `/tmp/lw-builder/bin/eco-io-handler.js`.
Full diffs, ready to apply: `/tmp/lw-builder/part6.diff` (Elm, 14 files), `snapshots/review-bug-triage-fixes/part7-io-handler.diff` (JS).
Private shadow root: `/tmp/lw-builder/root`; private Stage-1 compiler: `/tmp/lw-builder/root/bin/guida.js`.

How the CLI tests were run against a private build (cheap, ~20 s): in the shadow root,
`elm make --output=<root>/bin/guida.js <src>/Terminal/Main.elm` then
`node compiler/scripts/replacements.js <root>/bin/guida.js` (the same two commands as
`compiler/CMakeLists.txt:176-178`). `compiler/bin/index.js` honours `GUIDA_JS_PATH`. Copies of the
node tests with `ECO`/`HANDLER`/`APP_ELM_JSON` repointed are in `/tmp/lw-builder/scripts/`; run with
`NODE_PATH=/work/compiler/node_modules GUIDA_JS_PATH=/tmp/lw-builder/root/bin/guida.js node --test ...`.

Results with every change below applied:
- unit: all 16 target tests pass (Json Decode 3, Encode 1, Package 2, Version 1, Utils.Main 2, Diff 2,
  ExitDocsData 1, Generate 1, Make 3). Before: 15 failed.
- node `builder-cli` 8/8 + `cli-builder` 10/10 pass (private guida.js + private handler).
- node `eco-io-handler` 5/5 + `eco-io-handler-builder` 10/10 pass against the private handler; the
  same tests against `/work/compiler/bin/eco-io-handler.js` fail 15/15.
- Full elm-test suite: see "Regression check" at the end.

---

### 6.1 JSON decode positions (`Compiler/Json/Decode`)

#### Root cause
`Compiler/Parse/Primitives.elm:315-343`: `andThen` turns `Cok` + `Eerr` into `Eerr` (consumed flag
lost). In `pObject`/`pField`/`pObjectHelp`/`pArray`/`pArrayHelp` (`Json/Decode.elm:865-970`) every
failure after the opening bracket is therefore empty, and `pValue`'s `P.oneOf Start`
(`Json/Decode.elm:847`) replaces it with `Start` at the value's start (1:1 for the top level). The
plan's diagnosis is right. Same root cause as Part 5.1.

#### Fix
Two options; pick by order of landing:
- **If Part 5.1 (global `Primitives.andThen`: `Cok` then `Eerr` -> `Cerr`) lands first, it fixes all 3
  DecodeTest cases on its own** (verified: original `Json/Decode.elm` + only the 5.1 `andThen` change
  passes DecodeTest 3/3). Then 6.1 is just the `ObjectFirstField` addition and doc update below.
- Otherwise, local fix (prototyped): add to `Json/Decode.elm`
  `andThenCommit : (a -> Parser b) -> Parser a -> Parser b` = `P.andThen` plus
  `Cok`-then-`Eerr` -> `Cerr` (uses the exported `P.Parser(..)`, `P.PStep(..)`), and replace every
  `P.andThen` inside `pObject`, `pObjectHelp`, `pField`, `pArray`, `pArrayHelp` with it (`pFile`,
  `pValue` unchanged).

Plus (both options): a first-field failure (`{ this ...`) now reaches the user as `ObjectField`, whose
report is "EXTRA COMMA ... I saw a comma right before" (wrong; observed via CLI). Add
`ObjectFirstField Row Col` to `ParseError`, use it as the `P.oneOf` error in `pObject`'s first-entry
choice (`P.oneOf ObjectField` -> `P.oneOf ObjectFirstField`), and add a report arm in
`Compiler/Reporting/Error/Json.elm` ("EXPECTING A FIELD NAME": expecting a field name in double
quotes, like "type" or "dependencies", or a closing curly brace; + `objectNote`). Rewrite the
`ParseError` docstring (it currently says only `ObjectEnd` is ever produced).

#### Also changes
`Compiler/Reporting/Error/Json.elm` (new arm; only exhaustive match of `ParseError`, no codec).
Header comment of `tests/Compiler/Json/DecodeTest.elm` ("EXPECTED TO FAIL").

#### Risks
Only JSON text parsing (elm.json, docs.json, registry, eco config). Committing after `{`/`[`/`,`/key is
safe: alternatives of `pValue` are distinguished by their first char, so no successful backtracking is
lost. Error positions/titles in reports change (intended). No hot path.

#### Validation
DecodeTest 3/3; CLI "malformed elm.json error points at the missing colon" passes; checked by hand that
`{ this is not json` now gives EXPECTING A FIELD NAME with the caret under `t`.

#### Confidence
High.

---

### 6.2 JSON encode escaping (`Compiler/Json/Encode.escape`)

#### Root cause
`Json/Encode.elm:190-211`: only CR, LF, `"` and `\` are escaped; other chars < U+0020 are written raw.

#### Fix
In `escape`, add `'\t' -> "\\t"` and in the default arm
`if Char.toCode c < 0x20 then "\\u00" ++ hexDigit (code // 16) ++ hexDigit (modBy 16 code) else String.fromChar c`,
with `hexDigit n = String.slice n (n + 1) "0123456789abcdef"`.

#### Also changes
Docs: module doc (lines 16-21), `string` (115-116), `escape` (186-188) say other control chars are
written raw. Object keys are still never escaped (out of scope; triage closed it as not reachable).

#### Risks
Output bytes of docs.json / elm.json writes change only for strings containing control chars. `escape`
is per-char already; no perf change. Part 1 (32-bit Char) does not interact (`Char.toCode` < 0x20).

#### Validation
EncodeTest 1/1; CLI `make --docs` with U+0001 / form feed produces parseable docs.json.

#### Confidence
High.

---

### 6.3 Package and version validation

#### Root cause
- `Compiler/Elm/Package.elm:561-583` `chompName`: the final `else ( True, pos )` (stopped at a
  non-name char, e.g. `/`) ignores `prevWasDash`, so `elm-/core` passes; only end-of-input checks it.
- `Compiler/Elm/Version.elm:321-379` `numberParser`/`chompWord16`: `10 * total + d` unbounded.

#### Fix
- Package: `else ( not prevWasDash, pos )`; update the docstring ("A dash before any other stopping
  character is accepted" -> malformed when a dash is the last char before it stops).
- Version: add `maxComponent = 65535`; `chompWord16` accumulates
  `Basics.min (maxComponent + 1) (10 * total + d)` (no overflow; `Basics.` needed, `min` is shadowed in
  that module); `numberParser` returns `P.Cerr st.row st.col Tuple.pair` when `total > maxComponent`.
  Update the two docstrings ("no bound on the value", "nothing bounds the value to 16 bits").

#### Also changes
`Version.parser` is also used by `Constraint.elm:437`, `Registry.elm:314`, `Terminal/Helpers.elm:78`:
all now reject components > 65535 (matches the reference compiler's Word16). No version >65535
exists in the registry.

#### Risks
Rejection is a `Cerr` (consumed), so callers inside `oneOf` do not backtrack into another reading;
error is reported at the component's first digit.

#### Validation
PackageTest 2/2, VersionTest 1/1; CLI author-dash ("INVALID PACKAGE NAME") and over-long version
cases pass.

#### Confidence
High.

---

### 6.4 `dictFromListWith` is always empty (`Utils/Main.elm:423`)

#### Root cause
`Dict.update k (Maybe.map (flip f a))` never inserts an absent key. Diagnosis confirmed.

#### Fix
```elm
dictFromListWith f =
    List.foldl
        (\( k, a ) -> Dict.update k (\m -> case m of
            Just old -> Just (f old a)
            Nothing -> Just a))
        Dict.empty
```
(`f old new`, list order — what the old `flip f a` intended; callers use `OneOrMore.more`, so the first
two reported paths are in input order.) Rewrite its docstring.

#### Also changes
Revives three dead checks; their docstrings say "always empty / never reports" and must be rewritten:
`Builder/Elm/Outline.elm:318-321` (read) and `:448-453` (`detectDuplicates`),
`Builder/Build.elm:1812-1817` (`checkUniqueRoots`), `:2541-2545` (`checkRoots`). Their logic
(`isDup`, `checkOutside`, `checkInside`, `fromOneOrMore`) was read and is correct as written.

#### Risks
Newly reported errors: REDUNDANT SOURCE DIRECTORIES (elm.json listing one dir twice), CONFUSING FILES
(same root file twice), MODULE NAME CLASH (two outside roots with one name, or an outside root that
shadows a src-dir module). Scanned all 152 elm.json under /work (outside build/elm-stuff): none lists a
directory twice. Check that no build/test script passes the same .elm root twice (none found by grep).

#### Validation
Utils/MainTest 2/2; CLI builder-cli dup cases (3) pass.

#### Confidence
High.

---

### 6.5 `eco diff` (`Builder/Deps/Diff`, `Builder/Reporting/Exit`)

#### Root cause
- `Diff.elm:192-210` `isEquivalentUnion`: type variable lists are only compared via
  `isEquivalentAlias` per constructor argument, so with no constructors (opaque) or only nullary ones
  the arity is never compared.
- `Exit.elm:578` (`DP_Data`): `++ body ++ " bytes"`; `RP_Data` (`:1961`) does it right.

#### Fix
- `isEquivalentUnion`: prepend `(List.length oldVars == List.length newVars) &&`. Update docstring
  (drop "When no constructor has an argument, the variable lists are never compared").
- `Exit.elm:579`: `++ String.fromInt (String.length body)`.

#### Also changes
None (no other caller depends on the PATCH result).

#### Risks
Renaming a type variable keeps arity, so still equivalent. Length counts UTF-16 units like `RP_Data`
(consistent; "bytes" wording is pre-existing).

#### Validation
DiffTest 2/2, ExitDocsDataTest 1/1; CLI `eco diff` MAJOR and "contains 5 bytes" pass.

#### Confidence
High.

---

### 6.6 Stage arity limit message

#### Root cause
`Exit.elm:2773-2784` (`GenerateMonomorphizationError`): only messages starting with
`"specialization "` skip "This is likely a compiler bug". `Steps.checkStageArity`
(`Pipeline/Steps.elm:280-287`) produces `"STAGE ARITY LIMIT\n..."`, a program limit (HEAP_078).

#### Fix
In that arm: `if String.startsWith "STAGE ARITY LIMIT" errorMessage then` a report titled
"STAGE ARITY LIMIT", summary "This program needs a closure bigger than Eco can build:", the message in
red, then: "After specialization, a function value holds one slot per parameter and per captured
variable, and every type a captured polymorphic local function is used at becomes a variable of its
own. To stay under the limit, move such a local function to the top level, where it is not captured,
or capture one record instead of many values." `else` the old report unchanged. (The per-closure
lines from `ValidateLimits.message` already give counts and the HEAP_078 limit.)
A cleaner alternative is a dedicated `GenerateStageArityLimit (List String)` constructor thrown by
`Generate.validateStageArityLimit`, but `GenerateTest` builds the error via
`GenerateMonomorphizationError`, so the test would need rewriting; the prefix check keeps it.

#### Also changes
None. HEAP_078 unchanged.

#### Risks
None (report text only). Title still contains "STAGE ARITY LIMIT" (the CLI test greps it).

#### Validation
GenerateTest 1/1; CLI case (2197-way specialisation, `--stack-size=7000`) passes.

#### Confidence
High.

---

### 6.7 `--output` extension (`Terminal/Make.parseOutput`)

#### Root cause
The plan's diagnosis is off: dispatch already is on the extension (`Make.elm:874-892`). The bug is a
bare extension: `hasExt` (`:1037-1039`) requires a non-empty stem, so `--output=.js` fails all three
checks and falls through to `ELF ".js"` (native lowering, which then fails).

#### Fix
After the `isDevNull` check:
`else if List.member (Utils.fpTakeFileName name) [ ".html", ".js", ".mlir" ] then Nothing`.
(Also rejects `out/.js`, which `hasExt` accepted as JS.) Update the `parseOutput` docstring.

#### Also changes
None. `Nothing` gives the standard bad-flag-value report with the examples, non-zero exit.

#### Risks
None.

#### Validation
MakeTest 3/3; CLI `--output=.js|.html|.mlir` rejected, non-zero, no NATIVE LOWERING.

#### Confidence
High.

---

### 6.8 Build and solver robustness

#### 6.8a Deleted imported module crashes

##### Root cause
`Builder/Build.elm:1245-1246` `handleCachedDepsStatus`: `DepsNotFound _ -> RBlocked` for an unchanged
(cached) module. The deleted module is `RNotFound` (not counted by `addErrors`, `:2312-2330`), the
importer is `RBlocked`, so no error is collected and `:3040` crashes with "Error from `Main` should
have been reported already."

##### Fix
Pass `resultDict` through: in `checkCachedModule` (`:1192-1196`) call
`checkDeps ... |> Task.andThen (handleCachedDepsStatus env resultDict root ...)` inside the
`readMVar` callback; add a `ResultDict` parameter. New arm:
```elm
DepsNotFound problems ->
    File.readUtf8 (Utils.fpCombine root path)
        |> Task.map (\source ->
            case Parse.fromByteString projectType source of
                Ok (Src.Module srcData) ->
                    Error.BadImports (toImportErrors env resultDict srcData.imports problems)
                        |> Error.Module name path time source |> RProblem
                Err err ->
                    Error.BadSyntax err |> Error.Module name path time source |> RProblem)
```
(as the reference compiler and `handleChangedDepsStatus`/`makeImportError` do). Update the docstring
(`:1205-1209`).

##### Risks
Only reached on the error path. Reads/parses the file once more there.

##### Validation
CLI case passes (MODULE NOT FOUND, no crash).

##### Confidence
High.

#### 6.8b Malformed `--local-package` elm.json is deleted

##### Root cause (exact code that deletes)
`Builder/Deps/Solver.elm:720`, `parseAndValidateCachedConstraints`, `Err _ -> File.remove ctx.path`.
`ctx.path` is `home ++ "/elm.json"` (`:656`), and for a local package `home` is
`Stuff.localPackageSource st.cache pkg` (`:641-643`), i.e. the user's own directory given to
`--local-package`. Reached via `getConstraints` -> `loadConstraintsFromCache` (`:704`). The deletion
then reports SolverBadCacheData ("I deleted the cached version"). No other `File.remove` /
`dirRemove*` in Builder touches a local source: `Details.elm:1323` removes only the cache copy
(`Stuff.package cache pkg vsn`).

##### Fix
- `ConstraintLoadContext` gains `isLocal : Bool` (= `localSource /= Nothing`, computed where `home`
  is).
- `Err _ -> if ctx.isLocal then Task.succeed (ISErr (Exit.SolverBadLocalOutline ctx.pkg ctx.path (localOutlineError bytes))) else <old remove + SolverBadCacheData>`,
  with `localOutlineError bytes = case D.fromByteString Outline.decoder bytes of Err e -> Just e; Ok _ -> Nothing`
  (Nothing = decodes but is an application).
- `Exit.Solver` gains `SolverBadLocalOutline Pkg.Name FilePath (Maybe (Decode.Error OutlineProblem))`;
  `toSolverReport`: `Just e` -> `Json.toReport path (Json.FailureToReport toOutlineProblemReport) e`
  with reason "I need the elm.json of the local package <pkg> (--local-package), but I ran into a
  problem with it."; `Nothing` -> "PROBLEM SOLVING PACKAGE CONSTRAINTS ... It describes an
  application, but a --local-package must be a package." Update the `Solver` and
  `parseAndValidateCachedConstraints` docstrings.

##### Also changes
`Exit.Solver` has no binary codec and only `toSolverReport` matches it (grep).

##### Risks
None for registry packages (path unchanged).

##### Validation
CLI case passes (file kept); by hand the report is a normal elm.json JSON error at the right
position.

##### Confidence
High.

#### 6.8c Ambiguous import with a package prints an absolute path

##### Root cause
`Build.elm:922-924` `crawlSinglePath`: `Import.Ambiguous path [] dep deps` with the absolute
`path`; the local/local case (`:906`) uses `Utils.fpMakeRelative root`.

##### Fix
Destructure `(Env envData) as env`; `Import.Ambiguous (Utils.fpMakeRelative envData.root path) [] dep deps`.

##### Validation / Confidence
CLI case passes. High.

#### 6.8d `--debug --debug` reported as an unknown flag
(See "Regression check": `tests/Terminal/LocalPackageFlagTest.elm` must change with this.)

##### Root cause
`Terminal/Terminal/Chomp.elm:637-664` `checkForUnknownFlags`: every leftover `-` chunk is
`FlagUnknown`; on/off chompers take only the first occurrence.

##### Fix
New `FlagError` constructor `FlagRepeated String` (`Terminal/Terminal/Internal.elm:263`). In
`checkForUnknownFlags`, take the chunk's name before `=`; if it is in `getFlagNames flags []` and not
`--help`, fail with `FlagRepeated (String.dropLeft 2 name)` (no completion suggestion); else
`FlagUnknown` as now. `Terminal/Terminal/Error.elm` new arm:
`flagErrorHelp "This flag was given more than once:" ("--" ++ name) [ reflow "Give it once." ]`.
Update docstrings of `checkForUnknownFlags` and `FlagError`.

##### Also changes
Only `Error.elm` matches `FlagError` (grep). Repeatable flags (`chompRepeatableFlag`) are unaffected:
they consume all occurrences before the check.

##### Risks
A repeat is still an error (plan's choice) rather than accepted silently; scripts that pass a flag
twice now get a clearer error than before (both failed).

##### Validation / Confidence
CLI case passes; by hand prints "This flag was given more than once: --debug". High.

#### 6.8e `make --docs` with files named ignores `--docs`

##### Root cause
`Terminal/Make.elm`: `maybeDocs` is only read by `buildExposed` (no-paths branch, `:634-638`).

##### Fix
`Exit.Make` gains `MakeDocsWithFileNames`; `makeToReport`: "CLASHING FLAGS" / "I cannot write --docs
when files are named." / "Documentation is written for a package's exposed modules, so run
`eco make --docs=docs.json` with no file names in a package." In `runHelpWithScope`, run
`checkDocsWithPaths paths maybeDocs` (throws when `paths` is non-empty and `maybeDocs` is `Just`)
before `getMode`. Update `Make` docstring.

##### Risks
Grep of scripts/CMake: the only `make --docs` (CMakeLists.txt:221, eco/system docs) names no files.
Exit code becomes non-zero for that (previously silently-ignored) combination.

##### Validation / Confidence
CLI case passes. High.

---

### Part 7: `compiler/bin/eco-io-handler.js`

All in `snapshots/review-bug-triage-fixes/part7-io-handler.diff`; tests run against the copy (15/15 pass; 0/15 on the original).

#### Root cause / Fix (per op)
1. `Console.readLine` (`:207-222`): `rl.close()` inside the `line` handler fires `close` synchronously,
   which answers `""` first. Fix: `answered` flag; respond to the line, then close; `close` answers `""`
   only if nothing was answered.
2. `Process.spawn`/`spawnProcess` (`:478-523`): no `'error'` listener; ENOENT is emitted on next tick
   and is uncaught; a handle was handed out regardless. Fix: helper `spawnChild`: if `child.pid ===
   undefined` (spawn failed; synchronous property), `child.once("error", e => respond(500,
   ioErrorBody(e)))` and hand out no handle; else continue synchronously (tests and Elm read the reply
   synchronously). Child stdin pipe also gets a no-op `error` listener (EPIPE).
3. `Process.wait` (`:525-536`): listener added only on wait; `code || 0`. Fix: `registerChild` stores
   `{child, status, waiters}` and listens for `exit` at spawn: `status = code ?? 128 + os.constants.signals[signal]`;
   wait answers at once if `status` is known, else queues; forgets the handle after answering (as now).
   Unknown handle still answers 0 (unchanged).
4. - `readAll` (`:224-233`): module state `idle|reading|ended`; a call after end answers `""`, one
     during reading answers `""` at end; only the first gets the data.
   - `File.lock`/`unlock` (`:327-337`): in-process exclusive lock: `Map path -> queue`; lock grants or
     queues; unlock hands the lock to the next waiter or deletes the entry. Cross-process exclusion is
     NOT provided (no flock in Node; a lock file risks stale locks) - state it in the comment and in
     `src-xhr/Eco/File.elm:215-240` docs. Deadlock review of all Elm lock sites
     (`Stuff.withRootLock*`, `withRegistryLock` at `Details.elm:1057,1334`,
     `Solver.elm:215,335,418,920`): no nested acquisition of the same path; `verifyAllDeps` holds the
     registry lock only while forking, and the forked `refreshLocalPackageIfStale` waits for it
     (released right after), so no deadlock.
   - `loadState` (`:570-573`): `saved === undefined ? null : saved`.
   - `MVar.drop` (`:590-594`): after answering, answer each queued waiter `500 {"error":"MVar <id> was
     dropped while waited on"}`; `read`/`take`/binary `put` on an unknown id answer 500 instead of
     throwing a TypeError.
   - `Http.fetch` (`:620-673`): `new URL` in try; bad URL and gzip/deflate decode errors answer
     `200 {value:{statusCode:0,statusText:<msg>,url}}` (Elm maps code 0 to `Network`; optional
     follow-up: a `kind` field + `src-xhr/Eco/Http.elm` decode to give `BadUrl`/`BodyDecode`, which
     `Eco.Http.Error` already has).
   - `Http.getArchive` (`:675-718`): resolve `Location` with `new URL(location, currentUrl)`, drain the
     redirect response, cap at 10 redirects (`{value:{error:"too many redirects from <url>"}}`), and
     guard `new URL` (bad URL -> error value).

#### Also changes
Docs in `compiler/src-xhr`: `Eco/Process.elm` `wait` (says signal death gives ExitSuccess and an
early-exited child never answers), `spawn*` (failed start), `Eco/File.elm` `lock`/`unlock` ("takes
no lock"). Native kernels still do not lock (unchanged; out of scope).

#### Risks
- MVar.drop answering waiters with 500 makes the Elm side crash (`orCrash`) where it used to hang
  silently. The Elm builder drops MVars only after reading all results (`Build.elm:390,458,626,717`,
  `Generate.elm:817`, `Build.elm:1685`), so no waiter is expected; all 18 CLI tests built fine with it.
  Not yet exercised: a JS-hosted self-compile (bootstrap stage 1) with the new handler - run
  `full`/bootstrap 4b once to confirm. Fallback if it bites: leave waiters unanswered (drop test then
  needs changing).
- File.lock now actually serialises concurrent builder threads on the same lock file; checked above.
- `Process.spawn` success path stays synchronous (Elm expects it).

#### Validation
Node handler tests 15/15 on the copy; all CLI tests (which run through the handler) pass with it.

#### Confidence
High for 1-3 and the 4 sub-items; medium for MVar.drop waiter behaviour until one JS self-compile /
`full` run uses it.

---

### Regression check (full elm-test suite, private copy)
Whole suite (14,499 tests, `--seed 1 --fuzz 1`), original src vs patched src: 59 -> 44 failures;
exactly the 15 target tests fixed, **no new failure**. (The other 44 belong to other Parts.)

One existing test pins the old 6.8d behaviour and must change with it (it also failed to compile,
since it matches `FlagError` exhaustively): `tests/Terminal/LocalPackageFlagTest.elm` - add a
`BadFlag (FlagRepeated name) -> "repeated: " ++ name` arm, change the test "a repeated ordinary flag
is still rejected as unknown" to expect `Err "repeated: local-package"` (renamed "... is rejected as
repeated"), and its header lines 31-32. Diff: `/tmp/lw-builder/tests.diff`.

CLI tests ran with the guida.js built before the `ObjectFirstField` addition; that addition was then
checked by hand through a rebuilt guida.js and by the full unit suite above.

## Part 8: flaky test — `WebSocketDeflateBombTest` (JS E2E)

Seen 2026-10-28 in `run-js-e2e` (passed in every earlier run that day; unrelated to Part 1, since
JS E2E compiles with stock elm and runs on node):

```
streamed: stalled bounded True; after cancel bounded False; next Text "after"; end Closed (868, 33984 KiB)
```

### Root cause

`test/eco-system/src/WebSocketDeflateBombTest.elm`, streamed mode: after cancelling a 200 MiB
deflate bomb the test asserts the process grew by less than 32 MiB, measured as a difference of
`W.rssKiB` readings. On node, RSS depends on when V8 collects and returns memory, so the reading
after the cancel can land just over the bound (33,984 KiB here) even though inflation is bounded.
The whole-mode check already handles the same effect by measuring on a second, warmed-up run.

### Fix

Make the streamed bound measure retained growth, not GC timing. In order of preference:
1. Measure on a warmed-up second run, as whole mode does, and take the reading after the next
   message arrives (the stream is quiescent then) rather than right after the cancel.
2. If node still overshoots, request a collection before the reading when the host allows it
   (node `--expose-gc` in the JS E2E runner for this test) — native is unaffected.
3. Only if neither suffices: give the JS backend a larger streamed bound than native (e.g.
   48 MiB), with a comment; the property under test (bounded, not proportional to the 200 MiB
   bomb) still holds by a wide margin.

### Validation

Run the test 20 times in a loop under `run-js-e2e`'s node command (outside the shared suite) and
on native; all must pass. The streamed bound must still fail if inflation is made unbounded
(negative control: temporarily lift the stall in the server and confirm `bounded False`).
