# UTF-8→UTF-16 Widen Attribution: Where the 1.7M Events Come From, and How to Eliminate Them

*(Jul 8, 2026. Follow-up to `plans/utf8-string-pipeline-wiring.md` (W0–W5, landed). Method:
per-site attribution counters added to the GC-stats widen counter (GCStats.hpp
`Utf8WidenSite`, 12 tagged call sites), `eco` relinked, one instrumented Stage-7a-protocol
self-compile (cold eco-stuff; output byte-identical 11,698,078 B). Plus two code audits:
compiler-side Char/widen-op usage across `compiler/src`, and the MLIR bytecode string path.)*

## 1. The measured attribution (exact, zero residual)

The per-site sums reproduce the central counter exactly (1,676,359 + 27,601 + 11 + 12 =
1,703,983 calls; units likewise) — the attribution is **complete**:

| Site | Calls | % | Units | Avg units |
|---|---:|---:|---:|---:|
| **`(++)` append, mixed encodings** | **1,676,359** | **98.4%** | 4,587,271 | 2.7 |
| `String.split`, mixed encodings | 27,601 | 1.6% | 27,601 | 1.0 |
| `trim`/`trimLeft`/`trimRight` | 11 | ~0 | 1,387 | — |
| `String.indexes` | 12 | ~0 | 103 | — |
| `String.toList` | 0 | 0 | 0 | — |
| `ensureFlat` backstop | 0 | 0 | 0 | — |
| `fromBase64`/`fromHex` | 0 | 0 | 0 | — |
| **[blind spot] segment-chunk widen** | **51,239,725** | *(not in the 1.7M)* | **134,016,369** | 2.6 |
| [blind spot] rope-child widen | 0 | — | 0 | — |

Two headline surprises:

1. **It is almost entirely mixed-encoding `++`.** The W4-deferred ops I had blamed —
   C-fn `map`, `indexes`, the `trim` scan — measure at effectively **zero** on this
   workload. (`toList` is 0 because core defines `String.toList = foldr (::) []`, which
   rides the widen-free byte-snapshot foldr.)
2. **The counted 1.7M is the tip of an iceberg.** The `forEachSegment` chunk-widen blind
   spot (UTF-8 segments widened through the 512-unit stack buffer inside mixed
   `concat`/`join` flattens, `copyInto` walks, etc.) fires **51.2M times / 134M units** —
   30× the counted events. Total real widen work ≈ **53M events / 138.6M units** per
   self-compile.

## 2. Root cause: a few UTF-16 *seeds* poison whole assembly chains

The 2.7-unit average is the fingerprint: the widened side of a mixed `++` is almost always
a **tiny ASCII literal** (`"s:"`, `"."`, `"$"`, `","`) — UTF-8 interned — being appended to
a string that is *already UTF-16*. One UTF-16 operand anywhere in an append/concat/join
chain forces every UTF-8 fragment it meets to widen, and produces a UTF-16 result that
poisons the next append. The seeds that make strings UTF-16 in the first place are few:

| Seed | Where | Why UTF-16 |
|---|---|---|
| `String.fromChar` | `StringOps.hpp:1208` — `allocString(buf, 1)` | always allocates a UTF-16 leaf, even for ASCII chars |
| `String.fromList` | `core/String.cpp:46` | builds `u16` from a Char list, always UTF-16 |
| `String.cons` | `String.cpp:38` / `StringOps.hpp:1219` | snapshots to u16, always UTF-16 |
| `unescapeString` | `compiler/src/Mlir/Bytecode/StringTable.elm:276-321` | **unconditionally** `toList`s + `fromList`-rebuilds *every* string in the bytecode string table — converting the entire string section to UTF-16 before encoding |
| escape-bearing literals | `Compiler/Elm/String.elm:64-103` `writeChunks`/`writeCode` | `mba ++ "\\" ++ String.fromChar w` flips the accumulator to UTF-16 |
| flex-var names | `Compiler/Data/Name.elm:266-295` `fromTypeVariableScheme` | seeds `"a"…"z"` via `fromChar`; persists into annotations → typed artifacts → every later name append |
| `sepBy '.'`/`'_'` | `Name.elm:357-359` | `String.join (String.fromChar sep)` — a 1-unit UTF-16 separator makes both operands widen (this is the entire split/join-mixed 27,601 row: avg 1.0 unit = the separator) |

Compiler-side string assembly (mono-specialization symbol mangling, attr/type dedup keys
`"s:" ++ …` / `join ","` in `Mlir/Bytecode/AttrType.elm:113-208`, bytecode emission) then
amplifies each seed: the 51M chunk widens are the mixed `concat`/`join` flatten walks over
lists that are 90% tiny UTF-8 fragments + at least one UTF-16 element.

## 3. Answers to the specific questions

**Debug/error rendering** — confirmed negligible on this workload (user deprioritized;
measurement agrees: the trim/indexes rows are cold Format/Reporting paths, ~23 calls total).

