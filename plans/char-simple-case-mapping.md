---
status: not-started
updated: 2026-10-30
---

# Unicode simple case mapping: a Char is always one code point

Supersedes `plans/char-case-mapping-elm-exact.md` (done 2026-10-28). That plan reproduced
Elm-on-JS case mapping exactly by encoding multi-code-point results as Char values above 0x10FFFF.

## Why

Elm-on-JS implements `Char.toUpper c` as `c.toUpperCase()`, JavaScript's *full* case mapping. For
103 code points that gives more than one code point:
- `'ß'` → `"SS"`;
- `'ﬁ'` → `"FI"`;
- `'İ'` → `"i̇"`.

Elm returns that string as a `Char`, and a Char is then no longer a character:
- `String.length (String.fromChar (Char.toUpper 'ß')) == 2`;
- appending one Char can grow a String by two or three code points;
- `Char.toCode` answers for the first code point only.

To reproduce this, eco encodes 146 multi-code-point strings as Char values (KERN_008). That takes
a rank table, a rotated sort key for ordering, a masked `toCode`, expanding writers, a build flag,
a link-time guard and a Final_Sigma context rule.

**Decision (2026-10-30).** eco uses the Unicode Standard's **simple case mapping** instead:
`UnicodeData.txt` field 12 (Simple_Uppercase_Mapping) and field 13 (Simple_Lowercase_Mapping).
That is one code point in, one code point out, with no context and no locale. A Char is always
exactly one code point. This is the standard's own per-character mapping, and it is what Elm should
have used. The remaining differences from Elm-on-JS are few, and `design_docs/char-case-mapping.md`
(Step 5) lists them.

## What this plan accomplishes

- **Every Char is one code point**: 0..0x10FFFF, or a lone surrogate's own unit value. This is the
  representation before 2026-10-28 (plans/review-bug-triage-fixes.md Part 1).
- **One mapping for Char and String.**
  - `Char.toUpper` / `toLower` / `toLocaleUpper` / `toLocaleLower` use the simple mapping.
  - `String.toUpper` / `toLower` apply the same mapping to every code point.
  - So for every String `s`, `String.toUpper s == String.map Char.toUpper s` and
    `String.toLower s == String.map Char.toLower s`.
  - Case mapping never changes a String's length, in code points or in UTF-16 units. No simple
    mapping crosses between the BMP and the supplementary planes; the generator asserts this.
- **Everything the encoding needed is removed:**
  - the encoded range and its rank table (`kEntries`);
  - the sort-key rotation in Char comparisons;
  - the `toCode` mask and the expanding writers;
  - the Final_Sigma context rule and its Cased / Case_Ignorable tables;
  - the `ECO_CHAR_CASE_EXPANSION` build flag and its link guard (`eco_char_case_expansion_on/off`).
- **The tables come from a vendored file.** They are generated from a checksummed Unicode 17.0
  `UnicodeData.txt`, the Unicode version of the node the conformance tests are recorded on. The
  generator cross-checks them against node, so eco agrees with Elm-on-JS except where documented.
- **The conformance tests are split** into rows where eco agrees with Elm (run on both targets) and
  permanent divergence records (`-- XFAIL-NATIVE:`). A new native test states eco's semantics.

## Verified facts (2026-10-30, node v22.23.3: Unicode 17.0, ICU 78.3)

Checked by node scripts over every code point 0..0x10FFFF except surrogates, against
`https://www.unicode.org/Public/17.0.0/ucd/UnicodeData.txt`, then independently re-derived by a
reviewer. The file's sha256 is `2e1efc1dcb59c575eedf5ccae60f95229f706ee6d031835247d843c11d96470c`;
it has 40,575 lines and no version header.

- **Table sizes.** There are 1,505 simple uppercase mappings (26 ASCII) and 1,488 simple lowercase
  mappings (26 ASCII). None is an identity, none involves a surrogate, and none crosses between the
  BMP and the supplementary planes. No `<..., First>` / `<..., Last>` range line has a mapping.
- **Non-ASCII to ASCII.** Exactly four mappings go from a non-ASCII code point to ASCII:
  - upper U+0131 ı → I;
  - upper U+017F ſ → S;
  - lower U+0130 İ → i;
  - lower U+212A K → k.
- **Agreement with node.** Wherever node's full mapping (`toUpperCase` / `toLowerCase`) is a single
  code point, it equals the simple mapping: 0 differences upper, 0 lower. Title-case letters such
  as U+01C5 ǅ agree too. The ordinary entries of today's `CaseMapTables.hpp` are already the simple
  mapping:
  - upper: 1,452 + 26 ASCII + 27 = 1,505;
  - lower: 1,461 + 26 + 1 = 1,488.
- **Char divergence from Elm-on-JS: 103 code points**, all in the BMP. 102 have a
  multi-code-point JS uppercase, and 1 (U+0130) a multi-code-point JS lowercase. Under simple
  mapping:
  - 75 map to themselves;
  - 27 uppercase to one other code point, such as U+1F80 → U+1F88 and U+1FB3 → U+1FBC;
  - U+0130 lowercases to U+0069.

  Appendix A is the exact list.
- **One derived divergence.** U+1E9E ẞ is not in the list, but `toUpper (toLower 'ẞ')` differs:
  Elm gives `toUpper 'ß'`, which is "SS", and eco gives ß. Any test that composes mappings sees it.
  It is the only such code point (checked exhaustively).
- **String divergence from Elm-on-JS.** `String.toUpper` / `toLower` diverge on strings that
  contain an Appendix A code point. `String.toLower` also diverges on a Σ (U+03A3) that the
  Final_Sigma rule lowercases to ς (U+03C2); simple mapping always gives σ (U+03C3). JS string
  case mapping is otherwise context-free (300k random strings, plus every code point in four
  contexts).
- **Locale.** On node, `toLocaleUpperCase()` / `toLocaleLowerCase()` without an argument ignore the
  process locale. So `toLocale*` equals `toUpper` / `toLower`, and eco keeps them equal.
- **No other local source fits.**
  - Perl's unicore and Python's `unicodedata` are Unicode 14.0, and system ICU 72 is 15.0.
  - node has no simple-mapping API.
  - Deriving the table from node would need 28 hand-written exceptions.

  The vendored 17.0 file is the source.

## Design

### Char values

- A Char is a `u32` code point, 0..0x10FFFF. That includes the surrogate range, because a lone
  surrogate in a String is a Char of its own unit value.
- Nothing above 0x10FFFF is produced: `Char.fromCode` and `eco.char.fromInt` already give U+FFFD
  outside the range.
- Equality and ordering are plain unsigned integer comparison (code-point order). The comparison
  ops lower to `icmp ult/ule/ugt/uge` on i32. With every value at most 0x10FFFF, the sign bit is
  never set.
