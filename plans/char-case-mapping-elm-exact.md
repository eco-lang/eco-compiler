---
status: done
updated: 2026-10-28
---

# Elm-exact Char and String case mapping with an encoded Char range

## Why

`Char` is a 32-bit code point now (plans/review-bug-triage-fixes.md Part 1, done 2026-10-28).
`Char.toUpper`, `toLower`, `toLocaleUpper` and `toLocaleLower`
(`elm-kernel-cpp/src/core/Char.cpp:61-141`, `CharExports.cpp:34-52`) and `String.toUpper` and
`toLower` (`runtime/src/allocator/StringOps.hpp:791-866`) are still ASCII-only. Every non-ASCII
letter is left unchanged, where Elm maps it.

Elm-on-JS implements the Char functions as `_Utils_chr(char.toUpperCase())`, which is JavaScript's
full Unicode case mapping applied to the Char's string. For 103 code points that mapping gives
more than one code point (`'ß'` -> `"SS"`, `'ﬁ'` -> `"FI"`, `'ΐ'` -> 3 code points, `toLower 'İ'`
-> `"i̇"`), and Elm returns the multi-code-point string as a `Char`. Programs can observe this:
`String.map Char.toUpper "straße" == "STRASSE"`, `Char.toCode (Char.toUpper 'ß') == 83` and
`Char.toUpper 'ß' /= 'S'`. `String.toUpper`/`toLower` are `str.toUpperCase()`/`toLowerCase()`.
Elm guarantees `String.fromList (List.map Char.toUpper (String.toList s)) == String.toUpper s`,
and the same for `toLower` when `s` has no Σ in a word-final position.

Goal: reproduce Elm's behaviour exactly, for the Char functions and the String functions
together, while keeping `Char` a fixed 32-bit value. Multi-code-point results are encoded in the
range above 0x10FFFF.

## Reference semantics (what "exactly" means)

The reference is **Elm 0.19.1 with stock elm/core 1.0.5, compiled with `--optimize`, run on the
node that the JS E2E runner uses, with the default locale**. At the time of writing that node is
v22.23.3, with Unicode 17.0 and ICU 78.3 (`node -p process.versions`).

Under `--optimize` a Char is a primitive JS string. That makes `==` string equality, `compare`
UTF-16 string comparison, and `case` a strict string match.

The reference is `--optimize` and not debug mode because the two modes differ for these values.
In debug mode (`run-js-e2e.js:440-442` compiles without `--optimize`), `_Utils_chr` returns
`new String(c)`, and `_Utils_eqHelp` walks `for (var key in x)`. For two Chars that tests only
that `x` is a prefix of `y`. So `'S' == Char.toUpper 'ß'` is `True` in debug mode, while
`Char.toUpper 'ß' == 'S'` is `False`. The same holds for `List.member` and for structural
equality of containers. It also already affects ordinary Chars: a lone high surrogate
`fromCode 0xD83D` "equals" `'😀'`. Under `--optimize` both orders give `False`.

Eco implements the `--optimize` meaning: Char `==` is integer equality, and the encoding below
gives equal integers exactly for equal strings. The debug-mode prefix rule is a documented
divergence. Comparison (`_Utils_cmp`), `case`, the String kernels and the Char kernels behave the
same in both modes.

Conformance tests are recorded in debug mode, because `Debug.log` is rejected under `--optimize`.
So they must not contain a mode-dependent equality. Step 0.3 enforces this mechanically: a JS
guard throws whenever debug-mode Char equality differs from `--optimize` Char equality.

## Verified facts (node 22.23.3, Unicode 17.0)

Each of these was reproduced for this plan with node scripts over all code points 0..0x10FFFF,
excluding surrogates. The generator (Step 1) re-asserts every one of them on every run.

- **Multi-code-point mappings.**
  - 103 code points have one: 102 under `toUpperCase`, 1 under `toLowerCase` (U+0130 `İ` gives
    U+0069 U+0307).
  - They produce 73 distinct strings. 30 strings are shared: U+1FB3 `ᾳ` and U+1FBC `ᾼ` both give
    "ΑΙ" (U+0391 U+0399), and U+0390 and U+1FD3 both give U+0399 U+0308 U+0301.
- **Closure.** Applying `toUpperCase`/`toLowerCase` repeatedly to those strings gives **146
  distinct strings** in total.
  - Each is 2 or 3 code points long. Every code point is in the BMP and ≤ U+1FFA, so it is below
    U+D800 and is one UTF-16 unit.
  - No closure string maps to a single code point.
  - Mapping a whole closure string equals mapping each of its code points and concatenating the
    results (no context effects). No closure string contains Σ.
- **Single-code-point mappings.**
  - 1,478 code points map to a different single code point under `toUpperCase`, 26 of them ASCII.
  - 1,487 do under `toLowerCase`, 26 of them ASCII.
- **Context.**
  - `toUpperCase` of any string equals the concatenation of per-code-point `toUpperCase`.
    Checked for every code point X in the string `"a" + X + "b" + X`.
  - `toLowerCase` does the same except for U+03A3 Σ, the default `Final_Sigma` rule:
    `"ΑΣ".toLowerCase()` gives "ας", while a lone `"Σ"` gives "σ".
  - The rule as V8/ICU apply it (verified on 59,856 context strings and on all 268 code points
    that are both Cased and Case_Ignorable):
    - Σ becomes ς (U+03C2) iff scanning backwards from Σ and skipping every Case_Ignorable code
      point reaches a Cased code point, and scanning forwards and skipping every Case_Ignorable
      code point does **not** reach a Cased code point. Otherwise Σ becomes σ (U+03C3).
    - The skip is greedy: a code point that is both Cased and Case_Ignorable, such as U+02B0 `ʰ`,
      is skipped, not counted as cased. `"ʰΣ"` gives "ʰσ" and `"ΑΣʰ"` gives "αςʰ".
  - \p{Cased} is 158 ranges and \p{Case_Ignorable} is 464 ranges.
- **Locale.** `toLocaleUpperCase()`/`toLocaleLowerCase()` with no argument ignore the process
  locale on node: under `LC_ALL=tr_TR.UTF-8` the Intl default locale is `tr-TR`, yet
  `'i'.toLocaleUpperCase()` is still `'I'`. Only an explicit `'tr'` argument gives `'İ'`. So on
  the JS harness `toLocale*` equals `toUpper`/`toLower`.
- **Not Python.** Python's `unicodedata` here is Unicode 14.0, and the only `SpecialCasing.txt`
  on disk is Perl's (14.x). Python's `str.upper/lower` differs from node on 110 code points
  (U+019B -> U+A7DC, U+0264 -> U+A7CB, ...). The tables must therefore come from node itself.

## Design

### Char value encoding

A Char value `v` is a `u32` (MLIR `i32`) of one of two kinds:

| Value | Meaning |
|---|---|
| `v <= 0x10FFFF` (bits 21-31 zero) | an ordinary code point, unchanged from today |
| `0x110000 <= v <= 0x1FFFFF` | never produced; a writer that meets one emits U+FFFD (defensive) |
| `0x200000 <= v <= 0x1FFFFFFF` | **encoded**: bits 0-20 = the expansion's first code point, bits 21-28 = `rank + 1` |
| `v >= 0x20000000` (any of bits 29-31 set) | **reserved**; never produced. Bits 29-31 are always zero |

`rank` indexes `CaseMap::kEntries`, the 146 closure strings sorted by code-point sequence (see the
table below). The table has exactly one entry per distinct string, so equal strings get equal
values.

The layout claims whole bit fields:

```
 31   29 28        21 20                   0
┌───────┬────────────┬──────────────────────┐
│ 0 0 0 │ rank+1 (8) │ code point (21 b)    │
└───────┴────────────┴──────────────────────┘
```

The rank field is 8 bits, so at most 255 entries; 146 are used. Bits 29-31 are reserved and must
be zero, which keeps every Char value a non-negative `i32` and leaves them free for later use. The
generator asserts `kEntryCount <= 255`. If Unicode ever exceeds that, widening the field into the
reserved bits is a header-only change: `isEncoded`, `toCode` and `sortKey` do not depend on its
width, only on the reserved bits being zero.

Examples (Unicode 17.0 ranks):

| Expansion | Value |
|---|---|
| "SS" | `0x1400053` (rank 9) |
| "ss" | `0x3000073` (rank 23) |
| "FI" | `0x0A00046` (rank 4) |
| "ΑΙ" | `0x4800391` (rank 35) |
| "i̇" | `0x2C00069` (rank 21) |
| "Ϊ́" | `0x5200399` (rank 40) |

Code and tests outside the generated header must not hard-code ranks. Codegen tests use synthetic
encoded values (any first code point with any rank).

Only `Char.toUpper`/`toLower`/`toLocaleUpper`/`toLocaleLower` produce encoded values. Char
literals, `Char.fromCode`/`eco.char.fromInt` (still U+FFFD outside 0..0x10FFFF), `String.toList`,
`uncons`, the folds and `any`/`all`, `String.map`'s callback argument, elm/parser and JSON
decoding produce only ordinary code points.

**Operations on Char values:**

- **`Char.toCode v`** = `v & 0x1FFFFF`, one AND with no branch and no table. This equals Elm's
  `charCodeAt(0)` plus surrogate join, because the first code point is BMP and non-surrogate.
- **Ordering** compares `charSortKey(v) = rotl32(v, 11) = (v << 11) | (v >> 21)` as unsigned
  integers. For an ordinary `v` this is `cp << 11`. For an encoded `v` it is
  `(first << 11) | (rank + 1)`. So it orders by (first code point, then 0 for ordinary or
  rank + 1 for encoded). Why this equals JS UTF-16 string order (checked exhaustively for
  263,770,081 ordered pairs):
  - Encoded vs encoded: expansions are BMP below U+D800, so UTF-16 order equals code-point
    sequence order. Ranks are assigned in that order and the first code point is the most
    significant part of the rank order.
  - Ordinary `c` vs encoded `e` with first code point `f`:
    - If `c < f`, then `c`'s first unit is below `f`'s unit, or `c` is a BMP unit below it.
      Either way JS says less, and so does the key.
    - If `c == f`, the string `c` is a proper prefix of `e`, so JS says less. The key gives
      rank + 1 >= 1 > 0, which also says less.
    - If `c > f` (including astral and surrogate `c`, whose first unit is >= 0xD800 > f), JS
      says greater, and so does the key.
  - Ordinary vs ordinary: keeps eco's code-point order. This is the existing documented
    divergence from JS between U+E000..U+FFFF and astral code points (`Utils.cpp:346-349`,
    review-bug-triage-fixes.md). Encoded values are never involved in it.