**MLIR text emission** — not on the path at all: `eco make` emits **bytecode**
(`Terminal/Make.elm:335-359`; `Mlir/Pretty.elm` only under `--text-mlir`).

**"Might the MLIR binary format have UTF-16 attrs? Can they be UTF-8?"** — **They already
are UTF-8, end to end; the format needs no change.** Audited: the string section writes
`BE.string s ++ 0x00` (UTF-8 by construction; `StringTable.elm:262`); StringAttr /
SymbolRef / op names / locations are all varint *indices* into that section
(`AttrType.elm:833-967`, `DialectSection.elm:266-300`); zero `unsignedInt16` writes exist
anywhere under `Mlir/Bytecode/`. On the C++ side MLIR's `StringAttr` is raw bytes, read
verbatim by the bytecode reader; the only UTF-16 appears *after* parsing when non-ASCII
literals lower to `[N x i16]` globals (`EcoToLLVMTypes.cpp:183-199`) — backend-compile-time
`std::vector<uint16_t>`, never an Elm heap string, invisible to (and irrelevant for) the
runtime widen counter. The *ironic* finding: the bytecode path's one real problem is that
`unescapeString` converts the whole UTF-8 string table to UTF-16 heap strings *before*
handing them to the UTF-8 encoder.

**"The ops C-fn map, indexes, trim scan?"** — measured 0 / 12 / 11 calls. **Not worth
converting for this workload.** (They remain candidates only if some other program profile
shows them hot.)

**"Can we avoid dropping to Char at all?"** — Mostly we don't need to *remove* Char-level
code; we need Char-*producing constructors to stop yielding UTF-16*. `String.foldl/uncons/
all/any` Char callbacks are already widen-free (byte-snapshot paths); the damage comes only
from `fromChar`/`fromList`/`cons` **outputs**. Fixing those three constructors makes most
existing Char-level code representation-harmless. Where Char code is also a CPU cost
(unescapeString, `fromTypeVariable`'s whole-string `toList` to inspect the last char), the
audit found trivial whole-string replacements (below).

## 4. Recommended fixes, ranked by measured impact

**R1 — runtime (small, no compiler changes): make the three seed constructors emit UTF-8
for ASCII content.**
- `fromChar(c)`: `c < 0x80` → 1-byte `Tag_StringUtf8Leaf` (respect `utf8_strings_enabled`).
- `fromList(chars)`: or-accumulate (`acc |= c`) while building; all-ASCII → `AsciiOut`.
- `cons(c, s)`: `c < 0x80 && isUtf8(s)` → byte-concat via `AsciiOut`.
This single change removes the seeds *globally*: mixed appends become both-UTF-8 (W4
byte-concat arm), mixed concats/joins become all-UTF-8 (W4 byte arms), and both the
counted 1.68M appends and the bulk of the 51M chunk widens collapse. Expected to eliminate
**>95% of all widen work**. Differential/E2E suites already cover these ops across
representations; add representation assertions for the three constructors.

**C1 — compiler (1 line): guard `unescapeString`** (`StringTable.elm`): skip the
`toList`/`fromList` round-trip when `not (String.contains "\\" s)` (contains is
widen-free). Even with R1, this avoids a pointless per-char rebuild + copy of every string
in the table and keeps zero-copy views alive into `BE.string`'s memcpy path.

**C2 — compiler (1 line): `stringByteLength` → `BE.getStringWidth`**
(`StringTable.elm:389-413`): O(1) for UTF-8 forms vs O(n) Char fold; agrees with
`BE.string` *by construction* on both native and JS (it is what BE.string uses to size its
buffer), and fixes a latent lone-surrogate mismatch (hand-rolled loop counts a lone half
as 2; native `BE.string` writes 3 WTF-8 bytes).

**C3 — compiler (trivial, opportunistic):** `fromTypeVariableScheme` → 26 literal cases
(`Name.elm:266-295`); `writeChunks` escape arms → literal table (`Elm/String.elm:64-103`);
`sepBy` → String separators (`Name.elm:357-359`); `fromTypeVariable` last-char test →
`String.right 1` + `String.all Char.isDigit` (`Name.elm:238-256`); `fpSplitExtension`/
`fpSplitFileName` → split-based (`Utils/Main.elm:688/803`). With R1 in place these are
CPU/allocation wins more than widen wins.

**Not recommended (measured ~0):** runtime UTF-8 arms for `trim` scan, `indexes`, C-fn
`map`, `toList`.

## 5. Residual UTF-16 that is *by design*

After R1+C1: strings containing real non-ASCII (the 74 non-ASCII compiler modules'
literals, `\u{…}` escapes above 0x7F, lone surrogates) stay UTF-16 — that is the HEAP_032
ASCII gate working as intended. The remaining widens should be a small constant, and the
`utf8_widen_*` counters (now with per-site attribution, kept behind `ENABLE_GC_STATS`)
will show any regression at a glance in the self-compile stats banner.