- `Char.toCode` is the value. The exported kernel keeps its ABI truncation `c_raw & 0xFFFFFFFF`;
  only today's extra `0x1FFFFF` mask goes.

Old programs keep their meaning. For an ordinary value, today's rotated key `rotl32(v, 11)` is
monotonic, so Char ordering does not change.

### Case mapping

`CaseMap::upper(cp)` / `lower(cp)`:
- ASCII goes through a fast path.
- Anything else is a binary search in `kUpper` / `kLower`: sorted `(from, to)` pairs holding every
  non-identity simple mapping, ASCII included.
- A code point that is not in the table maps to itself. Surrogate values are never in it.

`String.toUpper` / `toLower` walk the String by code point. They join a valid surrogate pair, leave
a lone surrogate as it is, map each code point and write it back as the same number of UTF-16
units. A result that is all ASCII becomes a UTF-8 form, as today. That happens for a non-ASCII input
made of ASCII plus ı, ſ, İ or K. An all-ASCII UTF-8 input keeps its in-place path.

`toLocaleUpper` / `toLocaleLower` are `toUpper` / `toLower`.

### Data and generation

**The vendored data.** `runtime/third_party/unicode/17.0.0/`, following the convention of
`runtime/third_party/llvm-libc`, holds:
- `UnicodeData.txt`;
- `LICENSE.TXT`, the Unicode License v3 from https://www.unicode.org/license.txt;
- `README.md`, giving the URL, sha256, download date and the one consumer;
- `update.sh`, which downloads the file for a given version and prints its sha256.

The file is not installed or bundled: the install rules list their files explicitly.
`.gitattributes` already forces LF line endings.

**The generator**, `compiler/scripts/gen-casemap-tables.mjs` (node), keeps today's command-line
shape and adds `--list-divergent`:
- `node gen-casemap-tables.mjs` writes the header to stdout;
- `--check <file>` regenerates the header in memory and compares bytes with `<file>`;
- `--list-divergent` prints Appendix A, one line per code point.

One constant in the script describes the data:

```js
const UCD = {
  version: "17.0",
  sha256: "2e1efc1d...470c",
  upper: 1505,
  lower: 1488,
};
```

The UCD path is resolved from `import.meta.url` (`../../runtime/third_party/unicode/17.0.0/UnicodeData.txt`)
and does not depend on the working directory. Updating Unicode means editing this constant and the
path (design_docs/char-case-mapping.md says how).

**The check.** `test/scripts/check-casemap-tables.sh <repo> <node>` runs in `full` as today. It
runs `--check`, which also fails when node's Unicode version differs from the table's, because the
conformance recordings would then no longer match.

### What eco's JS output does

eco's JS output is produced by Elm's own generator. It keeps Elm-on-JS full case mapping, so the
semantics above are native only, as for Float (design_docs/float-semantics.md).

## Constraints for the implementer

**Kernel license (LSS_022) and scheduling.** The `kernel-license-check` target is part of ALL
(root `CMakeLists.txt:1360`). Editing a pinned file without a valid re-audit row therefore fails a
plain `cmake --build build`, and with it `check`, `full` and `bootstrap`.

- **Pinned files this plan edits:**

  | File | Pin rows | Pin date |
  |---|---|---|
  | `elm-kernel-cpp/src/core/Char.cpp` | 4 | 2026-10-28 |
  | `elm-kernel-cpp/src/core/CharExports.cpp` | 6 | 2026-10-28 |
  | `elm-kernel-cpp/src/core/Utils.cpp` | 9 | 2026-10-30 |
  | `elm-kernel-cpp/src/core/UtilsExports.cpp` | 8 | 2026-10-30 |

  They belong to 15 kernels:
  - `Elm.Char.fromCode`, `toCode`, `toLower`, `toUpper`, `toLocaleLower`, `toLocaleUpper`;
  - `Elm.List.sortBy`;
  - `Elm.Utils.append`, `compare`, `equal`, `ge`, `gt`, `le`, `lt`, `notEqual`.

  Every one of the 15 needs a re-audit row, including those whose code does not change, because
  the pin is a hash of the whole file.
- **An audit row must be stamped strictly after the pin's stamp.** (Updated 2026-10-30: the
  checker now takes UTC stamps `YYYY-MM-DDTHH:MM:SS`, a plain date meaning midnight, so a file
  re-pinned earlier the same day can be re-audited at once; this used to delay the commit to
  2026-10-31.) The audit rows go in the same commit.

**Other constraints:**
- **Invariants.** Read `design_docs/invariants.csv` first. KERN_008, CGEN_015, REP_ABI_001,
  REP_SSA_001 and REP_HEAP_002 change in Step 5.
- **The TLA+ canary.** It pins only the trace harnesses' `.cpp` files and a concurrency census of
  `RuntimeExports.cpp`, and no hashed line changes here. Run `sh test/scripts/check-tla-manifest.sh .`
  after Step 3 anyway. Step 3.15 removes the define from the two harness CMakeLists, so build and
  run `cmake --build build --target tla-trace` once in Step 5.
- **Cached objects.** Every object lowered before this change calls `eco_char_case_expansion_on`.
  After Step 3 such an object no longer links against the new runtime. heap-profile.py reuses its
  cached `<stem>.o` files as they are (`heap-profile.py:105-120`). Before the first heap-profile or
  benchmark run after this change:
  - delete those `.o` files under `build/compiler/build-kernel` (`find build/compiler/build-kernel -maxdepth 2 -name '*.o'`);
  - delete `build/test/*/eco-stuff`.

  Fully linked binaries (`bin/eco-opt*`, snapshot binaries) are unaffected.
- **Tests.** Expose first: Step 1 writes the native specification test as an expected failure.
  Use `ulimit -c 0` before test binaries, run each test command once, and send the output to a file
  in the scratchpad.

**Commits:**
- **Commit A:** Step 1 only. The tree stays green: the new test reports XFAIL.
- **Commit B:** Steps 2–5 together. Splitting them leaves the tree red: the tables, consumers,
  conformance expectations, license audits and invariants must change at once. Commit messages
  follow `GITSTYLE.md`, with no tool attribution trailers.

## Step 1 (commit A): the native specification test, expose first