- **`==` / `/=`**: integer equality. It agrees with `--optimize`, for example
  `toUpper 'ᾳ' == toUpper 'ᾼ'` is `True` and `toUpper 'ß' == 'S'` is `False`. It agrees with
  `compare v w == EQ` because entries are unique, so Dict, Set and `==` stay consistent.
- **`case` on Char literals**: integer match. An encoded value never matches a literal, which is
  what JS does (`"SS"` is not `'S'`).
- **Writing into a String**, through `String.fromChar`, `cons`, `fromList` and `map`'s callback
  result: the entry's 2-3 UTF-16 units.
- **`Debug.log` / `Debug.toString`**: `'` + expansion + `'`, for example `'SS'`.
- **`toUpper`/`toLower` of an encoded value**: `kEntries[rank].upper/.lower`. The closure makes
  this total.
- **`isUpper`, `isLower`, `isAlpha`, `isDigit`, ...**: elm/core Elm code over `toCode`, so these
  test the first code point, as in Elm. No change is needed.

### Tables (generated)

The generator is `compiler/scripts/gen-casemap-tables.mjs`, run with node. It sits beside the
Part 2 generator `compiler/scripts/gen-unicode-classes.py` and uses the same conventions:

- output on stdout;
- a "generated, do not edit" header that names the Unicode version;
- the generator command in the header.

Its output is `runtime/src/allocator/CaseMapTables.hpp`. The header is header-only and uses
`inline constexpr`, so no CMake source lists change (the allocator sources are listed three
times in `runtime/src/codegen/CMakeLists.txt:507/611/697`). The layout:

```cpp
// GENERATED by `node compiler/scripts/gen-casemap-tables.mjs > runtime/src/allocator/CaseMapTables.hpp`
// from node v22.23.3 (Unicode 17.0, ICU 78.3). Do not edit; see plans/char-case-mapping-elm-exact.md.
#pragma once
#include <cstdint>
namespace Elm::CaseMap {
inline constexpr const char* kUnicodeVersion = "17.0";   // process.versions.unicode
inline constexpr const char* kIcuVersion     = "78.3";   // informational
inline constexpr const char* kNodeVersion    = "22.23.3";// informational
inline constexpr uint32_t kEntryCount = 146;
inline constexpr uint32_t kMaxExpansionUnits = 3;
// One entry per distinct multi-code-point case-mapping string; index = rank; sorted by
// code-point sequence (a proper prefix first). upper/lower are Char values (ordinary or encoded).
struct Entry { uint16_t units[3]; uint8_t len; uint8_t pad; uint32_t upper; uint32_t lower; }; // 16 B
inline constexpr Entry kEntries[146] = { { {0x0041,0x02BE,0}, 2, 0, 0x..., 0x... }, ... };
// Non-identity mappings for code points >= 0x80 (ASCII is the callers' fast path), sorted by
// `from`; `to` is a Char value, encoded when the full mapping has more than one code point.
struct Pair { uint32_t from; uint32_t to; };                                   // 8 B
inline constexpr Pair kUpper[1554] = { ... };   // 1,452 single + 102 encoded
inline constexpr Pair kLower[1462] = { ... };   // 1,461 single + 1 encoded (U+0130)
// Inclusive code-point ranges for String.toLower's Final_Sigma rule.
struct Range { uint32_t lo; uint32_t hi; };                                    // 8 B
inline constexpr Range kCased[158] = { ... };
inline constexpr Range kCaseIgnorable[464] = { ... };
}  // namespace Elm::CaseMap
```

The array sizes are the Unicode 17.0 counts. The generator prints the actual counts to stderr.
The data totals about 31.9 KB: kUpper 12.4 KB, kLower 11.7 KB, kEntries 2.3 KB, kCased 1.3 KB,
kCaseIgnorable 3.7 KB.

**Generator algorithm** (all string operations are node's own, so the tables are node's
behaviour by construction):

1. For every `c` in 0..0x10FFFF except 0xD800..0xDFFF, let `s = String.fromCodePoint(c)`,
   `U = s.toUpperCase()` and `L = s.toLowerCase()`. A result with more than one code point goes
   into the set `E`.
2. Closure. Use a worklist over `E`. For each `e` and each of `toUpperCase` and `toLowerCase`:
   - let `t = f(e)`;
   - assert that `t` equals the concatenation of `f` over `e`'s code points;
   - if `t` has more than one code point and is not in `E`, add it to `E`.
   Run to the fixed point.
3. Assert, failing with a message:
   - every code point of every `e` is < 0xD800;
   - every `e` has 2 or 3 code points (`kMaxExpansionUnits`; if 4 ever appears, the message says
     to raise the constant and every `kMaxCharUnits` buffer);
   - `|E| <= 255` (the 8-bit rank field);
   - no `e` contains U+03A3;
   - `'Σ'.toLowerCase() === 'σ'`.
4. Sort `E` by code-point sequence, with a proper prefix first. Assert that JS `<` agrees on every
   consecutive pair. Then `rank(e)` is the index.
5. `value(str)` is the code point if `str` has one code point, else
   `(firstCp | ((rank + 1) << 21)) >>> 0`; assert the result is below `0x20000000` (bits 29-31
   clear).
6. Build `kUpper`/`kLower`: one `{c, value(U)}` for every `c >= 0x80` with `U !== s`, likewise for
   `L`. Build `kEntries[rank] = {units, len, value(e.toUpperCase()), value(e.toLowerCase())}`.
7. Build `kCased`/`kCaseIgnorable` from `/^\p{Cased}$/u` and `/^\p{Case_Ignorable}$/u` over all
   non-surrogate code points, merged into ranges.
