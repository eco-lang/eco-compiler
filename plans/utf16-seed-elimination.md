# UTF-16 Seed Elimination: fromChar/fromList/cons + StringTable Fixes (W7, phase 1)

> **STATUS: IMPLEMENTED + MEASURED (Jul 8, 2026).** R1+C1+C2 landed but alone
> did not reduce widens (the dominant seed was non-ASCII-file name slices, not
> the constructors — see the Addendum). With H1–H3 chain healing added:
> **widen calls 1,703,983 → 931 (−99.95%); the 51.2M chunk-widen blind spot →
> 0; UTF-16 String allocs 3,745,261 → 640**. Stage 7a ~232 s (−5.6% vs the
> UTF-8-wiring state, −2% vs original baseline), RSS 3.76 GiB, spread 1.4 s.
> Fixed points green; MLIR md5 identical pre/post H1-H3 (11,697,717 B — new
> baseline set by C1/C2). Full log in `frontendstats.txt`. Watch item: one
> full-suite segfault flake (then 5/5 green incl. gdb); and `rc::check`
> failures don't propagate to suite results — grep gates for "Falsifiable".

*(Jul 8, 2026. Follow-up to `design_docs/utf8-widen-attribution.md`: 98.4% of the
1,703,983 counted UTF-8→UTF-16 widens are mixed-encoding `++`, plus a 51.2M-event
chunk-widen blind spot — all traced to a handful of UTF-16 "seed" constructors that
poison otherwise-UTF-8 append/concat/join chains.)*

## Changes

**R1 — runtime: the three seed constructors emit UTF-8 for ASCII content.**
All gated on `utf8_strings_enabled`; non-ASCII keeps today's UTF-16 path.

1. `StringOps::fromChar` (`StringOps.hpp:1208`): `c < 0x80` → 1-byte
   `makeUtf8LeafFromBytes`. (Also upgrades `toList`'s per-char strings and
   `split ""`.)
2. `StringOps::cons` (`StringOps.hpp:1219`): `c < 0x80 && isUtf8(str)` →
   `AsciiOut(len+1)`: write `c`, memcpy `utf8Bytes` (wrap/guard/re-resolve
   pattern). `!str` already routes through `fromChar`.
3. `Kernel::String::fromList` (`core/String.cpp:46`): pass 1 (count walk, no
   alloc) additionally or-accumulates `acc |= charVal`; all-ASCII →
   `AsciiOut(count)` byte writes in pass 2, else the existing `BlankString`
   u16 writes. Same rooting discipline (list rooted across the one alloc,
   pass-2 walk allocation-free).

**C1 — compiler: guard `unescapeString`**
(`compiler/src/Mlir/Bytecode/StringTable.elm:276`): return `s` unchanged when
`not (String.contains "\\" s)` — skips the `toList`/`fromList` rebuild (and its
UTF-16-ification of the whole string table) for the escape-free majority.
Content is identical either way (the loop is an identity copy without `\\`).

**C2 — compiler: `stringByteLength` → `BE.getStringWidth`**
(`StringTable.elm:389`): widths now come from the same kernel family as
`BE.string`, so length-varint/data agreement is definitional per platform
(native O(1) for UTF-8 forms; JS unchanged O(n)). Also fixes the latent lone-
surrogate mismatch (hand-rolled loop counts a lone half as 2; `BE.string`
writes 3 WTF-8 bytes) — unobservable in practice since no compiler-source
literal carries a lone surrogate (the old accounting would already have
corrupted the section).

## Validation gates (in order)

1. C++ unit: new representation assertions — `fromChar('a')` →
   `Tag_StringUtf8Leaf` / `fromChar(é)` → `Tag_String`; `cons` ASCII+UTF-8 →
   UTF-8; `fromList` all-ASCII → UTF-8, with-é → UTF-16; existing
   differential + K8b goldens green.
2. `cmake --build build --target full` — compiler `.elm` changed ⇒ full, never
   check (stale-`.mlir` rule). Test-program MLIR should be byte-identical
   (C1/C2 preserve emitted bytes; R1 is representation-only).
3. Full bootstrap: **the compiler's own MLIR will change** (its source changed
   with C1/C2), so byte-identity with the old 11,698,078 B baseline no longer
   applies; the gates are the Stage 4b JS + Stage 8c native **fixed points**
   and the new self-compile MLIR being identical across stages 5/7a/8a.
4. Instrumented widen re-measure (relinked `eco`, cold eco-stuff): expect the
   mixed-append row (1,676,359) and split-mixed row (27,601) to collapse to
   near zero, and the 51.2M segment-chunk blind spot to drop by an order of
   magnitude (mixed concat/join lists become all-UTF-8 → W4 byte arms).
5. Stage 7a timing per `frontendstats.txt` protocol (4 samples, discard
   first); record a RUN LOG entry with the widen table before/after.

## Addendum (post-measurement pivot): H1–H3 chain healing

The instrumented re-measure after R1+C1+C2 showed **no significant reduction**
(1,702,709 vs 1,703,983 counted widens; segment-chunk unchanged at 51.2M): the
constructor seeds were real but not dominant. The dominant seed is **names
sliced from the 74 non-ASCII source modules** — the whole-file ASCII gate makes
those files UTF-16, so every identifier sliced from them is UTF-16-backed and
reseeds each mangling/append chain (one seed poisons a whole chain; the tiny
UTF-8 fragments appended to it are what the 1.68M @ 2.7-unit events are).
Runtime-only fixes:

- **H1** `slice()` tiny path (`tinyFromU16`): UTF-16 tiny slices (≤ 512 units,
  where names are materialized — the path copied already) narrow to a UTF-8
  leaf when the range is all-ASCII. Kills the name seed at origin.
- **H2** `append` mixed flatten: or-accumulate the (already-materialized)
  result; all-ASCII → `AsciiOut`. Stops chain self-propagation.
- **H3** `concat`/`join` mixed flatten: `healAsciiResult` — scan the fresh
  UTF-16 leaf; all-ASCII → convert to UTF-8 (leaf rooted across the alloc).

## Risks

- `fromList` or-accumulate misreading char kind → wrong bytes: reuse the
  existing `tupleFieldKind`-based read in both passes (factored helper).
- C1/C2 change compiler behavior → fixed point is the arbiter; both are
  content-preserving by argument above.
- HEAP_032 site list gains fromChar/cons/fromList — update invariants.csv.