1. **Create `test/elm/src/CharSimpleCaseTest.elm`.** It is native-only (test/elm is never run on
   JS) and modelled on `test/elm/src/FloatIeeeSemanticsTest.elm`.
   - Header line: `-- XFAIL-NATIVE: plans/char-simple-case-mapping.md, not implemented yet`. The
     marker is generic (`test/ElmE2ETestBase.hpp:1110-1130`). Step 4.1 removes it.
   - Inputs go through `List.map` or a function argument, so that nothing is folded at compile time.
   - Code points are logged as upper-case hex. Write a local `cps : String -> String` helper, a copy
     of `test/elm-conformance/src/ConformanceHelp.elm`'s `cps` (test/elm cannot import from there).
   - Each row is a labelled `Debug.log`. The expected CHECK values are below. "cp" means the logged
     upper-case hex code point list.

   | Label | Expression | Expected |
   |---|---|---|
   | `up DF` | `cps (String.fromChar (Char.toUpper 'ß'))` | `"DF"` |
   | `up DF len` | `String.length (String.fromChar (Char.toUpper 'ß'))` | `1` |
   | `up FB01` | `cps (String.fromChar (Char.toUpper 'ﬁ'))` | `"FB01"` |
   | `up 1F80` | toUpper U+1F80 | `"1F88"` |
   | `up 1FB3` | toUpper U+1FB3 | `"1FBC"` |
   | `up 1FBC` | toUpper U+1FBC | `"1FBC"` |
   | `lo 130` | toLower U+0130 | `"69"` |
   | `up 130` | toUpper U+0130 | `"130"` |
   | `up E9` | toUpper 'é' | `"C9"` |
   | `lo 416` | toLower 'Ж' | `"436"` |
   | `up 10428` | toUpper U+10428 | `"10400"` |
   | `lo 3A3` | toLower 'Σ' | `"3C3"` |
   | `up 17F` | toUpper U+017F | `"53"` |
   | `lo 212A` | toLower U+212A | `"6B"` |
   | `uplo 1E9E` | `Char.toUpper (Char.toLower 'ẞ')` | `"DF"` |
   | `loc` | `toLocaleUpper` / `toLocaleLower` of `'ß'`, `'i'`, `'İ'`, as a list of cp strings | the same as `toUpper` / `toLower`: `["DF","49","130","DF","69","69"]` (up ß, up i, up İ, lo ß, lo i, lo İ) |
   | `str up` | `cps (String.toUpper "straße")` | `"53 54 52 41 DF 45"` |
   | `str lo sigma` | `cps (String.toLower "ΟΔΟΣ")` | `"3BF 3B4 3BF 3C3"` |
   | `str up fi` | `cps (String.toUpper "ﬁx")` | `"FB01 58"` |
   | `str lo istanbul` | `cps (String.toLower "İstanbul")` | `"69 73 74 61 6E 62 75 6C"` |
   | `str up deseret` | `cps (String.toUpper "\u{10428}x")`, plus `String.length` of it | `"10400 58"` and `3` (UTF-16 units, as JS `.length`; the input is also 3) |
   | `str up lone` | `cps (String.toUpper (String.fromList [ Char.fromCode 0xD800, 'a' ]))` | `"D800 41"` |
   | `str ascii` | `String.toUpper "ſı"` | `"SI"` (the all-ASCII-result path) |
   | `equiv` | for each of `["straße", "ΟΔΟΣ ΑΣ", "ﬁ ﬂ ﬀ", "ᾀᾳῳ", "İıiI", "𐐨𐐩x", "Ǆǅǆ", "ẞß", "abc", ""]`: `String.toUpper s == String.map Char.toUpper s && String.toLower s == String.map Char.toLower s` | `[True,True,True,True,True,True,True,True,True,True]` |
   | `cmp` | `[compare (Char.toUpper 'ß') 'T', compare 'ß' 'ẞ', compare 'a' 'b']` | `[GT,LT,LT]`. ß is U+00DF, above T (U+0054) and below ẞ (U+1E9E). |
   | `eq` | `'ß' == Char.toUpper 'ß'` | `True` |
   | `set` | `Set.size (Set.fromList (List.map Char.toUpper (String.toList "ßß")))` | `1` |
   | `show` | `Debug.toString (Char.toUpper 'ß')` | `"'ß'"`, which the harness compares as UTF-8; or log `cps` of it, `"27 DF 27"` |

   Every value above was checked against the UCD 17.0 data. A row that is not in the table belongs
   to Step 4, not here.
2. **Run it natively once:** `build/test/test --filter CharSimpleCaseTest`. It must report
   `OK (XFAIL: ... Missing pattern: ...)`. The first missing pattern must be a divergence row
   (`up DF` or a later one). The rows that are not divergences (`up E9`, `lo 416`, `up 10428`,
   `up 17F`, `lo 212A`, `cmp`'s last item, `eq`) already hold today.

## Step 2 (commit B): vendored data, generator and tables

1. **Vendor the data.** Create `runtime/third_party/unicode/17.0.0/`:
   - `UnicodeData.txt`: run `update.sh 17.0.0`, which runs
     `curl -fsSL https://www.unicode.org/Public/17.0.0/ucd/UnicodeData.txt -o UnicodeData.txt` and
     `sha256sum`. Confirm `2e1efc1d…470c`.
   - `LICENSE.TXT`: the license text, unedited.
   - `README.md`.
   - `update.sh`.
2. **Rewrite `compiler/scripts/gen-casemap-tables.mjs`.**
   - **Parse.** Split every non-empty line on `;`. Field 0 is the code point (hex); field 12 is the
     simple upper and field 13 the simple lower, empty for none. A range line (`<..., First>`) has
     both empty, so it needs no special case.
   - **Collect** the non-identity pairs, in file order (the file is sorted by code point).
   - **Assert**, failing with a message that names the code point on any of these:
     - the file's sha256 (`crypto.createHash('sha256')`) equals `UCD.sha256`;
     - the counts equal `UCD.upper` / `UCD.lower`;
     - no source or target is in 0xD800..0xDFFF;
     - no pair is an identity;
     - sources are strictly increasing;
     - no pair crosses planes (`(from > 0xFFFF) !== (to > 0xFFFF)` is never true).
   - **Cross-check against node.** If `process.versions.unicode === UCD.version`: for every code
     point `c` in 0..0x10FFFF except surrogates, if `[...String.fromCodePoint(c).toUpperCase()]`
     has length 1, its code point must equal the table's upper of `c`, and likewise for lower.
     - In normal and `--list-divergent` modes, a different node version is an error naming both
       versions.
     - In `--check` mode the version mismatch is also an error, with the message in Step 2.4.
   - **`--list-divergent`.** For each BMP code point except surrogates whose JS upper or lower has
     more than one code point, print `HHHH up|lo simple <HHHH or => elm <HHHH ...>`, upper-case
     hex padded to 4. Assert 103 lines, 75 of them `=`, 27 `up` with a simple value, and 1 `lo`
     with a simple value.
   - **Delete** the closure, ranks, `kEntries`, `kCased`, `kCaseIgnorable` and the ICU and node
     version constants.
3. **The generated `runtime/src/allocator/CaseMapTables.hpp`** has this exact layout:
   - The header comment: `// Generated by compiler/scripts/gen-casemap-tables.mjs; do not edit.`,
     a line naming the source file and its sha256, and the line
     `// Unicode data: Copyright © 1991-2025 Unicode, Inc. Unicode License v3 (runtime/third_party/unicode/17.0.0/LICENSE.TXT).`
     Use the copyright years in that LICENSE.TXT.
   - `#pragma once`, `#include <cstdint>`, then `namespace Elm::CaseMap {`.
   - `inline constexpr const char* kUnicodeVersion = "17.0";` exactly. run-js-e2e.js:412 parses it
     with `/kUnicodeVersion = "([^"]+)"/`.
   - `struct CasePair { uint32_t from; uint32_t to; };`
   - `inline constexpr CasePair kUpper[1505] = {` with one pair per line,
     `    {0x00DF, 0x00DF},`-style: `0x`, upper-case hex, at least 4 digits, wider for code points
     above U+FFFF (`0x10428`). Then `};`. The same for `kLower[1488]`.
   - `}  // namespace Elm::CaseMap`, and LF endings.

   Regenerate with `node compiler/scripts/gen-casemap-tables.mjs > runtime/src/allocator/CaseMapTables.hpp`.
4. **Rewrite `test/scripts/check-casemap-tables.sh`.** It runs
   `"$node" "$repo/compiler/scripts/gen-casemap-tables.mjs" --check "$repo/runtime/src/allocator/CaseMapTables.hpp"`.
   The generator itself reports a Unicode version mismatch, with the message:
   "node <v> has Unicode X; the case tables are Unicode 17.0. Use a node with Unicode 17.0 (the
   conformance tests are recorded from it), or update the vendored data and re-record". The CMake
   call (`CMakeLists.txt:1568-1575`) is unchanged.