8. Self-test Final_Sigma.
   - Implement the rule above in the generator over the ranges from step 7.
   - Compare it with `toLowerCase()` on these strings, for every range endpoint X of both tables
     plus U+0020, U+0031 and U+002E, and every Y in {A, α, space, ', ., U+0301}:
     `X+Σ`, `Σ+X`, `Y+Σ+X`, `X+Σ+Y`, `Y+X+Σ`, `Σ+X+Y`, `X+Σ+Σ`, `Y+Σ+X+Y`.
   - Also compare on `X+Σ` and `ΑΣ+X` for every code point that is both Cased and
     Case_Ignorable.
   - Any mismatch fails.
9. Self-test context-freedom. For every `c` (as step 1), `("a"+X+"b"+X).toUpperCase()` must equal
   the per-code-point concatenation, and `toLowerCase()` must too when `c !== 0x3A3`.
10. Emit the header.

**Modes.**

- With no arguments the generator prints the header.
- `--check <path>` regenerates in memory and exits 1 in two cases:
  - The running node's `process.versions.unicode` differs from the file's `kUnicodeVersion`. The
    message says: "node X has Unicode A, tables are Unicode B: use a node with Unicode B or
    regenerate the tables (and re-record the conformance tests)".
  - The bytes differ, apart from the informational node/ICU lines. This catches an ICU fix
    within one Unicode version.

The generator takes about 10 s (four passes over 1.1M code points).

**The Unicode 14 parser tables (Part 2).** `compiler/src/Compiler/Parse/Unicode.elm` is Unicode
14.0 from Python, and the case tables will be 17.0 from node. **Leave the parser tables as they
are.** They model a different reference: upstream Elm's identifier classes, which come from the
GHC that built the upstream compiler (see that module's doc). These tables model elm/core on
node. Nothing connects the two: the parser classes decide what is an identifier at compile time,
and the case tables decide what Char functions return at run time. "Shared approach" here means:

- both generators live in `compiler/scripts/`;
- both stamp their Unicode version in the generated file;
- both are named in `design_docs/theory/kernels/elm-kernel.md`.

Follow-up (not in this plan): give `gen-unicode-classes.py` a `--check` mode too, and decide
whether it should pin a Python/Unicode version.

### Build flag `ECO_CHAR_CASE_EXPANSION` (default ON)

The encoding adds a branch to a few Char consumers. The flag decides at compile time whether
that branch exists at all. ON (the default, and the only setting the tests pin) is everything
this plan describes. OFF compiles every encoded-value path out of the C++ and gives
**single-code-point case mapping**: each code point maps to its full Unicode mapping when that is
one code point, and is left unchanged when it would expand. So é→É and ж→Ж as with ON, but ß, ﬁ,
ΐ, ᾳ and İ (the 103 expanding code points) map to themselves. This is not Unicode's "simple"
mapping (that would give ᾳ→ᾼ and İ→i); it is "ON minus the expansions", which is what the tables
give without extra data. OFF still beats today's ASCII-only behaviour, keeps `String.toUpper`
equal to mapping `Char.toUpper` (the String functions use the same per-code-point lookups), and
keeps Final_Sigma (σ/ς are single code points).

**Mechanism.** One CMake option, one `constexpr`, `if constexpr` at the sites. No `#ifdef` around
code: in non-template code both arms of an `if constexpr` are still parsed and type-checked in
every build, so the OFF arm cannot rot unseen while only ON is built. The discarded arm emits no
code.

- Root `CMakeLists.txt`, beside the `ECO_P1_CENSUS` option (`:120-131`), same pattern:

  ```cmake
  # Elm-exact multi-code-point Char case mapping (plans/char-case-mapping-elm-exact.md, KERN_008).
  # OFF compiles the encoded-Char paths out and leaves expanding code points (ß, ﬁ, ...) unchanged.
  option(ECO_CHAR_CASE_EXPANSION "Elm-exact multi-code-point Char case mapping" ON)
  if(ECO_CHAR_CASE_EXPANSION)
      add_compile_definitions(ECO_CHAR_CASE_EXPANSION=1)
  else()
      add_compile_definitions(ECO_CHAR_CASE_EXPANSION=0)
  endif()
  ```

  It must come before the first `add_subdirectory`, so that the runtime, kernels, codegen, JIT,
  tools and tests all see the same value.
- `CharValue.hpp` is the only place that reads the macro:

  ```cpp
  #ifndef ECO_CHAR_CASE_EXPANSION
  #error "ECO_CHAR_CASE_EXPANSION is not defined: this file is compiled outside the CMake build"
  #endif
  inline constexpr bool kExpansions = ECO_CHAR_CASE_EXPANSION != 0;
  ```

  The `#error` catches any compile path that bypasses the root definitions (a hand-written
  compile command, or a bitcode rule with its own flags) instead of silently picking a default.
- **Most sites need no explicit `if constexpr`**, because the predicates fold:
  - `hasRankBits(v)` = `v > kFirstMask` is the raw bit test. Only the table code uses it
    (`CaseMap::upper/lower` and `CaseMapTest`).
  - `isEncoded(v)` = `kExpansions && hasRankBits(v)`. With OFF it is the constant `false`, so
    everything guarded by it (`writeUnits`'s encoded arm, `entry()`, `print_char`'s expansion
    arm) is dead code that the compiler drops.
  - `firstCodePoint(v)`: `if constexpr (kExpansions) return v & kFirstMask; else return v;`
  - `sortKey(v)`: `if constexpr (kExpansions) return rotl32; else return v;`. So `compare` and
    every kernel compare that uses it become today's plain compare.
  - `kMaxCharUnits` = `kExpansions ? 3 : 2`, so OFF keeps today's two-unit buffers.
- **Explicit `if constexpr` sites** (the code that emits or looks up, not consumes):
  - `EcoToLLVMArith.cpp` (2c): `CharToIntOpLowering` emits the `andi` only when ON;
    `charSortKey` returns `x` unchanged when OFF, so the comparison lowerings emit today's IR.
    This is a compile-time choice of the compiler binary, made in its C++. The Elm front end and
    the `.mlir` it writes are the same for both settings.
  - `CaseMap::upper/lower` (Step 3): after the lookup, `if constexpr (!kExpansions)` return `v`
    when `hasRankBits(to)`. The tables are the same for both settings (one generator, one
    header, one `--check`). With OFF, `kEntries` is never referenced and the linker drops it.
- **Build-mismatch guard.** No persistent cache holds lowered code: the JIT includes
  `ObjectCache.h` but installs no cache, the AOT runner re-lowers on every run, and the `~/.eco`
  package artifacts are typed Elm (no lowering), so the setting does not need to be in a cache
  key. What can go wrong is linking a program lowered by one build tree against the runtime
  libraries of another. Lowered as OFF and run with an ON runtime, encoded values would compare as
  raw integers. (The reverse is harmless: an OFF runtime never produces them.) The guard follows
  the `eco_enable_list_chunks` precedent (`EcoToLLVM.cpp:251-270`):
  - the runtime defines exactly one of `extern "C" void eco_char_case_expansion_on()` /
    `eco_char_case_expansion_off()` (an empty function, in `CaseMap.cpp` or beside
    `eco_enable_list_chunks`), chosen by `kExpansions`;
  - the lowering injects `call @eco_char_case_expansion_on()` (or `_off`) at the top of `@main`,
    `gcLeaf = true`, in every module that has a `@main`;
  - a mismatch is an undefined symbol at link time (AOT) or a symbol-resolution failure (JIT),
    naming the setting. The cost is one empty call at start-up.
- **Tests.** Only the default (ON) is tested; OFF is not pinned with tests (the conformance tests
  would all need a second, OFF-only expectation). The `if constexpr` arms keep OFF type-checked in
  the ON build. OFF is built once in this plan, as the performance gate's A arm (below), and that
  build must compile; its `full` may fail only the tests that feed or expect encoded values (the
  two `*_encoded.mlir` fixtures, and after Step 3 the conformance tests).

### Locale variants

`toLocaleUpper`/`toLocaleLower` use the default tables (option (a)). This matches Elm-on-node
exactly (see Verified facts). In a browser with a Turkish, Azeri or Lithuanian locale, Elm would
apply that locale's conditional mappings; eco does not. That is a documented divergence, and
option (b), locale tables keyed by a runtime locale, is a follow-up. Conformance tests of
`toLocale*` use only inputs whose result is the same in every locale (no i/I/İ/ı, no
Lithuanian dot cases), so they are host-independent.

### Divergences that remain (document them, do not test them)

1. Debug-mode `==` prefix asymmetry (see Reference semantics). Eco implements `--optimize`.
2. Ordering of ordinary Chars U+E000..U+FFFF against astral Chars (existing).
3. Lone surrogates are never glued to a neighbour (existing).
4. `Elm_Kernel_Json_wrap_Char` (`JsonExports.cpp:1838`) encodes a Char as an integer, so an
   encoded value would come out as its raw integer.
   - Elm-on-JS would give a JSON string in both modes.
   - It is unreachable from Elm source: `Json.Encode` applies `Elm.Kernel.Json.wrap` only at
     String, Int, Float, Bool, null, list/array and object (`Json/Encode.elm:80-222`), and ports
     cannot carry Char.
   - Editing `JsonExports.cpp` would force 33 LSS_022 re-audits for no observable change, so it is
     not edited. Record the divergence in `elm-kernel.md`.
5. `toLocale*` in a browser with a non-default locale (above).
6. Existing Debug-printer differences: eco prints a String's non-ASCII units as `\uXXXX`
   (`RuntimeExports.cpp:3087-3125`), and Chars' control characters differ from
   `_Debug_addSlashes`. Conformance tests therefore print ASCII only.
7. Unicode version drift: eco's tables are fixed at generation, while Elm-on-JS follows the
   engine that runs it.

## Steps

Each step ends with the tree green. The one exception is Step 0, whose new native conformance
tests are expected to fail; they are marked `XFAIL-NATIVE` so that `full` stays green while still
showing them as failures.

Running tests follows CLAUDE.md. Run each gate command once, as
`<cmd> 2>&1 | tee /tmp/test_output.txt`, and read the file afterwards. Run the test binaries with
`ulimit -c 0`, because the validate unit suite's negative controls dump cores. Before trusting E2E
results after a compiler (Elm) change, wipe `build/test/*/eco-stuff` and the
`~/.eco/0.1.3/packages/**/artifacts.dat` caches (MEMORY: e2e stale caches).

### Step 0 — dual-target conformance tests, red on eco, green on Elm

**0.1 `-- XFAIL-NATIVE: <reason>` directive (native harnesses only).**

- `test/CheckPatterns.hpp`:
  - Next to `hostSkipReason` (`:740-757`), add
    `std::optional<std::string> xfailNativeReason(const std::string& content)`. It uses
    `detail::forEachDirectiveLine` with marker `"-- XFAIL-NATIVE:"`, takes the first occurrence,
    trims it, and gives `"no reason given"` when the reason is blank.
  - Document it in the directive comment block (`:656-672`).
- `test/ElmE2ETestBase.hpp`, `runMlirTestsParallel` (`:1053-1139`):
  - Next to `processMode` (`:1086-1094`), read `xfail[i] = xfailNativeReason(readFile(elmPaths[i]))`.
  - In the verdict lambda (`:1112-1132`), after `v` is final on both branches:
    - If `xfail[i]` and `!v.passed`: set `v.passed = true`, keep `v.error`, and mark the verdict
      as expected-fail. Extend `eco_test::ChildVerdict` in `test/SpawnedChildren.hpp` with
      `std::string note`, printed after `PASS` as `PASS (XFAIL: <reason>) -- <first error line>`.
    - If `xfail[i]` and `v.passed`: set `v.passed = false` and
      `v.error = "XPASS: the test passes natively; remove its -- XFAIL-NATIVE line"`.
  - Add `size_t xfailCount` to `ParallelTestSummary` (`test/IsolatedTestRunner.hpp:46`) and print
    it in the suite summary.
  - A compile failure (`runFiltered` `:1299-1304`) stays a failure even with XFAIL. Only a
    behaviour mismatch is "expected".
- `test/aot_e2e_main.cpp`: after a test's `r.passed` is computed (`:440-465`), apply the same rule
  using the source read in `discover_all` (`:189-224`, store the reason in `TestCase`). Print
  `XFAIL` or `XPASS` at the result print (`:626-632`), and count XFAILs in the summary (`:668-679`).
- `test/scripts/run-js-e2e.js` ignores the directive (on JS the test must pass). It is not a
  `CHECK-` variant, so the parser at `:120-140` already passes over it.
- Docs: `design_docs/theory/verification/program-tests.md` §"What the directives say" item 3
  (`:45`), and `design_docs/theory/verification/verification.md:155`.

**0.2 Multiple projects in `run-js-e2e.js`.**

Today the runner hard-codes one project:

- source directory `test/eco-system` (`:337`);
- a single mirror `<build>/test/js-e2e/project` that deletes any `src/*.elm` not in its source
  list (`:351-363`);
- filter prefix `'eco-system/'` (`:374`);
- `--local-package eco/system=...` on every compile (`:440-442`).

Refactor `main()` (`:334-495`) into `runProject(spec, opts, server)`, called for each entry of:

```js
const PROJECTS = [
  { name: 'eco-system', dir: 'test/eco-system',
    localPackages: ['eco/system=' + path.join(repo, 'system-kernel-cpp')],
    sharedInputs: [path.join(repo, 'system-kernel-cpp', 'src'), path.join(repo, 'system-kernel-cpp', 'elm.json')],
    modeGuard: false, allowSkipJs: true },
  { name: 'elm-conformance', dir: 'test/elm-conformance',
    localPackages: [], sharedInputs: [],
    modeGuard: true, allowSkipJs: false },
];
```

- Each project gets its own `<build>/test/js-e2e/<name>/project` and `<build>/test/js-e2e/<name>/out`.
  The old `<build>/test/js-e2e/{project,out}` become unused; the runner deletes them once if
  present. Each project also gets its own first seeding compile (`:458-461`).
- The filter prefix is `spec.name + '/'`, and the `--local-package` arguments come from
  `spec.localPackages`.
- The `shared` mtime (`:428-435`) uses `spec.sharedInputs`.
- Summaries print per project and as a total. The exit status is 1 if any project fails.
- New option `--project <name>[,<name>]`: default all.
- `allowSkipJs: false`: a `-- SKIP-JS:` line in a conformance test is a failure ("conformance
  tests must run on both targets").
- The HTTP test server is shared, and the conformance tests never use it.
- Update the header comment (`:1-37`) and the comment above `run-js-e2e` in
  `compiler/CMakeLists.txt:258-263`. The target itself is unchanged and runs every project.

**0.3 Mode guard (conformance project only).** After a successful compile, `patchModeGuard(jsFile)`
edits the compiled file as follows.

1. Rename the one definition `function _Utils_eqHelp(x, y, depth, stack)` (stock elm/core
   `Utils.js`; it is at line 545 of a current `out/*.js`) to `function _Utils_eqHelp_raw(x, y, depth, stack)`.
2. Insert before it:

```js
/* eco-conformance mode guard */
function _Utils_eqHelp(x, y, depth, stack) {
	var r = _Utils_eqHelp_raw(x, y, depth, stack);
	if (x instanceof String && y instanceof String && r !== (x.valueOf() === y.valueOf()))
		throw new Error('eco-conformance: Char equality differs between debug and --optimize: '
			+ JSON.stringify(x.valueOf()) + ' == ' + JSON.stringify(y.valueOf()));
	return r;
}
```

The raw function's recursive calls go through the wrapper, so nested Chars are checked too.

- If the definition does not occur exactly once, the patch fails with "stock elm/core Utils.js
  changed; update patchModeGuard".
- The marker comment makes the patch idempotent.
- In debug builds only Chars are `String` objects (Elm Strings are primitives), so the guard
  concerns only Chars.

**0.4 Recording expectations from Elm.** Add `--record <TestName>` (requires `--project`). It
compiles the test (applying the mode guard), runs it like a normal test, and then prints each
non-empty output line as `-- CHECK: <line>`, in output order. It exits non-zero in three cases:

- the run's exit status differs from `-- EXIT:` (default 0);
- the run throws;
- a line contains a non-ASCII character. The message says "print code points, not text":
  eco's Debug printer escapes non-ASCII String units.

The author pastes the lines into the test.

**0.5 The conformance project and its native registration.**

- `test/elm-conformance/elm.json`: an application with `elm/core 1.0.5` direct and
  `elm/json 1.1.3` indirect (`Builder/Elm/Outline.elm:375-379` rejects an application without
  elm/json), with `"source-directories": ["src"]`, no Html.
- The directory name is the one the user chose. Its `elm.json` description and this plan say that
  it is unrelated to `test/conformance` (Autobahn/h2spec).
- Test shape: `main : Program () () ()` via `Platform.worker`, with all `Debug.log` calls in a
  top-level `report : ()` value that `init` returns as the model. Precedent:
  `test/elm-core/src/ProcessSpawnRecursiveTest.elm`.
  - `main = text ...` cannot be used: the JS launcher calls `Elm.<Name>.init()` with no node
    (`run-js-e2e.js:327-330`), and there is no elm/html.
- Output rules:
  - every logged value is a `String` built by the test, so every CHECK ends at a closing quote and
    cannot match a longer value;
  - output is ASCII only;
  - every label is unique.
- Helper module `test/elm-conformance/src/ConformanceHelp.elm` (no `main`) exposes:
  - `cps : String -> String`, the code points as upper-case hex joined by spaces (`"53 53"`);
  - `charCps : Char -> String` = `cps (String.fromChar c)`;
  - `mix : Int -> Int -> Int` = `\h v -> modBy 2147483629 (h * 31 + v + 1)`. It stays below
    2^36, which is exact in JS doubles and in eco's Int64. It uses no `Bitwise` (eco's is 64-bit)
    and no `//` (32-bit in Elm JS).
  - `hashString : Int -> String -> Int` folds `mix` over `Char.toCode` of each Char, then mixes in
    `String.length`.
- Native registration:
  1. `test/CMakeLists.txt:15-29`: add `elm-conformance` to `ELM_TEST_PACKAGES` (creates the JIT
     and AOT build-tree shadows).
  2. New `test/elm-conformance/ElmConformanceTest.hpp`, in the pattern of
     `test/elm-core/ElmCoreTest.hpp`:
     `ElmE2EBase::buildTestSuite("elm-conformance", "Elm Conformance E2E", "elm-conformance/")`
     in output mode (not process-output).
  3. `test/main.cpp`: `#include "elm-conformance/ElmConformanceTest.hpp"` (beside `:84-91`),
     `auto elmConformanceTests = ElmConformanceTest::buildElmConformanceTestSuite();` (beside
     `:1331`), and `suite.add(std::move(elmConformanceTests));` (beside `:1380-1387`).
  4. `test/aot_e2e_main.cpp:145-151`: add `"elm-conformance"` to `aot_test_packages()`.

**0.6 The Char/String case-mapping conformance tests** (`test/elm-conformance/src/`). All
expectations are recorded with `--record`, none written by hand. Mode-dependent equality is
banned: every `==`/`/=`/`List.member` between Chars has the encoded or longer value on the left,
or both sides of equal UTF-16 length, and the guard enforces this. Code points are given here as
hex.

- `CharCaseSpecialTest.elm`: for each of `ß` DF, `ﬁ` FB01, `ﬂ` FB02, `ﬀ` FB00, `ǰ` 1F0, `ŉ` 149,
  `ΐ` 390, `ΰ` 3B0, `ᾳ` 1FB3, `ᾼ` 1FBC, `İ` 130, `ẞ` 1E9E, log:
  - `charCps (toUpper c)` and `charCps (toLower c)`;
  - `String.fromInt (Char.toCode (toUpper c))`;
  - `String.fromInt (String.length (String.fromChar (toUpper c)))` (ΐ gives 3).
- `CharCaseOrdinaryTest.elm`: `toUpper`/`toLower` code points for these single-code-point
  mappings:
  - Latin-1 `é` E9 and `ÿ` FF (to 178), `µ` B5 (to 39C), `ı` 131 (to 49), `ſ` 17F (to 53);
  - Greek α–ω and Σ (lone Σ gives σ 3C3), Cyrillic `ж` 436, Armenian `ա` 561;
  - Georgian `ა` 10D0 (to 1C90), Cherokee `Ꭰ` 13A0/`ꭰ` AB70;
  - titlecase `ǅ` 1C5 (upper 1C4, lower 1C6);
  - astral Deseret `𐐨` 10428 (to 10400) and `𐐀` 10400;
  - unchanged: `'1'`, `'中'`, `'😀'`.
- `CharCaseEncodedOpsTest.elm` (all mode-independent):
  - `toUpper 'ß' == 'S'` gives False.
  - `toUpper 'ᾳ' == toUpper 'ᾼ'` gives True (dedup), and `compare (toUpper 'ᾳ') (toUpper 'ᾼ')`
    gives EQ.
  - `compare (toUpper 'ß') 'S'`, `'T'`, `'R'`; `compare (toUpper 'ß') (toUpper 'ﬀ')`.
  - `List.sort` of `[toUpper 'ß', 'S', 'T', toUpper 'ﬀ', 'F', toUpper 'ﬁ', toUpper 'ﬂ', 'G', toUpper 'ﬃ']`,
    logged as the `charCps` list.
  - A `Dict Char Int` and a `Set Char` mixing ordinary and encoded keys (including the ᾳ/ᾼ pair),
    logged as `Dict.size`, the keys' `charCps`, and `Dict.get (toUpper 'ᾼ')`.
  - `case toUpper 'ß' of 'S' -> "S"; _ -> "other"`.
  - `Char.isUpper`/`isLower`/`isAlpha` of `toUpper 'ß'` and `toLower 'İ'`.
  - `toLower (toUpper 'ß')` (gives "ss"), `toUpper (toLower 'İ')` (gives `49 307`, not `130`),
    `toUpper (toUpper 'ß')`.
  - `String.fromChar`, `String.cons (toUpper 'ß') "x"`,
    `String.fromList [toUpper 'ß', 'x', toUpper 'ΐ']`, `String.map Char.toUpper "straße"`,
    `String.toList (String.fromChar (toUpper 'ß'))` (gives two ordinary 'S').
  - `Char.fromCode (Char.toCode (toUpper 'ß'))` gives 'S'.
  - `Debug.log "dbg" (toUpper 'ß')` gives `dbg: 'SS'`, and `Debug.log "dbgfi" (toUpper 'ﬁ')`
    gives `dbgfi: 'FI'`. These are the only raw Char logs, and their expansions are ASCII. (As
    built: a single Char, not the planned list `[toUpper 'ﬁ', 'a']`, because of the list
    separator divergence in "Step 0 results".)
- `StringCaseTest.elm`:
  - `cps (String.toUpper s)` / `cps (String.toLower s)` for these strings: "straße", "ﬁnal",
    "ǰ", "ΐ", "ᾳ ᾼ", "İstanbul", "ǅemal", "Ἀθῆναι", "𐐨𐐀", "STRASSE straße", and a string that
    mixes ASCII, é, ж, 中 and 😀.
  - Final_Sigma: "ΑΣ", "Σ", "ΑΣΑ", "Α.Σ", "ΑΣ.", "ΑΣ\u{0308}", "ΑΣ Α", "ΑΣ.Α", "1Σ",
    "ΟΔΟΣ ΟΔΟΣ", "ʰΣ", "ΑΣʰ".
  - The equivalence `String.fromList (List.map Char.toUpper (String.toList s)) == String.toUpper s`
    (and `toLower` for the Σ-free strings), logged as `"True"`/`"False"` strings.
- `CharLocaleCaseTest.elm`: `toLocaleUpper`/`toLocaleLower` of `ß`, `ﬁ`, `é`, `Σ`, `ǅ`,
  `𐐨`, logged as code points. No i/I/İ/ı inputs.
- `CharCaseFullRangeTest.elm`, which proves the whole table. For each plane p in 0..16 it folds
  over every code point `c` in the plane except D800-DFFF:
  - With `u = toUpper c` and `l = toLower c`, mix in, in order:
    - `hashString (String.fromChar u)` and `hashString (String.fromChar l)`;
    - `Char.toCode u` and `Char.toCode l`;
    - `hashString (String.fromChar (toLower u))` and `hashString (String.fromChar (toUpper l))`;
    - `hashString (String.toUpper (String.fromChar c))` and
      `hashString (String.toLower (String.fromChar c))`;
    - `if Char.isUpper u then 1 else 0`.
  - Log `Debug.log ("plane " ++ String.fromInt p) (String.fromInt h)`: 17 lines.
  - A second series `"strplane p"` hashes `String.toUpper s` and `String.toLower s`, where `s` is
    each 0x100-code-point block of the plane (surrogates skipped). This covers whole-string paths
    and Final_Sigma with real neighbours.
  - A last line `"sorted"` hashes, in `List.sort` order, the `charCps` of `[toUpper c, toLower c]`
    for all `c` in 0..0xD7FF, and then mixes in `Set.size` of the same list.
  - Use a tail-recursive loop: stack-safe on both targets, and it runs in a few seconds on JS.

**0.7 Show the gap.**

1. Run `node test/scripts/run-js-e2e.js --project elm-conformance` once. Every conformance test
   must pass.
2. Run `TEST_FILTER=elm-conformance cmake --build build --target full` once to classify. Add
   `-- XFAIL-NATIVE: ASCII-only case mapping (plans/char-case-mapping-elm-exact.md)` to every test
   that fails.
3. Fill in the table in "Step 0 results" below: test, first missing CHECK line.
4. Gate: one unfiltered `cmake --build build --target full`. It is green, the summary lists the
   XFAIL count, and the JS part passes every conformance test.

**Definition of done (Step 0):**

- every conformance test passes on JS;
- every one is XFAIL natively, with its reason;
- `full`, `run-aot-e2e`, `elm-tests` and `stress` stay green;
- no runtime or kernel file has changed.

### Step 1 — table generator, tables, lookup headers (no behaviour change)

Files:

- `compiler/scripts/gen-casemap-tables.mjs`: the algorithm, modes and self-tests from Design.
- `runtime/src/allocator/CaseMapTables.hpp`: generated and checked in.
- `runtime/src/allocator/CharValue.hpp` (hand-written). It depends only on `<cstdint>` and holds
  no tables, so codegen can include it:

  ```cpp
  #ifndef ECO_CHAR_CASE_EXPANSION
  #error "ECO_CHAR_CASE_EXPANSION is not defined: this file is compiled outside the CMake build"
  #endif
  namespace Elm::CharValue {
  inline constexpr bool kExpansions = ECO_CHAR_CASE_EXPANSION != 0;  // see "Build flag"
  inline constexpr uint32_t kFirstMask = 0x1FFFFF;     // bits 0-20
  inline constexpr uint32_t kRankShift = 21;           // bits 21-28 = rank + 1
  inline constexpr uint32_t kRankBits = 8;             // at most 255 entries
  inline constexpr uint32_t kRankMask = 0xFFu << kRankShift;          // 0x1FE00000
  inline constexpr uint32_t kReservedMask = ~(kFirstMask | kRankMask); // bits 29-31, always zero
  inline constexpr uint32_t kMaxCharUnits = kExpansions ? 3 : 2;  // UTF-16 units of one Char's string
  // The raw bit test; only the table code (CaseMap::upper/lower, CaseMapTest) uses it.
  inline bool hasRankBits(uint32_t v) { return v > kFirstMask; }
  // Constant false when OFF, so every encoded-value path guarded by it is compiled out.
  inline bool isEncoded(uint32_t v) { return kExpansions && hasRankBits(v); }
  inline uint32_t firstCodePoint(uint32_t v) {                             // Char.toCode
      if constexpr (kExpansions) return v & kFirstMask; else return v;
  }
  inline uint32_t rank(uint32_t v) { return ((v & kRankMask) >> kRankShift) - 1; } // isEncoded(v) only
  // rotl32(v, 11). With bits 29-31 zero, (v >> 21) is exactly rank + 1 (0 when ordinary).
  inline uint32_t sortKey(uint32_t v) {
      if constexpr (kExpansions) return (v << 11) | (v >> kRankShift); else return v;
  }
  inline int compare(uint32_t a, uint32_t b) { uint32_t x = sortKey(a), y = sortKey(b); return x < y ? -1 : x > y ? 1 : 0; }
  }
  ```

- `runtime/src/allocator/CaseMap.hpp` (hand-written). It includes `CaseMapTables.hpp` and
  `CharValue.hpp`, and every function in it is allocation-free and inline:
  - `const Entry& entry(uint32_t v)`: asserts `(v & kReservedMask) == 0 && isEncoded(v) && rank(v) < kEntryCount && entry.units[0] == firstCodePoint(v)`.
  - `uint32_t upper(uint32_t v)` / `lower(uint32_t v)`: Char value to Char value.
    - ASCII fast path first.
    - If `isEncoded(v)`, return `entry(v).upper/.lower` (compiled out when OFF).
    - Otherwise binary-search `kUpper`/`kLower` (`std::upper_bound` on `from`); return `to`, or
      `v` when absent. Surrogates and unassigned code points are absent.
    - `if constexpr (!kExpansions)`: return `v` instead of a `to` with `hasRankBits(to)`
      (single-code-point mapping, see "Build flag").
  - `uint32_t units(uint32_t v)` and `uint32_t writeUnits(uint32_t v, uint16_t* out)`, writing at
    most `kMaxCharUnits`:
    - ordinary <= 0xFFFF: 1 unit;
    - <= 0x10FFFF: a surrogate pair;
    - 0x110000..0x1FFFFF: U+FFFD;
    - encoded: the entry's units.
  - `bool isCased(uint32_t cp)` / `isCaseIgnorable(uint32_t cp)`: binary search over the ranges.
  - `bool finalSigmaAt(const uint16_t* p, size_t n, size_t start, size_t end)` for the Σ at units
    `[start, end)`: the greedy rule from Verified facts. It decodes with
    `StringOps::prevCodePoint`/`nextCodePoint` semantics, written locally to avoid an include
    cycle.
- Root `CMakeLists.txt`: the `ECO_CHAR_CASE_EXPANSION` option, default ON, exactly as in Design
  "Build flag". Re-run `cmake --preset build` once afterwards so the cache gets the option.
- `test/scripts/check-casemap-tables.sh <repo> <node>` runs `gen-casemap-tables.mjs --check`.
  Add it to `full` (root `CMakeLists.txt:1532-1546`) as a POSIX-only `COMMAND`, the same way
  `_full_js_e2e` is added (`:1528-1531`), with `${NODE_EXECUTABLE}`.
- `run-js-e2e.js`, conformance project preflight: read `kUnicodeVersion` from
  `runtime/src/allocator/CaseMapTables.hpp`. If it differs from `process.versions.unicode`, fail
  the project before compiling, with the generator's message. The reference itself would have
  changed, so the recorded CHECK lines would be wrong.
- Unit tests: new `test/allocator/CaseMapTest.cpp/.hpp`. Add the source to the test sources in
  `test/CMakeLists.txt` (beside `allocator/StringOpsTest.cpp`, `:103`), and register it in
  `test/main.cpp` (beside `registerStringOpsTests`, `:1144`). It checks:
  - **structure:**
    - `kUpper`/`kLower` strictly increasing by `from`, every `from >= 0x80` and not a surrogate;
    - every `to` is <= 0x10FFFF or a valid encoded value whose first unit matches;
    - `kEntries` strictly increasing by unit sequence (prefix first), all units < 0xD800,
      `len` in {2,3}, `upper`/`lower` valid Char values;
    - `sortKey` strictly increasing over `kEntries`;
    - ranges sorted and disjoint;
    - `kEntryCount <= 255`;
    - every `to`, `upper` and `lower` has `(v & kReservedMask) == 0`;
    - `kRankMask == 0x1FE00000` and `kReservedMask == 0xE0000000`;
    - the checks that need encoded values (samples, sortKey, Final_Sigma with expansions) sit
      under `if constexpr (CharValue::kExpansions)`, so an OFF build compiles this file and
      skips them. Structure checks run in both.
  - **samples:**
    - `upper(0xDF)` is encoded with units 53 53, and `lower(upper(0xDF))` has units 73 73;
    - `upper(0x1FB3) == upper(0x1FBC)`;
    - `lower(0x130)` has units 69 307, and `upper(lower(0x130))` has units 49 307;
    - `upper(0x10428) == 0x10400`, `upper('a') == 'A'`, `upper(0xB5) == 0x39C`;
    - `lower(0x3A3) == 0x3C3`, `upper(0x1C5) == 0x1C4`, `lower(0x1C5) == 0x1C6`;
    - for every entry, `upper` and `lower` are fixed points of the closure:
      `upper(entry.upper) == entry.upper` if encoded.
  - **sortKey:** for synthetic `S = 0x53`, `e0 = 0x53 | 1<<21`, `e1 = 0x53 | 2<<21`:
    `0x52 < S < e0 < e1 < 0x54 < 0xE000 < 0x1F600`, and `0x10FFFF > e1`.
  - **Final_Sigma:** `finalSigmaAt` on "ΑΣ" (true), "Σ", "ΑΣΑ", "ΑΣ.Α", "ʰΣ" (false), "ΑΣʰ",
    "Α.Σ" (true).

**Definition of done (Step 1):**

- `node compiler/scripts/gen-casemap-tables.mjs --check runtime/src/allocator/CaseMapTables.hpp`
  exits 0;
- `CaseMapTest` passes;
- `full` is green, with the same XFAIL set as Step 0;
- nothing outside the new files, the CMake option and the `full`/runner hooks changed.

### Step 2 — make every consumer of a Char value encoding-aware (no producer yet)

Nothing produces an encoded value yet, so Elm programs behave identically. The new paths are
covered by C++ and MLIR tests that feed encoded values directly. The performance gate (below)
compares an OFF tree with an ON tree after the edits, so no pre-edit baseline is needed; take one
from the Step 1 tree anyway if it is cheap, as a cross-check.

**2a. UTF-16 writers.** `runtime/src/allocator/StringOps.hpp`. Not GC-concurrency code: the TLA
manifest pins no file named here.

- `:425-433`: rewrite the block comment. A Char may be an encoded value (KERN_008) that writes
  2-3 units.
- `codePointUnits` (`:470-471`): `return CaseMap::units(cp);`.
- `encodeCodePoint` (`:473-484`): document "room for `CharValue::kMaxCharUnits` (3) units" and
  `return CaseMap::writeUnits(cp, out);`. The U+FFFD case is kept for 0x110000..0x1FFFFF.
- `appendCodePoint` (`:486-490`): `u16 buf[CharValue::kMaxCharUnits]`.
- `fromChar` (`:1341-1350`): `u16 buf[CharValue::kMaxCharUnits]`. The `c < 0x80` UTF-8 fast path
  stays correct, because encoded values are >= 0x200000.
- `cons` (`:1358-...`): `u16 units[CharValue::kMaxCharUnits]`. The `c < 0x80` UTF-8 arm stays
  correct for the same reason.
- `#include "CaseMap.hpp"`.
- Callers that need no source edit, because they go through these helpers. They are listed so the
  reviewer checks them:
  - `elm-kernel-cpp/src/core/String.cpp:63-112` `fromList`: the pre-count `:77` uses
    `codePointUnits`, the write `:108` uses `encodeCodePoint`, and the ASCII gate `acc |= cp`
    sends any encoded value to the UTF-16 path;
  - `StringExports.cpp:255-273` `Elm_Kernel_String_map` (`appendCodePoint`, then
    `materializeString`);
  - `runtime/src/allocator/StringOps.cpp:1063-1076` `map`.

  `String.filter`/`any`/`all`/folds copy source units and never write a callback's Char, so they
  are unaffected (`StringExports.cpp:275-292`).
- `grep -rn "u16 [a-z]*\[2\]" runtime/src elm-kernel-cpp/src eco-kernel-cpp/src system-kernel-cpp/src`
  must find nothing left that holds an encoded Char. On 2026-10-28 the only hits were the three
  above.
- Deliberately **not edited**: `String.cpp` and `StringExports.cpp`. Their bytes are pinned by the
  LSS_022 manifest (23 and 29 rows), and their code is unchanged. The manifest deliberately does
  not pin shared allocator headers (`check-kernel-license-manifest.sh` "Scope note"), and the
  kernels' function-value flow does not change.

**2b. Comparisons (kernels).**

- `elm-kernel-cpp/src/core/Utils.cpp`:
  - `compareUnboxableSlot` kind 3 (`:164-166`): `return CharValue::compare(a.c, b.c);`.
  - The mixed boxed/primitive Char arm (`:261-265`): compare with `CharValue::compare`, keeping
    the `aKind == 0` operand order.
  - `cmp` `Tag_Char` (`:345-355`): `CharValue::compare(ac->value, bc->value)`. Update the comment:
    code-point order for ordinary Chars (unchanged divergence), and the sort-key order for encoded
    ones.
  - Equality sites (`:144-145`, `:495-496`, `:580-584`) are unchanged: integer equality is correct.
- `elm-kernel-cpp/src/core/UtilsExports.cpp`:
  - `Elm_Kernel_Utils_compare_Char` (`:83-93`): use `CharValue::compare`;
  - `lt/le/gt/ge_Char` (`:163-175`): compare `CharValue::sortKey` of the masked operands;
  - `equal/notEqual_Char` (`:155-159`) are unchanged;
  - update the comment at `:150-153`.

**2c. Comparisons and `toCode` (codegen).** `runtime/src/codegen/Passes/EcoToLLVMArith.cpp`, with
`#include "../../allocator/CharValue.hpp"` for the constants:

- `CharToIntOpLowering` (`:896-907`): `if constexpr (CharValue::kExpansions)` emit
  `%m = arith.andi %x, 0x1FFFFF : i32` then `arith.extui %m : i32 to i64`; otherwise today's
  `arith.extui %x`. Update the comment.
- New `static Value charSortKey(OpBuilder&, Location, Value x)`: when ON,
  `arith.ori (arith.shli x, 11) (arith.shrui x, 21)`, which LLVM turns into one `rol`; when OFF
  (`if constexpr`), `return x;`, so the comparison lowerings below emit today's IR unchanged.
- `CharLt/Le/Gt/GeOpLowering` (`:939-985`): `arith.cmpi ult/ule/ugt/uge` on
  `charSortKey(lhs), charSortKey(rhs)`.
- `CharCmpOrderOpLowering` (`:1114-1131`): both `isLt`/`isGt` on the keys.
- `CharEq/NeOpLowering` (`:987-1009`) are unchanged.
- Build-mismatch guard (Design "Build flag"): in `EcoToLLVM.cpp`, beside the
  `eco_enable_list_chunks` injection (`:251-270`), inject
  `call @eco_char_case_expansion_on()` (or `_off`, by `CharValue::kExpansions`) at the top of
  `@main` in every module that has one, unconditionally (not only under `listChunks`), with
  `gcLeaf = true`. Define both names' one active function in the runtime beside
  `eco_enable_list_chunks`'s definition (`grep -rn "eco_enable_list_chunks" runtime/src`), the
  other name not at all. Add the symbol to whatever export/symbol list the JIT resolves runtime
  symbols from (the same list `eco_enable_list_chunks` is on). Test: `test/codegen/` already
  has `@main` fixtures; add one CHECK-MLIR-style or LLVM-IR check that the call is present.
- `EcoCompareCaseRewrite.cpp` (`:106-107`, `:168-171`) needs **no edit**. It rewrites
  `eco.char.cmp_order` + case into `eco.char.lt`/`gt`, whose lowering now carries the encoding.
  Pin that with a test (below).
- Fallback only if the performance gate fails: peepholes for a constant ordinary operand `k`.
  These follow from the key definition:
  - `x < k` iff `(x & 0x1FFFFF) <u k`;
  - `x >= k` iff `(x & 0x1FFFFF) >=u k`;
  - `x <= k` iff `(x & 0x1FFFFF) <u k || x == k`;
  - `x > k` iff `!(x <= k)`.
- Doc comments: `runtime/src/codegen/Ops.td:212-216` (`Eco_Char`), `:2705-2716`
  (`char.toInt`: "the first code point: value & 0x1FFFFF"), `:2735-2760` (comparisons: "unsigned
  compare of rotl32(v, 11)"); `runtime/src/codegen/EcoOps.h:35`;
  `runtime/src/allocator/Heap.hpp:439` (`ElmChar`: "a Char value, KERN_008").
- `compiler/src/Compiler/GlobalOpt/KernelIntrinsics.elm:390-394` doc comment: Char ordering is the
  lowering's sort-key order. This is a comment only, so the compiler output is unchanged.

**2d. Debug printer.** `runtime/src/allocator/RuntimeExports.cpp` `print_char` (`:3127-3165`):

- Split the per-code-point body into `print_char_cp(u32 c)`, which keeps today's escapes and UTF-8
  output.
- `print_char(u32 c)` prints `'`. If `CharValue::isEncoded(c)` it calls `print_char_cp` on each of
  the entry's units; otherwise it calls `print_char_cp(c)`. Then it prints `'`. (With OFF,
  `isEncoded` is constant false and the expansion arm is compiled out.)
- The 0x110000..0x1FFFFF range keeps `\uXXXX`.
- This one function serves every Char print site (`:3197`, `:3309`, `:3331`, `:3357`, `:3384`,
  `:3543`, and `eco_dbg_print_char` `:3675`), including `Debug.toString`'s capture path.
- RuntimeExports.cpp has only a `census` pin in `test/tla/manifest.txt:202` (its concurrency
  lines). This edit does not touch them, so the tla-canary stays green. If it fires, investigate
  per CLAUDE.md and do not repair the hash.

**2e. Invariants and docs** (CLAUDE.md requires this with a representation change):

- `design_docs/invariants.csv`:
  - **New row `KERN_008`** (CrossPhase; CharValue; tested): "A Char value is a code point
    0..0x10FFFF or an encoded case-mapping result: bits 0-20 hold the expansion's first code
    point, bits 21-28 hold rank+1 into CaseMap::kEntries (at most 255 entries), and bits 29-31 are
    reserved and always zero. kEntries has one entry per distinct
    expansion, sorted by code-point sequence. Only Char.toUpper/toLower/toLocaleUpper/toLocaleLower
    produce encoded values. toCode is value & 0x1FFFFF (kernel and eco.char.toInt lowering).
    Ordering is the unsigned compare of rotl32(value, 11) (eco.char.lt/le/gt/ge/cmp_order,
    Utils cmp/compare/lt..ge_Char). Equality is integer equality. Every writer of a Char into a
    String (encodeCodePoint/codePointUnits/appendCodePoint and fromChar, cons, fromList, map)
    writes the expansion, and the Debug printer prints it. Build flag ECO_CHAR_CASE_EXPANSION
    (default ON): OFF compiles every encoded path out, no value is ever encoded, and a module
    lowered with one setting refuses to link against a runtime built with the other." Source:
    `runtime/src/allocator/CharValue.hpp|runtime/src/allocator/CaseMap.hpp|test/allocator/CaseMapTest.cpp|test/codegen/char_*_encoded.mlir|test/elm-conformance`.
  - `CGEN_015` (`:257`): "i32 holding a Char value (KERN_008): a code point 0..0x10FFFF (a lone
    surrogate keeps its unit value) or an encoded case-mapping result in 0x200000..0x1FFFFFFF (bits 29-31 zero); literals and
    eco.char.fromInt give code points only", plus an `(Updated ...)` note.
  - `REP_ABI_001` (`:9`) and `REP_SSA_001` (`:13`): "Char→i32 holding a Char value (CGEN_015,
    KERN_008)".
  - `REP_HEAP_002` (`:20`): "a kind-11 slot holds the Char value zero-extended to 64 bits".
- `design_docs/theory/value-representation.md:13` (table row) and `:29` (Char paragraph): add the
  encoding, toCode, ordering, the writers and the build flag.
- `design_docs/theory/backend/eco-dialect.md:17`.
- `THEORY.md:84`: "a Char is a Unicode code point, or an encoded multi-code-point case-mapping
  result, in 32 bits".

**2f. Tests:**

- `test/codegen/char_toInt_encoded.mlir`: `eco.char.toInt` of `0x1400053`, `0x5200399` and
  `0x10FFFF` gives 83, 921 and 1114111. Use the `test/codegen/char_toInt.mlir` pattern.
- `test/codegen/char_cmp_encoded.mlir`: synthetic values R=0x52, S=0x53, e0=0x200053,
  e1=0x400053, T=0x54, E000, 1F600. For each ordered pair: `eco.char.lt/le/gt/ge/eq/ne` and
  `eco.char.cmp_order` (print the Order tag). Plus one `cmp_order`-feeding-`eco.case` function
  that `EcoCompareCaseRewrite` rewrites (pattern: `test/codegen/compare_case_rewrite_jit.mlir`).
- `test/kernel/KernelExportsTest.cpp` (beside `:258-265`):
  - `Elm_Kernel_Utils_compare_Char`/`lt_Char`/`ge_Char` on the same synthetic values;
  - `Utils::compare` on boxed `eco_alloc_char` values and on two cons lists of unboxed Chars
    (the `compareUnboxableSlot` path);
  - `Elm_Kernel_String_cons(encoded "SS"-value, "x")`, `fromChar`, and `fromList` over an
    unboxed-Char list holding `[ss, 'x', ΐ]` built from `CaseMap::upper` results, giving units
    `53 53 78 399 308 301` and length 6 (the exact-size blank);
  - `encodeCodePoint(0x150000, buf)` gives U+FFFD.
- `test/allocator/RuntimeExportsTest.cpp`: `eco_dbg_print_char(CaseMap::upper(0xDF))` with output
  capture gives `'SS'`.
- The C++ cases above that feed encoded values sit under `if constexpr (CharValue::kExpansions)`
  (skipped, not failed, in an OFF build). The two `.mlir` fixtures cannot be skipped that way;
  in the OFF tree they are expected failures (see "OFF tree" below).

**2g. LSS_022 re-audit.** The manifest guard runs in `ALL`, so it must happen in this step.
Changed pinned files: `elm-kernel-cpp/src/core/Utils.cpp` and `UtilsExports.cpp`. The rows that
pin them, all in `compiler/src/Compiler/MonoSolver/KernelSetFacts.elm`, are 9:

- `Elm.Utils.append`, `compare`, `equal`, `ge`, `gt`, `le`, `lt`, `notEqual` (`:2160-2215`);
- `Elm.List.sortBy` (`:1677`).

For each row:

1. Re-run the plans/kernel-parametricity-license.md §2 checklist against the new body: Char
   arithmetic only, no apply, no retention, no closure mint, no type change.
2. Append to its `evidence` string
   `| re-audit 2026-MM-DD: plans/char-case-mapping-elm-exact.md Step 2 - Utils.cpp/UtilsExports.cpp Char compares use CharValue::compare/sortKey (KERN_008); scalar code only; no application, retention, fabrication or type change; B1-B3 unchanged; line ranges updated | audited: 2026-MM-DD`.
3. Re-derive the file:line cites in the string.
4. Last: `sh test/scripts/check-kernel-license-manifest.sh . --update`.

`RuntimeExports.cpp` in `runtime/src/allocator` is not in the manifest. The pinned
`RuntimeExports.cpp` is eco-kernel-cpp's.

**Definition of done (Step 2):**

- the codegen, kernel and unit tests above pass;
- `full` is green with the unchanged XFAIL set;
- `elm-tests` is green (the evidence strings are Elm);
- the OFF tree builds, and its `full` fails only `char_toInt_encoded.mlir` and
  `char_cmp_encoded.mlir` (they feed encoded values that OFF does not decode); everything else
  is green with the Step 0 XFAIL set;
- the performance gate passes (or the fallback peephole has been applied and the gate re-run);
- the manifest check is green.

### Step 3 — produce the mappings (Char and String together)

Char and String switch on in one step. The equivalence
`String.fromList (List.map Char.toUpper (String.toList s)) == String.toUpper s` holds today (both
are ASCII-only), and it would break between two separate steps.

**3a. Char kernels.**

- `elm-kernel-cpp/src/core/Char.cpp`:
  - `toLower` (`:61-81`) returns `CaseMap::lower(c)`, and `toUpper` (`:83-103`) returns
    `CaseMap::upper(c)`. Replace the "ASCII only / TODO ICU" notes with a pointer to this plan.
  - `toLocaleLower`/`toLocaleUpper` (`:105-141`) keep delegating. Their NOTE says: default
    locale, which matches node, plus the browser divergence.
  - `toCode` (`:38-59`) returns `CharValue::firstCodePoint(c)`.
- `elm-kernel-cpp/src/core/CharExports.cpp`:
  - `Elm_Kernel_Char_toCode` (`:30-32`) returns `c_raw & CharValue::kFirstMask`. Update the comment.
  - The four mappers (`:34-52`) are unchanged apart from comments: they already mask to 32 bits
    and return the full `uint32_t`.
- The `toCode` kernel change belongs here rather than in Step 2 so that `CharExports.cpp`'s six
  rows are re-audited once. No encoded value exists before this step.

**3b. String kernels.** `runtime/src/allocator/StringOps.hpp` `toUpper` (`:791-828`) and `toLower`
(`:830-866`):

- UTF-8 forms are all ASCII (`StringOps.hpp:64-71`), and ASCII maps to ASCII, so the UTF-8 arms
  are unchanged.
- UTF-16, fast path: after `copyInto` into the blank, the in-place ASCII loop is correct when no
  unit is >= 0x80. Scan the source (`forEachSegment`, or `charAt` over `len`, with no allocation)
  for any unit >= 0x80 **before** allocating, and take the existing path when there is none.
- UTF-16, general path:
  1. `auto buf = toStdU16String(str)`, a C-heap snapshot that no GC can invalidate.
  2. Walk the code points with `nextCodePoint`, keeping each one's start and end unit index.
  3. Append `CaseMap::upper(cp)` (or `lower`) with `appendCodePoint`, which writes expansions.
  4. In `toLower` only, when `cp == 0x3A3`, append
     `CaseMap::finalSigmaAt(buf.data(), n, start, end) ? 0x3C2 : 0x3C3` instead.
  5. Materialise like `StringExports.cpp:242-253`: if every result unit is < 0x80 and UTF-8
     strings are enabled, return `allocAsciiOut` + `finishAsciiOut`; otherwise
     `alloc::allocString`.
  The source is a C++ copy, so nothing needs rooting.
- Rewrite the doc comments ("ASCII only") to say full Unicode, Final_Sigma, and this plan.
- `String.cpp:396-402` delegates, so it is unchanged and not re-audited (the same reasoning as
  2a).

**3c. Conformance.** Remove `-- XFAIL-NATIVE:` from every Step 0 test. The strict XPASS rule makes
`full` fail on any test still marked. Then every conformance test must pass on both targets.

**3d. Unit tests** (`test/kernel/KernelExportsTest.cpp`):

- `Elm_Kernel_Char_toUpper(0xDF)` is encoded with `toCode` 83;
  `Elm_Kernel_Char_toLower(Elm_Kernel_Char_toUpper(0xDF))` is "ss";
  `Elm_Kernel_Char_toLocaleUpper(0xDF) == Elm_Kernel_Char_toUpper(0xDF)`;
- `Elm_Kernel_String_toUpper("straße")` gives "STRASSE" as an ASCII UTF-8 form;
- `Elm_Kernel_String_toLower("ΟΔΟΣ ΟΔΟΣ")` gives units `3BF 3B4 3BF 3C2 20 3BF 3B4 3BF 3C2`;
- `String.toLower` of a rope/slice input containing Σ at a segment boundary.

**3e. LSS_022 re-audit.** Changed pinned files: `Char.cpp` (4 rows: toLocaleLower,
toLocaleUpper, toLower, toUpper) and `CharExports.cpp` (6 rows: fromCode, toCode, toLocaleLower,
toLocaleUpper, toLower, toUpper), which is 6 distinct rows (`KernelSetFacts.elm:990-1031`).

- They are all class `vacuous` (`Char -> Char` / `Char -> Int` / `Int -> Char`): no
  function-capable position. They now call `CaseMap::upper`/`lower`/`firstCodePoint`, which are
  pure, allocation-free table lookups over `constexpr` data.
- Append the same style of re-audit note naming Step 3, update the `entry:`/`helpers:` line
  ranges, then run `--update`.
- `String.toUpper`/`toLower`'s pinned files (`String.cpp`, `StringExports.cpp`) did not change, so
  their rows are not re-audited. Their helper (`StringOps.hpp`) is outside the manifest's scope.

**3f. Docs:**

- `design_docs/theory/kernels/elm-kernel.md:11`: replace "Char case conversion is ASCII-only"
  with the full-Unicode behaviour, the encoding (link KERN_008), the reference semantics, the
  Divergences list, and both generators and their Unicode versions.
- `design_docs/theory/runtime/data-structures.md:64`: `toUpper`/`toLower` results may change
  length.
- `design_docs/kernel-boundary/audit-01-basics-bitwise-char-utils.md:97-98`, `:154` and
  `audit-02-string.md:44-45`: append a dated note that these are table lookups now and no longer
  trivial ASCII tests.
- `design_docs/utf8-string-encoding-investigation.md:235`: the UTF-8 arm is still byte-wise,
  because UTF-8 forms are all ASCII.
- `examples/benchmarks/src/UnicodeString.elm`:
  - the module doc (`:1-20`) loses "Only the ASCII part of `toUpper` is checked";
  - extend the check to the full upper-case code-point sum (é→É, è→È, à→À, ж→Ж, и→И, л→Л are
    1:1 BMP mappings);
  - update its README line ("only the ASCII part of `toUpper`").

**Definition of done (Step 3):**

- every conformance test passes on JS and natively (JIT and AOT) with no XFAIL left;
- the Step 3 unit tests pass;
- the manifest check is green;
- the full gate below is green.

### Step 4 — final gate and plan closure

Run the Gate (below), fill in "Results", and set this plan's front matter to `status: done` with
the date.

## Performance gate (Step 2, re-checked after Step 3)

The paths at risk are `Char.toCode` (every `isUpper`/`isLower`/`isAlpha`/`isDigit` in elm/core,
and every parser) and the Char comparisons. Today both are one `zext` or `icmp`. Afterwards they
are an `and` plus `zext`, or a `rol` per operand plus `icmp`.

The build flag makes this an A/B from one source tree: A = OFF, which is today's Char code
paths (the `if constexpr` arms emit exactly the pre-plan code), B = ON.

1. **Trees.** After Step 2, configure a second tree from the same source:
   `cmake --preset build -B build-casemap-off -DECO_CHAR_CASE_EXPANSION=OFF`, then
   `cmake --build build-casemap-off` (all targets; MEMORY: relower needs all runtime libs) and
   `cmake --build build-casemap-off --target full` once: the only failures allowed are the two
   `*_encoded.mlir` codegen fixtures (Step 2 DoD). `build` stays ON.
2. **Measure both**, A then B, the same commands:
   - Micro: `cd examples/benchmarks && ECO=<tree's eco> node run.mjs lexer expr-parser sexpr json-parser csv-parser word-freq unicode-string sort --runs 25 --skip-elm`,
     where `<tree's eco>` is that tree's dev `eco` (the bench harness memory: dev build via
     `compiler/bin/index.js` + that tree's `eco-boot-native`; check `run.mjs:33` for how `ECO` is
     used and point it at the tree's binaries). Read the `eco-native` medians. Run A twice to
     measure noise.
   - Self-compile wall: `python3 heap-profile.py run --build-tree <tree> --label casemap-<off|on> --repeat 3`
     at the default heap config (Stage 7 self-compile). Take the wall and CPU medians.
   If a Step 1 measurement was taken, A should match it within noise (A is the pre-plan code);
   a gap means the two trees differ in something besides the flag.
3. **Pass criteria:**
   - Every micro workload's median within max(2 %, measured noise) of baseline.
   - Self-compile wall median within +1.5 % (the recorded noise is about 1.3 % wall).
   - The Stage 8c native fixed point (`eco-compiler-boot == eco-compiler-boot-2`) still holds.
     The compiler's Elm code and therefore its MLIR do not change: the compiler's only Char case
     use is in error messages (`Reporting/Error/Syntax.elm:2339`, `:7268`), and its
     `String.toUpper`/`toLower` uses are ASCII.
4. **If a criterion fails** (B slower than A):
   - Apply the constant-operand peephole (2c) and re-measure.
   - Or decide with the user whether the default should be OFF; that is a one-line change of
     the option's default, not new code.
   - Then look at the disassembly of the hot loop (`perf annotate` on the lexer workload).
   - If it still fails, stop and report the numbers to the user before going on.
5. **After Step 3**, re-run the micro set once on both trees. `unicode-string` is expected to change, because
   String.toUpper now maps é/ж. ASCII workloads must be flat. Record the numbers.

Record all medians in "Results" below.

## Gate (Step 4; also run the relevant parts at each step's DoD)

Each command once, output to `/tmp/test_output.txt` (or one file per command), then read it:

- `cmake --build build --target elm-tests`
- `cmake --build build --target full`: the native E2E, eco/system core and JS E2E (eco-system and
  elm-conformance), plus the casemap-table check.
- `cmake --build build --target stress`
- `cmake --build build --target run-aot-e2e` (Gate B; the known 893/895 baseline plus the new
  conformance tests)
- `cmake --build build --target bootstrap` (Stages 4b, 8c and 9b fixed points)
- `cmake --build build-casemap-off --target full` once: the OFF tree must compile, and the only
  failures allowed are the two `*_encoded.mlir` codegen fixtures and the `elm-conformance` tests
  natively (their XFAIL marks are gone after Step 3, and OFF does not expand). Record the list,
  then delete `build-casemap-off`; it is not part of any routine gate.

The conformance tests' native output must equal the JS output: the same CHECK lines, recorded
from Elm.

## Review dispositions

Review: `review-casemap.md`. Every finding used here was verified against the code or node.

- **Accepted:**
  - 1 (`--optimize` reference, plus the mechanical guard).
  - 2 (one entry per distinct string; 73 direct, 146 closed).
  - 3 (`codePointUnits`/`encodeCodePoint` changed in place, buffers enlarged).
  - 4 (bit-packed encoding: verified ≤ U+1FFA and BMP, and the ordering argument checked over
    263.8M pairs; perf gate added).
  - 5 (tables from node, version check).
  - 6 (elm/json, Platform.worker).
  - 8 (String.toUpper/toLower in scope, Final_Sigma).
  - 9 (native registration in four places).
  - 10 (per-project runner).
  - 11 (`XFAIL-NATIVE`, strict XPASS).
  - 12 (`filter` dropped).
  - 14 (all four invariant rows plus the comments).
  - 15 (locale).
  - 16 (facts, all re-verified).
  - 17 (no Elm table module).
  - 18 (full-range hash and the extra cases).
- **Adjusted:**
  - 3: the callers `StringExports.cpp:270`, `StringOps.cpp:1075` and `String.cpp:77/108` get **no
    source edit**. They go through the changed helpers, and leaving `String.cpp`/`StringExports.cpp`
    untouched avoids 52 manifest-row re-audits with no flow change.
  - 7: `EcoCompareCaseRewrite.cpp` needs **no edit**. It re-emits `eco.char.lt/gt`, whose lowering
    carries the encoding. A codegen test pins this instead.
- **Rejected:**
  - 13's implied fix to `Json_wrap_Char`: unreachable from Elm source (`Json.Encode` applies wrap
    only at non-Char types, and ports cannot carry Char), and the edit would cost 33 re-audits. It
    is documented as a divergence.
  - 9's suggestion to rename `test/elm-conformance`: the user chose the name. The clash with
    `test/conformance` is addressed by documenting it.

## Step 0 results (fill in)

Recorded 2026-10-28 (node 22.23.3, Unicode 17.0). JS: `run-js-e2e.js --project elm-conformance`.
Native: JIT (`TEST_FILTER=elm-conformance` `full`) and AOT (`run-aot-e2e`), both XFAIL on every
test with the same first missing line.

| Test | CHECKs | JS | Native (pre-implementation) | First missing CHECK |
|---|---|---|---|---|
| CharCaseSpecialTest | 48 | pass | XFAIL | `DF up: "53 53"` (eco: `"DF"`) |
| CharCaseOrdinaryTest | 88 | pass | XFAIL | `E9 up: "C9"` (eco: `"E9"`) |
| CharCaseEncodedOpsTest | 49 | pass | XFAIL | `dbg: 'SS'` (eco: `'ß'`) |
| StringCaseTest | 72 | pass | XFAIL | `strasse up: "53 54 52 41 53 53 45"` (eco: `... DF 45`) |
| CharLocaleCaseTest | 16 | pass | XFAIL | `DF locUp: "53 53"` (eco: `"DF"`) |
| CharCaseFullRangeTest | 35 | pass (2.1 s) | XFAIL | `plane 0: "1592108178"` (eco: `"1246368386"`) |

Findings while writing them:

- **Debug list separator (not case mapping).** Stock Elm prints a list as `[a,b]` and a tuple as
  `(a,b)` (`_Debug_toAnsiString`); eco prints `[a, b]`, which about 200 native E2E test files pin.
  `CharCaseEncodedOpsTest`'s `dbgl: ['FI','a']` therefore keeps failing natively after Step 3
  unless this divergence is fixed or that line is changed. **Decided in Step 3:** the line logs
  one Char (`dbgfi: 'FI'`) instead; the separator divergence is out of this plan's scope.
- **Unused top-level values.** Eco drops a top-level value that nothing uses, and a
  `Debug.log` inside it with it (Elm on JS evaluates every top-level value). So every log in a
  conformance test must feed the value the program uses; `ConformanceHelp.logAll` does.
- `--record` drops Elm's `Compiled in DEV mode.` banner line, which is JS-only output.

## Results

Implemented 2026-10-28, all steps. A = `build-casemap-off` (`-DECO_CHAR_CASE_EXPANSION=OFF`, the
pre-plan Char code paths), B = `build` (ON, default), same source tree. eco-native medians in ms
(`run.mjs --runs 25 --skip-elm --skip-js`); "noise" is A run twice at Step 2.

| Workload | A Step 2 (2 runs) | B Step 2 | B vs A | A Step 3 | B Step 3 | B vs A |
|---|---|---|---|---|---|---|
| lexer | 156 / 158 | 159 | +1.3 % | 165 | 162 | -1.8 % |
| expr-parser | 171 / 173 | 173 | +0.6 % | 174 | 174 | 0.0 % |
| sexpr | 227 / 228 | 229 | +0.7 % | 229 | 228 | -0.4 % |
| json-parser | 248 / 253 | 249 | -0.6 % | 245 | 249 | +1.6 % |
| csv-parser | 273 / 271 | 277 | +1.8 % | 267 | 279 | +4.5 % (see below) |
| word-freq | 123 / 122 | 122 | -0.4 % | 123 | 121 | -1.6 % |
| unicode-string | 157 / 155 | 155 | -0.6 % | 164 | 163 | -0.6 % |
| sort | 266 / 269 | 271 | +1.3 % | 279 | 283 | +1.4 % |

| Measurement | A (OFF) | B (ON) | B vs A |
|---|---|---|---|
| Stage 7 self-compile wall, median of 3 (Step 2; heap-profile.py, compiled-in heap defaults) | 70.24 s | 70.72 s | +0.68 % (gate 1.5 %) |
| Stage 7 self-compile CPU, median of 3 | 100.02 s | 100.55 s | +0.53 % |
| Bootstrap 4b / 8c / 9b fixed points (Step 4, ON) | | pass | |

**csv-parser at Step 3 is a code-placement effect, not the encoding.** Three alternating A/B pairs
gave A 268/268/265 and B 276/279/278 (about +4 %). But nothing the encoding changed is on its path:
the program's MLIR has no `eco.char.toInt`/ordering op in any parser or CSV function; the kernels
it calls (`Parser_isSubChar`, `chompBase10`, `String_toFloat`, `String_slice`) disassemble to
identical instructions in both binaries (only their 64-byte alignment differs); and of the 371
compiled parser/CSV functions only `CsvSplit.document` differs, by two register moves fewer in B.
A itself moved from 272 to 267 between Step 2 and Step 3, when Step 3 changed only code this
workload never runs. (`perf` is unavailable here: `perf_event_paranoid` = 3.) MEMORY: the GC mark
loop showed +4.5 % from alignment alone. The self-compile, the whole-program gate, is +0.68 %.

Gate (Step 4, ON tree, each run once):

| Suite | Result |
|---|---|
| `full`: native JIT | 2,541 / 0, no XFAIL left |
| `full`: JS E2E | 214 / 0 (eco-system 208 + 5 skipped, elm-conformance 6) |
| `full`: casemap-table check | up to date (node 22.23.3, Unicode 17.0) |
| `elm-tests` | compiler 14,564 / 0, eco/system 918 / 0 |
| `stress` | 114 / 0 |
| `run-aot-e2e` | 1,225 / 0 (2 skipped, 0 XFAIL) |
| `bootstrap` | Stages 4b, 8c, 9b pass |
| Conformance output, AOT | all 308 recorded Elm lines appear verbatim in eco's output |
| OFF tree `full` (Step 3) | fails exactly `char_toInt_encoded.mlir`, `char_cmp_encoded.mlir` and 5 conformance tests (CharCaseOrdinaryTest passes: OFF keeps the 1:1 mappings) |

Notes from the implementation:

- The table generator runs in about 1 s, not 10 s; its counts equal the Verified facts exactly
  (146 entries; kUpper 1,554 with 102 encoded; kLower 1,462 with 1 encoded; 34,031 Final_Sigma
  checks).
- `heap-profile.py` gained `--lower-with-build-tree`: it used to lower with `build/` always, which
  the flag makes wrong for the OFF tree (the guard symbol would not even link). Its default
  `--config` (`build/compiler/build-kernel/heap-config.json`, dated 2026-10-03) is stale: the
  runtime rejects its `mark_work_ratio` key, so the runs above used `--config` with `{}`.
- The guard is pinned by `test/codegen/char_case_build_guard.mlir` (either setting).
- The `CaseMapTest` structure checks read raw bits (`v & kFirstMask`), so they pass in both builds.
