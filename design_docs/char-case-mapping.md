# Char and String case mapping in eco

A `Char` in eco is always exactly one Unicode code point, and case mapping takes one code point to
one code point: the Unicode Standard's **simple case mapping**, `UnicodeData.txt` field 12
(Simple_Uppercase_Mapping) and field 13 (Simple_Lowercase_Mapping), with no context and no locale
(invariant KERN_008, plans/char-simple-case-mapping.md). Where Elm on JavaScript behaves
differently, eco differs on purpose; the differences are listed below.

This is the semantics of eco's NATIVE output. eco's JavaScript output is produced by Elm's own JS
generator, so it keeps Elm's JS behaviour (the differences below), as for Float
(design_docs/float-semantics.md).

The tests are the contract:

- `test/elm/src/CharSimpleCaseTest.elm` (native): eco's semantics.
- `test/elm-conformance/src/CharCaseOrdinaryTest.elm`, `CharCaseSpecialTest.elm`,
  `CharLocaleCaseTest.elm`, `StringCaseTest.elm`, `CharCaseFullRangeTest.elm`: rows where eco and
  Elm agree, recorded from Elm on node and run on both targets.
- `test/elm-conformance/src/CaseMappingDivergenceTest.elm` and `CharCaseMappedOpsTest.elm`: Elm's
  own behaviour where eco differs, recorded from Elm on node and marked `XFAIL-NATIVE` for good, so
  each difference stays visible.
- Lower level: `test/allocator/CaseMapTest.cpp` (the tables), K17/K18 in
  `test/kernel/KernelExportsTest.cpp` (the kernels), `test/codegen/char_toInt_cmp_plain.mlir` (the
  lowering).

## The semantics

| Operation | eco |
|---|---|
| A `Char` value | One code point, 0..0x10FFFF, held in a `u32` (i32 in SSA and the ABI). A lone surrogate in a String is a Char of its own unit value. |
| `Char.fromCode` | The code point; U+FFFD outside 0..0x10FFFF (as Elm). |
| `Char.toCode` | The value. |
| `==` `/=` `<` `compare`, `sort`, `Dict`, `Set` on Char | Unsigned integer comparison: code-point order. |
| `Char.toUpper` / `toLower` | The simple mapping of the code point, or the code point itself. |
| `Char.toLocaleUpper` / `toLocaleLower` | The same as `toUpper` / `toLower`. |
| `String.toUpper` / `toLower` | The simple mapping of every code point (a valid surrogate pair is one code point, a lone surrogate is left as it is). No Final_Sigma rule. |

So, for every String `s`:

- `String.toUpper s == String.map Char.toUpper s` and `String.toLower s == String.map Char.toLower s`;
- `String.length (String.toUpper s) == String.length s`, and the same for `toLower`. No simple
  mapping crosses between the BMP and the supplementary planes (the generator asserts it), so the
  length is unchanged in UTF-16 units as well as in code points.

## Why

Elm on JS implements `Char.toUpper c` as `c.toUpperCase()`, JavaScript's *full* case mapping, and
returns the resulting string as a `Char`. For 103 code points that string has more than one code
point (`'ß'` to "SS", `'ﬁ'` to "FI", `'İ'` to "i̇"), and such a Char is no longer a character:
`String.length (String.fromChar (Char.toUpper 'ß')) == 2`, appending one Char can grow a String by
three code points, and `Char.toCode` answers for the first code point only.

The simple mapping is the standard's own per-character mapping. With it, a Char is always a
character, and case mapping is a total function from code points to code points. From 2026-10-28
to 2026-10-30 eco reproduced Elm's full mapping by encoding the multi-code-point results as Char
values above 0x10FFFF (plans/char-case-mapping-elm-exact.md); that took a rank table, a rotated
sort key, a masked `toCode`, expanding String writers, a build flag, a link guard and a
Final_Sigma context rule, all now removed.

## Differences from Elm on JavaScript

Wherever node's full mapping of a code point is a single code point, it equals the simple
mapping (the generator checks every code point on every run). The differences are:

- **103 code points whose full mapping has several code points**, all in the BMP.
  `node compiler/scripts/gen-casemap-tables.mjs --list-divergent` prints them, and
  plans/char-simple-case-mapping.md Appendix A records the list. Under the simple mapping:
  - 75 map to themselves (`toUpper 'ß' == 'ß'`; Elm gives "SS"). Among them are the Latin and
    Armenian ligatures (ﬀ..ﬆ, ﬓ..ﬗ, և), ŉ, ǰ, ẖ..ẚ, Greek letters with dialytika or
    perispomeni such as ΐ and ΰ, and the Greek title-case letters with iota subscript
    (ᾈ..ᾏ, ᾘ..ᾟ, ᾨ..ᾯ, ᾼ, ῌ, ῼ);
  - 27 uppercase to their one-code-point title-case form (`toUpper 'ᾀ' == 'ᾈ'`,
    `toUpper 'ᾳ' == 'ᾼ'`; Elm gives "ἈΙ" and "ΑΙ");
  - `toLower 'İ' == 'i'` (U+0130 to U+0069; Elm gives "i̇", i plus U+0307).
- **Word-final Σ.** Elm's `String.toLower` applies JavaScript's Final_Sigma rule, so a capital
  sigma at the end of a word becomes ς (U+03C2): `String.toLower "ΟΔΟΣ" == "οδος"`. eco always
  gives σ (U+03C3): "οδοσ". `Char.toLower 'Σ'` is σ in both.
- **What follows from these:**
  - `Char.toCode`, `String.fromChar` and `String.length (String.fromChar …)` of a mapped
    result (Elm: 83, "SS" and 2 for `Char.toUpper 'ß'`; eco: 223, "ß" and 1);
  - equality, ordering, `Set` and `Dict` keys of mapped results (in Elm, `Char.toUpper 'ß'` sorts
    between 'S' and 'T');
  - compositions: `toUpper (toLower 'ẞ')` (U+1E9E) is "SS" in Elm and ß in eco. U+1E9E is the only
    code point that diverges only through a composition.
  - `String.toUpper` / `toLower` of any String containing one of the 103 code points.
- **Locales.** In a browser with a Turkish, Azeri or Lithuanian locale, Elm's `toLocale*` apply
  that locale's rules. On node, without an argument, they ignore the process locale, so they equal
  `toUpper` / `toLower`, as in eco.

## The data

- `runtime/third_party/unicode/17.0.0/UnicodeData.txt`, vendored, with `LICENSE.TXT` (Unicode
  License v3) and `README.md` (URL, sha256, consumer) in `runtime/third_party/unicode/`. It is not
  installed or bundled.
- `compiler/scripts/gen-casemap-tables.mjs` generates `runtime/src/allocator/CaseMapTables.hpp`:
  `kUpper` (1,505 pairs) and `kLower` (1,488 pairs), every non-identity simple mapping, ASCII
  included, sorted by code point. It asserts the file's sha256, the table sizes, that no pair is an
  identity, involves a surrogate or crosses planes, and (with node of the same Unicode version)
  that node agrees wherever its full mapping is one code point.
- `runtime/src/allocator/CaseMap.hpp` maps: an ASCII fast path, then a binary search.
- `full` runs `test/scripts/check-casemap-tables.sh`, which regenerates the header in memory and
  fails if it differs, or if node's Unicode version is not the tables'. The conformance tests are
  recorded from node, so the two must match.

The parser's identifier classes come from a different generator and reference
(`compiler/scripts/gen-unicode-classes.py`, Python's Unicode 14.0, matching upstream Elm's
compiler); the two Unicode versions are independent.

## Updating to a new Unicode version

1. `sh runtime/third_party/unicode/update.sh <version>` (e.g. `18.0.0`) downloads `UnicodeData.txt` into
   `runtime/third_party/unicode/<version>/` and prints its sha256.
2. In `gen-casemap-tables.mjs`, update `UCD`: `version`, `dir`, `sha256`, and the counts
   (`upper`, `lower`, `divergent*`), which the script reports when they no longer match.
3. Regenerate: `node compiler/scripts/gen-casemap-tables.mjs > runtime/src/allocator/CaseMapTables.hpp`.
   This needs a node of the new Unicode version (`process.versions.unicode`).
4. On that node, re-record every elm-conformance case test
   (`node test/scripts/run-js-e2e.js --project elm-conformance --record <Test>`), check that
   `--list-divergent` still matches plans/char-simple-case-mapping.md Appendix A (update this page
   and the skip list in `CharCaseFullRangeTest.elm` if not), and delete the old data directory.