5. **Rewrite `runtime/src/allocator/CaseMap.hpp`** (namespace `Elm::CaseMap`). It includes
   `CaseMapTables.hpp` and nothing from `CharValue.hpp`, and holds:
   - `namespace detail { inline uint32_t lookup(const CasePair* t, size_t n, uint32_t cp) }`:
     `std::lower_bound` by `from`, returning `to` on a hit and `cp` otherwise.
   - `inline uint32_t upper(uint32_t cp)`: `if (cp < 0x80) return (cp >= 'a' && cp <= 'z') ? cp - 32 : cp;`
     otherwise `detail::lookup(kUpper, 1505, cp)`. Use `std::size(kUpper)`, not a literal.
   - `inline uint32_t lower(uint32_t cp)`: likewise with `'A'..'Z'` and `+ 32`.
   - `inline uint32_t units(uint32_t cp)`: 2 for 0x10000..0x10FFFF, 1 otherwise (including above
     0x10FFFF, which `writeUnits` writes as one U+FFFD).
   - `inline uint32_t writeUnits(uint32_t cp, uint16_t* out)`: writes 1 or 2 UTF-16 units and
     returns the count. Above 0x10FFFF it writes U+FFFD and returns 1. It must agree with `units`,
     because `String.cpp:77` pre-counts with `units` and `:108` writes with `writeUnits`.

   The file-top comment says that a Char is one code point, that the tables are Unicode simple case
   mapping, and that it cites `plans/char-simple-case-mapping.md`.
6. **Delete `runtime/src/allocator/CharValue.hpp`.** Six files include it: `UtilsExports.cpp`,
   `Utils.cpp`, `CharExports.cpp`, `EcoToLLVM.cpp`, `EcoToLLVMArith.cpp` and `CaseMap.hpp`. Others
   use `CharValue::` through those includes. After Step 3,
   `grep -rnE 'CharValue\.hpp|CharValue::' runtime elm-kernel-cpp eco-kernel-cpp system-kernel-cpp test`
   must print nothing. `testUnboxedCharValue` in HeapHelpersTest is unrelated.
7. **Rewrite `test/allocator/CaseMapTest.cpp` and `.hpp`.** Update the `.hpp` comment at :2-3 and
   keep the registrations in `test/main.cpp:47`, `:1165-1167` and `:1379`, updating the comment at
   :1165. Cases:
   - both tables are strictly sorted, with no identity, surrogate or plane-crossing pair, and their
     sizes are 1505 / 1488;
   - spot values:
     - `upper(0xDF) == 0xDF`, `upper(0x1F80) == 0x1F88`, `upper(0x1FB3) == 0x1FBC`;
     - `lower(0x130) == 0x69`, `upper(0x10428) == 0x10400`, `upper(0xE9) == 0xC9`;
     - `lower(0x3A3) == 0x3C3`, `upper(0x17F) == 0x53`, `lower(0x212A) == 0x6B`;
     - `upper(0xD800) == 0xD800`, `upper(0x110000) == 0x110000`;
   - `writeUnits(0x10400)` writes D801 DC00 and returns 2;
   - `writeUnits(0x110000)` writes FFFD and returns 1, and `units(0x110000) == 1`.

## Step 3 (commit B): consumers

Line numbers are as of 2026-10-30; confirm each before editing.

**Runtime:**
1. **`runtime/src/allocator/StringOps.hpp`**
   - Delete the encoded-Char comments (:29-33). Keep `#include "CaseMap.hpp"` (:48).
   - `codePointUnits` / `encodeCodePoint` (:456-462) still call `CaseMap::units` / `writeUnits`.
     Update their comments, which cite `CharValue::kMaxCharUnits`.
   - `appendCodePoint`'s buffer (:466) becomes `u16 buf[2]`.
   - **`caseMapGeneral` (:758-790)** is rewritten per code point:
     - take the UTF-16 snapshot (`toStdU16String`, as today);
     - at each position `i`: if `buf[i]` is a high surrogate and `buf[i+1]` a low surrogate, take
       the combined code point and advance 2, otherwise take `buf[i]` and advance 1;
     - `m = upper ? CaseMap::upper(cp) : CaseMap::lower(cp)`, then `appendCodePoint(out, m)`;
     - if the result is all ASCII, return it as a UTF-8 form, as today;
     - delete the `0x3A3` / `finalSigmaAt` branch.
   - `toUpper` (:807-847) / `toLower` (:849-889): unchanged structure.
   - `fromChar` (:1388-1400) and `cons` (:1406-1412): buffers `[2]`; delete the comment at :1397.
   - Update the comment at :1455-1460 (`CharToCharMapper`, "encoded…whole expansion") to "a Char
     maps to one code point".
2. **`runtime/src/allocator/RuntimeExports.cpp`**
   - Delete the guard functions (:351-355).
   - `print_char` (:2946-2962): the body becomes `print_char_cp`'s. Delete `print_char_cp` and the
     `CaseMap::entry` expansion, and keep the name `print_char` for its callers (:2989, :3081,
     :3101, :3125, :3153, :3287, :3411-3413).
3. **`runtime/src/allocator/RuntimeExports.h`.** Delete the guard declarations (:392-399). Rewrite
   the `eco_alloc_char` comment (:388-390) and the `eco_dbg_print_char` comment (:671-672) as "a
   Char is one code point".
