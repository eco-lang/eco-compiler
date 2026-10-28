---
status: not-started
updated: 2026-10-28
---

# Elm-exact Char case mapping with an encoded range

## Why

`Char` is now a 32-bit code point (plans/review-bug-triage-fixes.md Part 1, done 2026-10-28), but
`Char.toUpper`/`toLower`/`toLocaleUpper`/`toLocaleLower` are still ASCII-only
(`elm-kernel-cpp/src/core/CharExports.cpp`, `Char.cpp`): every non-ASCII letter is left unchanged,
where Elm maps it.

Elm-on-JS implements them as `_Utils_chr(char.toUpperCase())`: JavaScript's full Unicode case
mapping on the Char's string. For about 100-150 characters that mapping yields more than one code
point (`'ß'` -> `"SS"`, `'ﬁ'` -> `"FI"`, `'ǰ'` -> `"J̌"`, `'ΐ'` -> 3 code points, `toLower 'İ'` ->
`"i̇"`), and Elm returns that multi-code-point string as a `Char`. Programs observe it:
`String.map Char.toUpper "straße" == "STRASSE"`, `Char.toCode (Char.toUpper 'ß') == 83`,
`Char.toUpper 'ß' /= 'S'`.

Goal: reproduce Elm-on-JS exactly while keeping `Char` a fixed-size `i32`.

## Design

Code points stop at 0x10FFFF; an `i32` Char has room above that. A Char value is either:

- `0 .. 0x10FFFF`: an ordinary code point (unchanged);
- `0x110000 + i`: entry `i` of a generated, read-only table of special case-mapping results, each a
  short sequence (2-3) of code points.

Only the four case-mapping functions produce encoded values, and only when the full mapping has
more than one code point. Literals, `Char.fromCode` (still U+FFFD outside 0..0x10FFFF),
`String.toList`/`uncons`/folds, elm/parser and JSON decoding produce ordinary code points only.

### The table

Generated (like the Part 2 Unicode letter tables) from Unicode `UnicodeData.txt` (simple 1:1
mappings) and `SpecialCasing.txt` (unconditional entries only; JS's default `toUpperCase` uses no
conditional/locale entries):

1. Simple map: code point -> code point, for every character whose full mapping is one code
   point (the ordinary case: all Latin, Greek, Cyrillic, ...).
2. Special map: code point -> table index, for every character whose full mapping is longer.
3. Closure: for every table entry, apply full upper and lower mapping to its expansion; a
   single-code-point result maps there, a longer one becomes (or reuses) an entry. Repeat to a
   fixed point (e.g. `toLower "SS"` = `"ss"`). The table is finite and fixed at build time.

Generator output: one C++ header for the kernels (sorted arrays, binary search) and, if the
compiler needs it (constant folding), an Elm module. Pin the Unicode version to the one node uses
for the JS backend, so both backends agree.

### Semantics of an encoded value (must equal Elm-on-JS)

| Operation | Behaviour |
|---|---|
| `Char.toCode` | first code point of the expansion |
| `isUpper`/`isLower`/`isAlpha`/... | as Elm: through `toCode` |
| `String.fromChar`, `cons`, `fromList`, `map`, `filter`, folds, `any`/`all` callbacks | expand to the entry's code points when written into a String; callbacks receive the value as is |
| `==` | integer equality (`toUpper 'ß' /= 'S'`, as Elm) |
| `<`, `compare`, `Dict`/`Set` keys | compare the expanded UTF-16 sequences (Elm compares the strings) |
| `case` on Char literals | never matches (literal patterns are code points) |
| `Debug.toString` / `Debug.log` | the expansion between quotes (`'SS'`) |
| case mapping of an encoded value | table lookup (closed) |

### Locale variants

`toLocaleUpper`/`toLocaleLower` follow the host locale in Elm-on-JS. Decide: (a) treat as the
default locale (same as `toUpper`/`toLower`), or (b) add the Turkish/Azeri/Lithuanian conditional
tables keyed by the runtime locale. Recommend (a) first, documented; (b) as a follow-up.

## Changes

1. Generator script + generated tables (C++ header; Elm module if needed).
2. `CharExports.cpp`/`Char.cpp`: `toUpper`/`toLower`/`toLocale*` via the simple map, then the
   special map returning `0x110000 + i`.
3. `Char.toCode` (kernel and the `eco.char.toInt` lowering if it is ever applied to a case-mapped
   value: an encoded value can reach it, so the lowering needs the range check or must call the
   kernel).
4. String kernels that write Chars into UTF-16 (`fromChar`, `cons`, `fromList`, `map`, `filter`,
   `reverse` is unaffected): one `c > 0x10FFFF` check, then append the expansion. Shared helper
   next to `appendCodePoint`.
5. Char comparison (`Utils` compare, `eco.char.lt` and friends): encoded values compare by
   expansion; ordinary values keep the integer compare (fast path).
6. Debug printer: expand.
7. Invariants and docs: REP_HEAP_002 and value-representation.md ("a Char is a code point, or
   0x110000+i naming a special case-mapping result"); CGEN_015 if it states the value range.
8. LSS_022 re-audit for every licensed row whose kernel file changes.

## Tests

- E2E comparing native against the JS backend's output (stock elm) for: `toUpper`/`toLower` of
  `ß ﬁ ﬂ ǰ ŉ ΐ ΰ ᾳ İ`, ordinary Latin/Greek/Cyrillic/Armenian letters; `String.map Char.toUpper
  "straße"`; `toCode (toUpper 'ß')`; `toUpper 'ß' == 'S'`; `compare` and a `Set` of encoded
  values; `Debug.log` of one; `toLower (toUpper 'ß')`.
- Unit tests for the generator's closure and for the kernels' range checks.

## Gate

elm-tests, `full`, stress, JS E2E and the bootstrap, each run once; the new E2E outputs must equal
the JS backend's.