4. **Comments only.** `Heap.hpp:423-427` (`ElmChar`), `HeapHelpers.hpp:333` and `:360-362`.

**Kernels** (license-pinned):

5. **`elm-kernel-cpp/src/core/Char.cpp`**
   - Keep `#include "CaseMap.hpp"` (:2).
   - `toCode` (:39-61) returns the value, with no `firstCodePoint`.
   - `toLower` / `toUpper` (:63-101) call `CaseMap::lower` / `upper`, with updated comments.
   - `toLocale*` (:103-143): update the NOTE comments to cite this plan.
6. **`elm-kernel-cpp/src/core/CharExports.cpp`**
   - Delete `#include "CharValue.hpp"` (:5).
   - `Elm_Kernel_Char_toCode` (:32-37) keeps `c_raw & 0xFFFFFFFF`, drops the `0x1FFFFF` mask and
     `firstCodePoint`, and returns the value.
   - Update the comment at :39-41.
7. **`elm-kernel-cpp/src/core/Utils.cpp`.** Delete the include (:13). Each
   `CharValue::compare(a, b)` becomes `(a < b) ? -1 : (a > b ? 1 : 0)` on `u32`:
   - `compareUnboxableSlot` kind 3 (:165);
   - the mixed boxed/unboxed Char arm (:260-264);
   - the `cmp` `Tag_Char` arm (:342-353).

   The equality sites (:145-146, :493-494, :578-580) do not change.
8. **`elm-kernel-cpp/src/core/UtilsExports.cpp`**
   - Delete the include (:7).
   - `Elm_Kernel_Utils_compare_Char` (:86-95) compares the `u32` values. Keep its high-bits mask of
     the 64-bit argument as today.
   - `lt/le/gt/ge_Char` (:167-179) compare the values, not `sortKey`.
   - Update the comment at :150-156.

**Codegen:**

9. **`runtime/src/codegen/Passes/EcoToLLVMArith.cpp`**
   - Delete the include (:37) and update the header comments (:7, :17-18).
   - `CharToIntOpLowering` (:1131-1151): delete the `if constexpr` and the `andi 0x1FFFFF`; only
     the `extui` remains.
   - Delete `charSortKey` (:1184-1199).
   - `CharLtOpLowering`, `CharLeOpLowering`, `CharGtOpLowering` and `CharGeOpLowering`
     (:1203-1270), and `CharCmpOrderOpLowering` (:1416-1430), compare the converted operands
     directly: `LLVM::ICmpPredicate::ult/ule/ugt/uge`. `CharCmpOrderOpLowering` uses the same
     select chain over `ult` / `ugt` as today, minus the keys. The doc comments say code-point order.
10. **`runtime/src/codegen/Passes/EcoToLLVM.cpp`.** Delete the include (:40) and the guard injection
    block (:320-332).
11. **`runtime/src/codegen/RuntimeSymbols.cpp`** and **`RuntimeSymbols.h`**. Delete the guard comment
    (:31-32) and the `#if ECO_CHAR_CASE_EXPANSION` entries (:86-96) in the `.cpp`, and the comment
    in the `.h` (:18-20). `RuntimeSymbolMapTest` still passes: the guard was never one of
    `materializeAllRuntimeDecls`' declarations.
12. **`runtime/src/codegen/Ops.td`, comments only.**
    - :212-218: `Eco_Char` is a code point, 0..0x10FFFF.
    - :2708-2712: `char.toInt` is a zero extension.
    - :2739-2743 and :2828-2829: code-point order.
13. **`runtime/src/codegen/EcoOps.h:52-56`.** The `kEcoCharBits` comment.
14. **`compiler/src/Compiler/GlobalOpt/KernelIntrinsics.elm:390-392`.** Comment only: Char ordering
    is code-point order.

**Build:**

15. **CMake.**
    - Root `CMakeLists.txt`: delete the option and `add_compile_definitions` (:133-142). Keep
      `_full_casemap_check` (:1568-1575), and update the comments at :1572 and :1590 that cite the
      old plan.
    - Delete the `ECO_CHAR_CASE_EXPANSION` blocks in `test/gc-heap-tsan/CMakeLists.txt` (:20-27)
      and `test/gc-helper-tsan/CMakeLists.txt` (:13-20).
16. **`heap-profile.py:113` and `:1943`.** Update the comments that mention the OFF tree. Keep the
    `--lower-with-build-tree` option itself: it is generic.
17. **Check for leftovers.**
    `grep -rn ECO_CHAR_CASE_EXPANSION . --exclude-dir=build --exclude-dir=snapshots --exclude-dir=.git`
    may only print lines in `plans/char-case-mapping-elm-exact.md`, `test/tla/*/AUDIT.md` (history)
    and this plan.

**Tests:**

18. **`test/kernel/KernelExportsTest.cpp`**
    - **K17** (`test_char_encoded_kernels`, :319-389) is rewritten as "K17 Char ordering at the
      kernel boundary". It keeps the ordinary values and checks R < S < T < U+E000 < U+1F600 through:
      - `Elm_Kernel_Utils_lt_Char` / `ge_Char`;
      - `Elm_Kernel_Utils_compare_Char`, with a 64-bit argument whose high bits are set;
      - boxed `cmp` on two `Tag_Char` objects;
      - the mixed boxed/unboxed arm;
      - `compareUnboxableSlot` kind 3, through a two-Char tuple compare.

      Delete the encoded synthetic values, the expansion writers, the `'SS'` Debug and the
      `encodeCodePoint(0x150000)` lines. Keep its registration (:858), with the new name.
    - **K18** (`test_case_mapping_kernels`, :391-428) changes to:
      - `toUpper(0xDF) == 0xDF` and `toCode` 0xDF;
      - `String.toUpper "straße"` → `"STRAßE"`;
      - `"ﬁx"` → `"ﬁX"`;
      - `"ΟΔΟΣ"` lower → `"οδοσ"`;
      - the all-ASCII-result path: `String.toUpper` of `"ſı"` gives `"SI"`, and the result is a UTF-8
        form (check its tag, as the existing UTF-8 tests do);
      - a slice input ending in Σ: `StringOps::slice` of `"xΑΣx"` to `"ΑΣ"`, then lower, gives
        `"ασ"`;
      - kept: the `0xE9`, `0x416` and 64-bit-mask `'a'` checks.
    - Drop `#include "CaseMap.hpp"` (:15) if nothing else in the file uses it.
19. **Codegen fixtures.**
    - Delete `test/codegen/char_toInt_encoded.mlir`, `char_cmp_encoded.mlir` and
      `char_case_build_guard.mlir`.
    - Add `test/codegen/char_toInt_cmp_plain.mlir`, modelled on `char_cmp_encoded.mlir`'s module and
      using a check prefix per RUN line, as `test/codegen/inline_alloc_tuple.mlir` does.
    - `RUN: %ecoc %s -emit=mlir-llvm 2>&1 | %FileCheck %s --check-prefix=IR` checks:
      - in the function using `eco.char.toInt`, `llvm.zext` and `CHECK-NOT` / `IR-NOT: 2097151`;
      - in the comparison function, `llvm.icmp "ult"` with `IR-NOT: llvm.intr.fsh` and
        `IR-NOT: llvm.shl`;
      - `IR-NOT: eco_char_case_expansion`.
    - `RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s --check-prefix=JIT` prints three results:
      `'a' < 'b'` is 1; U+E000 < U+10000 is 1 (code-point order, where JS UTF-16 order would give
      0); and `toInt 0x10FFFF` is 1114111.
20. **`test/CMakeLists.txt`.** `allocator/CaseMapTest.cpp` stays.

**Build and run:** `cmake --build build --target test`, then run:
- `CaseMap`, K17, K18, `RuntimeSymbolMap`, `char_toInt_cmp_plain`;
- `CharSimpleCaseTest`, which now XPASSes and so fails; Step 4.1 removes its marker.

Kernel-license errors are expected until Step 5.4. To build meanwhile, add the audit rows first
(Step 5.4) or build only the `test` target.

## Step 4 (commit B): conformance tests

Six case tests in `test/elm-conformance/src` hold expectations recorded from Elm on node. Each logs
rows through `ConformanceHelp.logAll`. Most generate their rows with an `entries` function over an
`inputs` list (`CharCaseSpecialTest.elm:61-89`), so rows move by moving *inputs*, not CHECK lines.

1. **CharSimpleCaseTest.** Remove its `-- XFAIL-NATIVE:` line and run it natively: it must pass.
2. **Rename `CharCaseEncodedOpsTest.elm` to `CharCaseMappedOpsTest.elm`** (module name too). Keep
   it whole as a divergence record:
   - its rows are Elm's operations on multi-code-point results;
   - add the header `-- XFAIL-NATIVE: deliberate divergence from Elm: eco uses Unicode simple case
     mapping, so these mapped Chars are single code points (design_docs/char-case-mapping.md)`;
   - update its doc comment;
   - re-record its CHECKs: `node test/scripts/run-js-e2e.js --project elm-conformance --record CharCaseMappedOpsTest`.
     The recorder prints CHECK lines and does not edit, so replace the file's CHECK block with them.
3. **Find the diverging rows mechanically.** For each of `CharCaseSpecialTest`,
   `CharLocaleCaseTest` and `StringCaseTest`:
   - run it natively once, with all output kept:
     `ECO_TEST_OUTPUT_LIMIT=1000000 build/test/test --filter <Test> > $S/<Test>.native.txt 2>&1`;
   - diff its CHECK lines against the actual `label: "value"` lines:
     `grep '^-- CHECK: ' src/<Test>.elm | sed 's/^-- CHECK: //' | sort > want.txt`, the same for
     the output, and `comm -23 want.txt got.txt`;
   - every line that `comm -23` prints is a diverging row.

   Expected result, from the reviewer's computation (2026-10-30):

   | Test | Diverging rows |
   |---|---|
   | CharCaseSpecialTest | 31: `up`, `upCode` and `upLen` of DF, FB01, FB02, FB00, 1F0, 149, 390, 3B0, 1FB3 and 1FBC, plus `130 lo` |
   | CharLocaleCaseTest | `DF locUp`, `FB01 locUp` |
   | StringCaseTest | the `up` rows of strasse, final, j caron, iota dt, alpha ypo, athens and mixed; `istanbul lo`; the `lo` rows of s1, s4, s5, s6, s7, s10, s12, s13 and s14 (exactly the rows whose recorded value contains 3C2) |
   | CharCaseOrdinaryTest | none (run it too, to confirm) |

   - **A diverging row outside this table:** check whether its input contains an Appendix A code
     point, U+1E9E or a Σ. If it does, add it to the split and note it here. If it does not, it is
     a bug in Steps 2-3: stop and fix it.
   - **A precise cross-check, optional:** a node script that applies the UCD simple mapping to each
     row's input gives eco's expected value directly.
4. **Create `test/elm-conformance/src/CaseMappingDivergenceTest.elm`.**
   - Copy the `entries` / helper functions the three tests use for their diverging inputs, with the
     same label scheme.
   - Move each diverging *input* (whole `( name, Char )` or string entry) from its test's input list
     into the new test's. All rows of a moved input go with it, including the ones that agree; the
     divergence test is a record.
   - Header: `-- XFAIL-NATIVE: deliberate divergence from Elm: eco uses Unicode simple case mapping
     and no Final_Sigma (design_docs/char-case-mapping.md); these rows are Elm's full mapping`.
   - Do not add a `==` between a mapped Char and a Char that is a prefix of its expansion. The
     recorder's mode guard (`run-js-e2e.js:349-390`) throws on it, because debug-mode Elm compares
     those differently.
   - Record its CHECKs with `--record`, and re-record the three trimmed tests the same way. Replace
     each CHECK block with the recorder's output; do not hand-edit CHECK lines.
5. **Rework `CharCaseFullRangeTest.elm`.**
   - Add `skip : Set Int`, built once with `Set.fromList` from the 103 Appendix A code points plus
     U+1E9E (the composition, see "Verified facts") and U+03A3.
   - **`plane` hashes:** skip a code point `c` when `Set.member c skip`.
   - **`strplane` hashes:** build each 0x100 block's string from its code points minus those in
     `skip`. Do not skip whole blocks; that would drop ASCII and Latin-1.
   - **`sorted`:** exclude results whose source is in `skip`.
   - Update the doc comment to say what is skipped and why, and point to
     CaseMappingDivergenceTest.
   - Re-record its CHECKs. **Sanity check:** the `plane 1..16` and `strplane 1..16` lines must be
     byte-identical to today's, because no code point above the BMP is skipped. If they differ, the
     rework changed the hash structure: fix the code, not the expectations.
   - Add one row to CaseMappingDivergenceTest that logs, for all 103 Appendix A code points, Elm's
     `toUpper` and `toLower` code points (`cps` per Char), then re-record that test.
6. **`test/scripts/run-js-e2e.js`.** Keep the `unicodeTables` preflight (:409-418): it still reads
   `kUnicodeVersion` from the new header. Update its comment (:410-411) to cite this plan.
7. **Run on both targets.**
   - JS: `node test/scripts/run-js-e2e.js --project elm-conformance`. Every test passes, including
     the two divergence records.
   - Native: `build/test/test --filter elm-conformance/`. The agreeing tests pass;
     `CaseMappingDivergenceTest`, `CharCaseMappedOpsTest` and the three Float records report XFAIL.

## Step 5 (commit B): invariants, docs, audits, bookkeeping

1. **`design_docs/invariants.csv`**
   - **Rewrite KERN_008's description and keep its status `tested`.** Text:

     > A Char value is one Unicode code point in a u32: 0..0x10FFFF, a lone surrogate being its own
     > unit value. No larger value is produced: Char.fromCode and eco.char.fromInt give U+FFFD
     > outside the range, and String writers write a value above 0x10FFFF as U+FFFD. Equality and
     > ordering are unsigned integer comparison, and toCode is the value. Case mapping is the
     > Unicode simple case mapping (UnicodeData.txt 17.0 fields 12/13), from tables generated by
     > compiler/scripts/gen-casemap-tables.mjs from the vendored runtime/third_party/unicode file
     > and checked in full. toLocaleUpper/toLocaleLower equal toUpper/toLower. String.toUpper and
     > toLower map each code point with the same tables, so they commute with String.map
     > Char.toUpper/toLower and never change a String's length. Divergences from Elm-on-JS:
     > design_docs/char-case-mapping.md.

     Sources: `CaseMap.hpp`, `CaseMapTables.hpp`, `CaseMapTest.cpp`, `char_toInt_cmp_plain.mlir`,
     K17/K18, `CharSimpleCaseTest`, `test/elm-conformance`.
   - **CGEN_015:** delete the clause "or an encoded case-mapping result in 0x200000..0x1FFFFFFF
     (bits 29-31 zero)…" and the "(Updated 2026-10-28: encoded case-mapping results…)" note. Keep
     the other "Updated 2026-10-28" note (Char widened from 16 bits).
   - **REP_ABI_001:** replace "holding a Char value (CGEN_015, KERN_008)" with "holding a code point
     (CGEN_015)".
   - **REP_SSA_001:** replace "a Char value per CGEN_015/KERN_008" with "a code point per CGEN_015".
   - **REP_HEAP_002:** replace "the Char value (KERN_008)" with "the code point".
2. **New `design_docs/char-case-mapping.md`**, modelled on `design_docs/float-semantics.md`. Sections:
   - the semantics (from "Design");
   - why: one code point per Char, and the standard's own mapping;
   - **divergences from Elm-on-JS:**
     - the 103 code points by group: 75 unchanged, 27 to title case, İ → i;
     - word-final Σ in `String.toLower`;
     - derived divergences: `toCode`, `String.length (String.fromChar …)` and `String.fromChar`
       of a mapped result; ordering, `Set` and `Dict` of mapped results; compositions such as
       `toUpper (toLower 'ẞ')`;
   - the JS target's scope, which keeps Elm's behaviour;
   - **updating to a new Unicode version:**
     1. run `update.sh <version>` into a new directory;
     2. update `UCD` in the generator, and the path;
     3. regenerate the tables;
     4. on a node of that Unicode version, re-record every elm-conformance case test and check that
        `--list-divergent` still matches Appendix A, updating it if not;
   - the list of tests.
3. **Docs to edit:**
   - `THEORY.md:84`: "a Char is one Unicode code point, in 32 bits".
   - `design_docs/theory/value-representation.md:31`: delete the encoding paragraph and keep :29.
   - `design_docs/theory/kernels/elm-kernel.md:13`: rewrite (simple case mapping, vendored data,
     node cross-check).
   - `design_docs/theory/kernels/elm-kernel.md:15`: delete the divergence items about encoded
     values, `Json_wrap_Char` and the OFF flag, and point to char-case-mapping.md. Keep the
     debug-mode `==` note only if it still concerns Elm's own values.
   - `design_docs/theory/backend/eco-dialect.md:17`: drop the encoded clause.
   - `design_docs/theory/runtime/data-structures.md:64`: rewrite. Case mapping maps each code point
     and never changes the length; `"straße"` → `"STRAßE"`.
   - `design_docs/kernel-boundary/audit-01-basics-bitwise-char-utils.md:156-158` and
     `audit-02-string.md:44` and `:203`: add a dated note. :203 still says "ASCII-only", which is
     stale.
   - `design_docs/utf8-string-encoding-investigation.md:235`: add a dated note.
4. **Kernel license re-audit.**
   - Append one row per kernel to `compiler/src/Compiler/MonoSolver/kernel-license-audit.csv`, 15
     in all (see Constraints). Each row is `<kernel>,<date>,plans/char-simple-case-mapping.md,"<note>"`,
     where the date is a UTC stamp (`date -u +%Y-%m-%dT%H:%M:%S`) strictly after the pin's. Use a
     note per file:
     - `Char.cpp`, `CharExports.cpp`: "toCode returns the value (no 0x1FFFFF mask / firstCodePoint);
       toUpper/toLower/toLocale* map through CaseMap simple tables; includes changed; no
       application, retention, fabrication or type change; B1-B3 unchanged".
     - `Utils.cpp`, `UtilsExports.cpp`: "Char compare is unsigned integer order (CharValue::compare
       / sortKey removed); include removed; no application, retention, fabrication or type change;
       B1-B3 unchanged".
   - Insert each row after that kernel's last existing row. A small python script does this, as on
     2026-10-30.
   - Then run `sh test/scripts/check-kernel-license-manifest.sh . --update`, then the check without
     `--update`, which must exit 0. Validate the CSV with `python3 -c 'import csv; ...'`: every row
     has 4 fields.
5. **The old plan.** Set `plans/char-case-mapping-elm-exact.md`'s front matter to
   `status: superseded`, `updated: <today>`, `superseded_by: "plans/char-simple-case-mapping.md"`.
   Its text stays as history.
6. **The TLA+ canary.** `sh test/scripts/check-tla-manifest.sh .` must pass without `--update`; if a
   pin fires, follow test/tla/README.md "The canary". Then run
   `cmake --build build --target tla-trace` once, because the harness CMakeLists changed. It must
   build and report the expected rows.
7. **Memory** (`/home/dev/.claude/projects/-work/memory/`).
   - Mark `char-case-mapping-elm-exact-done.md` superseded and say what was kept: elm-conformance,
     `--record`, XFAIL-NATIVE, the mode guard.
   - Add a note for this plan, with its `MEMORY.md` pointer.
   - Fix the stale `MEMORY.md` line 12 ("Char = UTF-16 unit, toUpper ASCII-only").

## Step 6: gates (after commit B)

Run each gate once, with output to a file in the scratchpad:
1. `cmake --build build --target elm-tests`. The compiler change is only a comment.
2. `cmake --build build --target full`. It runs the casemap check, the native suites, the JS runner,
   the Node addon tests and the driver checks.
3. `cmake --build build --target stress-test && build/test/stress-test`.
4. `cmake --build build --target bootstrap`. The Char comparison lowering changes the compiler's own
   code; the 4b and 8c fixed points must hold.
5. **A `benchmarks/fe-opt-loop.md` regression row**, following its protocol on an idle machine,
   after deleting cached objects (Constraints). The 2026-10-28 Char work is the recorded first
   suspect for a +2.9 s parse/check/build drift (entry "FloatMinMax"). Record whether removing the
   rotl and the mask moves that phase.

Then set this plan to `status: done`, with progress notes, and mark the case-mapping entries in
`cpp-review-bugs.md`, if any, accordingly.

## Appendix A: the 103 code points where simple mapping differs from Elm-on-JS

`node compiler/scripts/gen-casemap-tables.mjs --list-divergent` prints this list (Step 2.2). Format:
code point, which mapping, the simple result (`=` means unchanged), and Elm's result. U+1E9E is
not listed: it diverges only through composition (see "Verified facts").

```
00DF up simple = elm 0053 0053
0130 lo simple 0069 elm 0069 0307
0149 up simple = elm 02BC 004E
01F0 up simple = elm 004A 030C
0390 up simple = elm 0399 0308 0301
03B0 up simple = elm 03A5 0308 0301
0587 up simple = elm 0535 0552
1E96 up simple = elm 0048 0331
1E97 up simple = elm 0054 0308
1E98 up simple = elm 0057 030A
1E99 up simple = elm 0059 030A
1E9A up simple = elm 0041 02BE
1F50 up simple = elm 03A5 0313
1F52 up simple = elm 03A5 0313 0300
1F54 up simple = elm 03A5 0313 0301
1F56 up simple = elm 03A5 0313 0342
1F80 up simple 1F88 elm 1F08 0399
1F81 up simple 1F89 elm 1F09 0399
1F82 up simple 1F8A elm 1F0A 0399
1F83 up simple 1F8B elm 1F0B 0399
1F84 up simple 1F8C elm 1F0C 0399
1F85 up simple 1F8D elm 1F0D 0399
1F86 up simple 1F8E elm 1F0E 0399
1F87 up simple 1F8F elm 1F0F 0399
1F88 up simple = elm 1F08 0399
1F89 up simple = elm 1F09 0399
1F8A up simple = elm 1F0A 0399
1F8B up simple = elm 1F0B 0399
1F8C up simple = elm 1F0C 0399
1F8D up simple = elm 1F0D 0399
1F8E up simple = elm 1F0E 0399
1F8F up simple = elm 1F0F 0399
1F90 up simple 1F98 elm 1F28 0399
1F91 up simple 1F99 elm 1F29 0399
1F92 up simple 1F9A elm 1F2A 0399
1F93 up simple 1F9B elm 1F2B 0399
1F94 up simple 1F9C elm 1F2C 0399
1F95 up simple 1F9D elm 1F2D 0399
1F96 up simple 1F9E elm 1F2E 0399
1F97 up simple 1F9F elm 1F2F 0399
1F98 up simple = elm 1F28 0399
1F99 up simple = elm 1F29 0399
1F9A up simple = elm 1F2A 0399
1F9B up simple = elm 1F2B 0399
1F9C up simple = elm 1F2C 0399
1F9D up simple = elm 1F2D 0399
1F9E up simple = elm 1F2E 0399
1F9F up simple = elm 1F2F 0399
1FA0 up simple 1FA8 elm 1F68 0399
1FA1 up simple 1FA9 elm 1F69 0399
1FA2 up simple 1FAA elm 1F6A 0399
1FA3 up simple 1FAB elm 1F6B 0399
1FA4 up simple 1FAC elm 1F6C 0399
1FA5 up simple 1FAD elm 1F6D 0399
1FA6 up simple 1FAE elm 1F6E 0399
1FA7 up simple 1FAF elm 1F6F 0399
1FA8 up simple = elm 1F68 0399
1FA9 up simple = elm 1F69 0399
1FAA up simple = elm 1F6A 0399
1FAB up simple = elm 1F6B 0399
1FAC up simple = elm 1F6C 0399
1FAD up simple = elm 1F6D 0399
1FAE up simple = elm 1F6E 0399
1FAF up simple = elm 1F6F 0399
1FB2 up simple = elm 1FBA 0399
1FB3 up simple 1FBC elm 0391 0399
1FB4 up simple = elm 0386 0399
1FB6 up simple = elm 0391 0342
1FB7 up simple = elm 0391 0342 0399
1FBC up simple = elm 0391 0399
1FC2 up simple = elm 1FCA 0399
1FC3 up simple 1FCC elm 0397 0399
1FC4 up simple = elm 0389 0399
1FC6 up simple = elm 0397 0342
1FC7 up simple = elm 0397 0342 0399
1FCC up simple = elm 0397 0399
1FD2 up simple = elm 0399 0308 0300
1FD3 up simple = elm 0399 0308 0301
1FD6 up simple = elm 0399 0342
1FD7 up simple = elm 0399 0308 0342
1FE2 up simple = elm 03A5 0308 0300
1FE3 up simple = elm 03A5 0308 0301
1FE4 up simple = elm 03A1 0313
1FE6 up simple = elm 03A5 0342
1FE7 up simple = elm 03A5 0308 0342
1FF2 up simple = elm 1FFA 0399
1FF3 up simple 1FFC elm 03A9 0399
1FF4 up simple = elm 038F 0399
1FF6 up simple = elm 03A9 0342
1FF7 up simple = elm 03A9 0342 0399
1FFC up simple = elm 03A9 0399
FB00 up simple = elm 0046 0046
FB01 up simple = elm 0046 0049
FB02 up simple = elm 0046 004C
FB03 up simple = elm 0046 0046 0049
FB04 up simple = elm 0046 0046 004C
FB05 up simple = elm 0053 0054
FB06 up simple = elm 0053 0054
FB13 up simple = elm 0544 0546
FB14 up simple = elm 0544 0535
FB15 up simple = elm 0544 053B
FB16 up simple = elm 054E 0546
FB17 up simple = elm 0544 053D
```

## Review log

- **2026-10-30, adversarial review** (3 blockers, 6 major, 10 minor), all folded in above:
  - the `compare (toUpper 'ß') 'T'` expectation is GT, not LT;
  - the U+1E9E composition divergence in CharCaseFullRangeTest;
  - `kernel-license-check` is in ALL, the Utils pins are dated 2026-10-30, and the commit can
    therefore not land before 2026-10-31;
  - the commit boundaries;
  - K17 kept as an ordering test;
  - the K18 ASCII-result and slice cases;
  - cached `.o` files no longer link;
  - the input-level, recorder-based split procedure;
  - the generator's version constant and CLI;
  - strplane filtering instead of block skipping;
  - the CharValue include inventory, plus missed comment sites and heap-profile.py;
  - case mapping changes no UTF-16 length (asserted);
  - `units` / `writeUnits` agreement;
  - the `toCode` ABI truncation;
  - the exact invariant edits, with KERN_008 kept as `tested`;
  - the doc locations, MEMORY.md line 12, the derived divergences, the vendoring convention, the
    table's integer type and hex format, and the check prefixes.
