# Mono comparable-key optimization (compiler-source refactor)

**Status: K1 + K2 + K4 SHIPPED. K3 = NO-GO (premise refuted by measurement).**

- **K1 + K2** (2026-08-04, `benchmarks/tier2-opt.md` Run B): −1.2% wall,
  −2,706 MiB allocation, output byte-identical. §9.
- **K3**: NO-GO. Construction is ~2× ALL comparison in the compiler, and a
  hash prefix would reorder keys and forfeit byte-identity anyway. §10.
- **K4** (2026-08-05, Run C): built by explicit decision AFTER §10 deferred
  it, accepting the loss of byte-identity. Implemented as hash-consing-lite.
  Verified by elm-tests + E2E 1619/1619 + bootstrap (BOTH fixed points).
  **Result: wall −0.35% (≈flat), true allocation −1.31%** — the §10 ceiling
  estimate was accurate. §11.

**Originally NEW 2026-08-04 — extracted from `plans/opt-tier2-cons-fusion.md`
U-T2.2′, which has been reduced to generated-code optimizations only.**

> **CATEGORY A — this plan changes the eco compiler's own Elm source. It does
> NOT add or change a compiler pass, so it makes *no user program faster*.
> Its entire payoff is self-compile wall and compiler heap traffic (series
> axes 1–2).** Anything in here that would generalize to arbitrary compiled
> code belongs in `opt-tier2-cons-fusion.md` instead — see §8.

**Relation to the opt-tier series:** not a tier. `plans/opt-tier{1..4}-*.md`
rank *generated-code* transforms; this is a hand optimization of one hot
subsystem in the compiler, sequenced independently and cheap enough not to
compete with them.

---

## 0. Why this was split out

The `ECO_CONS_SITES` census that ranks the opt-tier residuals measures **the
compiler compiling itself**. That workload plays two roles simultaneously —
it is the product (compiler speed) *and* the benchmark corpus (a stand-in for
"a real Elm program"). A hot site in that census is therefore ambiguous: it
may indicate that eco *generates* poor code for a pattern (generalizable, a
pass), or that one function in the compiler's source is written badly
(not generalizable, an edit).

`toComparableMonoTypeHelper` is unambiguously the second kind. The cost is
driven by an architectural choice in `Data.Map`/`Data.Set` (§1), which no
codegen pass can see or fix. Keeping it filed under a generated-code tier
invited exactly the confusion that produced this split.

The same caution the tier-2 plan already applies to fusion — *"activated
per-workload, never by self-compile evidence"* — applies to reading the cons
census at all.

## 1. The mechanism (this is the whole problem)

This compiler's dictionaries take the key-derivation function as an
**argument applied on every operation**, rather than storing a precomputed
key. `compiler/src/Data/Map.elm:110`:

```elm
get : (k -> comparable) -> k -> Dict comparable k v -> Maybe v
get toComparable targetKey (D dict) =
    Dict.get (toComparable targetKey) dict |> Maybe.map Tuple.second
```

`insert` (`Data/Map.elm:151`) and `Data/Set.elm:68,82` are the same shape.
Consequently **every `get`/`member`/`insert` on a `MonoType`-keyed structure
re-walks the entire type tree and rebuilds the entire key string from
scratch.** Lookups that read as `O(log n)` are really `O(log n · |type|)`
with a full allocation storm attached, and the resulting `String` is then
compared character-wise at every node of the `Dict` walk.

There are **41 call sites** outside the defining module (22
`toComparableMonoType`, 19 `toComparableLayoutKey`), concentrated in
`Monomorphize/Specialize.elm` (7), `Generate/MLIR/Context.elm` (6),
`MonoSolver/Engine.elm` (4), `Monomorphize/Analysis.elm` (4),
`Generate/MLIR/Patterns.elm` (4).

## 2. What one call allocates

`toComparableMonoTypeHelper` (`compiler/src/Compiler/AST/Monomorphized.elm:1284`)
is an explicit-work-stack traversal with two `List` parameters:

```elm
toComparableMonoTypeHelper : Bool -> List WorkItem -> List String -> List String
```

For a type of N nodes producing F fragments, one call allocates:

| pool | count | source |
|---|---|---|
| `WorkItem` Custom objects | ~N + markers | every `WorkType t` / `WorkMarker ")"` is a boxed ctor |
| cons cells (work stack) | ~N + markers | each push is `:: rest` |
| cons cells (`acc`) | ~F | each fragment is `"I" :: acc` |
| cons cells (`List.reverse`) | ~F | both entry points reverse before `String.concat` |
| `String` | 1 + concat temporaries | the key itself |

F is larger than it looks: `MCustom` alone pushes **eight** fragments per
node (`"(" :: name :: NUL :: modName :: NUL :: project :: NUL :: author ::
"X"`, line ~1367), so a single `MCustom` costs ~16 cons cells in `acc` +
reverse before counting its work-stack entries.

## 3. Sizing (and the honest bracket)

From the chunks-ON `ECO_CONS_SITES` census (opt-tier2 §1): the
`toComparableMonoTypeHelper` loop is **≈164.6M cons, 40% of symbolized
residual Cons**, plus a matching Custom pool from the `WorkItem` wrappers.

Against the 6.21B-object total that is **≈2.7% of objects** for the cons
pool; combined with its Custom shadow, plausibly **≈4–5% of allocation**.
Real, but not transformative — and this codebase has repeatedly measured
allocation reduction as *not* proportional to wall (see the tier-1 analysis-
toll note and the borrow perf-tune-loop record).

**The stronger argument is second-order and invisible to the object census:**
interning also removes the *string comparisons* inside every `MonoType`-keyed
dictionary walk. Historical support: `plans/hash-prefix-comparable-keys.md`
measured `Dict.get` on the monomorphization registry at **14.8% of Stage-5 JS
execution time**. That figure is old and JS-hosted — treat it as direction,
not magnitude, and re-measure natively before quoting it in a decision.

## 4. Prior art (checked 2026-08-04)

| plan | status | interaction |
|---|---|---|
| `specid-worklist-and-list-string-keys.md` | **LANDED** (`scheduled : BitSet` at `Monomorphize/State.elm:165`) | already removed ~70% redundant worklist re-encounters; the residual key traffic measured here is *post* that win |
| `hash-prefix-comparable-keys.md` | **NOT landed** (no hash in the helper) and **stale** — its stated signature predates the LSS `annoSensitive : Bool` parameter and the `WorkItem` rename | absorbed as **K3** below; do not implement it standalone |
| `eliminate-unnecessary-data-map-dict.md` | separate | **complementary, not overlapping** — it targets `identity`-comparator `Data.Map` uses; this plan targets the genuinely non-identity `MonoType`-keyed ones it explicitly classifies as "YES needs Data.Map" |

## 5. Units

Staged cheapest-first. Each stage is independently shippable and independently
gated; stop whenever the measured return stops justifying the next stage's
risk.

### K1 — call-site amplifiers (do first: hours, no key change, no risk)

Two patterns rebuild keys far more often than the algorithm requires.

**K1.1 — quadratic key rebuilding.** `Generate/MLIR/Context.elm:460`:

```elm
else if List.any (\t -> Mono.toComparableLayoutKey t == currentKey) toRegister then
```

Every worklist step rebuilds a full key for *every* element already in
`toRegister`, then string-compares. As `toRegister` grows this is O(n²) full
key constructions, inside type-registry population that runs over every type
in the program. **Fix:** carry `( key, type )` pairs through `processWorklist`
so each item is keyed once; better, keep a `Set String` of accumulated keys
and make the membership test O(log n) with zero rebuilds.

**K1.2 — probe-then-insert double keying.** `Monomorphize/Analysis.elm:68-74`:

```elm
if EverySet.member Mono.toComparableLayoutKey monoType acc then
    acc
else
    List.foldl collectCustomTypesFromMonoType
        (EverySet.insert Mono.toComparableLayoutKey monoType acc)
        args
```

The existing comment claims this "avoids redundant `toComparableLayoutKey`
calls" — it avoids the *recursion*, but member-then-insert still builds the
identical key twice, per node of every type traversed. **Fix:** hoist the key
into a `let` and use a key-taking insert.

**K1.3 — sweep the remaining 39 sites** for the same two shapes before
concluding K1. `Generate/MLIR/Context.elm:373-384` (`customKey` computed then
compared against a freshly-rebuilt key per field) is a third instance.

Neither fix changes any emitted key, so both are gated solely by byte-identity.

### K2 — helper mechanics (contained to one function)

**K2.1 — delete the `WorkItem` Custom pool.** Convert the explicit work stack
to direct structural recursion that appends into the accumulator. The stack
exists to keep the function tail-recursive, but recursion depth here is *type
nesting depth* — small and bounded — not breadth: records, tuples, custom
args and function args all `List.foldl` over their children rather than
nesting. **Verify before relying on this:** the JS-hosted bootstrap
(`eco-boot.js` under node) has a stack limit the native build does not; if a
pathological nesting depth exists in the corpus this reverts to K2.2 alone.

**K2.2 — delete the `List.reverse`.** Both entry points
(`toComparableMonoType`, `toComparableLayoutKey`) reverse F cons cells before
`String.concat`. Build fragments forward instead, or emit directly into a
rope/builder.

Both must keep the emitted key **byte-identical** (§6).

### K3 — hash-prefix discriminant (absorbed from the old plan; decide, don't assume)

Accumulate a cheap multiplicative hash during the existing traversal and
prepend it as the first fragment, so `Dict` comparisons resolve on element 0
instead of walking a long shared prefix (`["G", "elm", "core", "Dict", "get",
NUL, …]`). Collisions are harmless — it is a comparison fast path, not a hash
table.

**Two corrections to the old plan before it is implementable:**
1. Its signature is stale: the helper now takes `annoSensitive : Bool` first
   and the work type is `WorkItem`, not `Work`.
2. It is **partially redundant with K4.** If interning lands, keys stop being
   rebuilt at all and the prefix buys only comparison speed on the surviving
   lookups. Implement K3 only if K4 is declined, or if K1+K2 measurement shows
   comparison (not construction) dominates.

**Decision point:** measure after K2. Do not implement K3 and K4 both without
re-measuring in between.

### K4 — intern / hash-cons `MonoType` (the real win, and the real risk)

Give structurally identical `MonoType`s a shared node carrying an interned
`Int` id. Keys become that id; the string is built at most once per *distinct*
type instead of once per *lookup*. This collapses both allocation pools and
deletes the string comparisons inside every keyed `Dict` walk.

Three obstacles, in ascending order of nastiness:

1. **Chicken-and-egg.** Interning needs a lookup key — the thing being
   avoided. Standard escape: smart constructors keyed on `(tag, child-ids)`,
   cheap because children are already interned. That means routing
   construction through smart constructors across **356 `MList`/`MTuple`/
   `MCustom`/`MFunction` construction sites**, concentrated in
   `Monomorphize/TypeSubst.elm` (64), `MonoSolver/Translate.elm` (60),
   `Monomorphize/Specialize.elm` (51).
2. **State threading in pure Elm.** The intern table must live somewhere; the
   monomorphizer already threads state, so this is plumbing — through exactly
   the modules that construct types most.
3. **Iteration-order hazard (the sharp edge).** Switching a `Dict` from a
   `String` key to an `Int` key changes fold order from lexicographic to
   id-assignment order. Anywhere compiler *output* depends on map traversal
   order — MLIR emission, type-registry numbering, spec naming
   (`defName$v<idx>`, `MonoSolver/Engine.elm:1017`) — generated code changes
   with nothing semantically wrong. The byte-identity gate catches it loudly,
   but expect either deliberate order preservation or a re-baseline.

**Lower-risk variant, prefer this first:** keep `String` as the key *type* and
use the interned id only to **memoize the string**. Same allocation win, zero
ordering change. Only go to Int keys if the comparison cost measured in §3
justifies it on its own.

**Flavour hazard (applies to any memo):** there are two key functions sharing
this helper — `toComparableMonoType` (`annoSensitive = True`, specialization
intent) and `toComparableLayoutKey` (`False`, layout intent, lines
~1248-1266). A memo table must be keyed **per flavour** or specialization keys
silently merge with layout keys — precisely the class of bug the M4 `==` audit
exists to prevent (see the `toComparableLayoutKey` docstring).

## 6. Correctness gates

The emitted keys are load-bearing for specialization identity, so the gate is
strong and cheap:

- **Byte-identical self-compile** is the primary gate for K1, K2 and the
  memoizing variant of K4 — none of them may change a single key. Full
  bootstrap to fixed point.
- **Both flavours** must be exercised: flag-off graphs are all-`LTop`, where
  `toComparableMonoType` and `toComparableLayoutKey` produce byte-identical
  strings — so an `annoSensitive` regression is **invisible flag-off**. Gate
  LSS flag-on too.
- Invariants to re-read before touching keys: `MONO_003` (CEcoValue layout
  erasure / canonical placeholder id), the D4 quiescence-before-defaulting
  reasoning inline at the `CNumber` arm (open number keys as `"I"`), and
  `MONO_005/017/020/021/022/024` per the prior key plans.
- `cmake --build build --target elm-tests`, then full E2E **once**, teed to a
  file, grepped (never re-run).
- K4 only: explicit diff of emitted MLIR, not just exit status — the ordering
  hazard is silent otherwise.

## 7. Risks

- **Ordering (K4)** — see §5 K4.3. The single largest reason to prefer the
  memoizing variant.
- **Flavour merge (K4)** — see §5 K4 flavour hazard; invisible flag-off.
- **Stack depth (K2.1)** — direct recursion vs the JS-hosted bootstrap;
  verify before relying on it.
- **E2E/elm-tests cache race** — run serially; `--target full` deletes
  `bin/eco-compiler` (rebuild via `--target eco-compiler` for census runs).
- **Measurement discipline** — census and wall against the **chunks-ON**
  baseline (default since Aug 3); walls always recorded with their major-GC
  counts (GC-trigger lottery).

## 8. Explicitly out of scope (belongs in opt-tier2)

Two *generalizable* patterns surfaced while investigating this site. They are
category B — they would apply to any program eco compiles — and are recorded
in `opt-tier2-cons-fusion.md` §5, not here:

- **CSE over pure calls.** The K1.2 probe-then-insert shape is idiomatic Elm,
  and Elm's purity makes CSE unconditionally sound. There is currently no
  Elm-level CSE pass in `GlobalOpt/`.
- **Sum-type wrapper unboxing.** The K2.1 `WorkItem` pool is the generic cost
  of the explicit-work-stack idiom, which Elm programs write constantly as the
  standard workaround for deep recursion.

If either pass ships, the corresponding hand-fix here becomes redundant —
which is an argument for doing K1/K2 as *measurement* of what those passes
would be worth, not as a substitute for them.

---

## 9. As-built (K1 + K2, shipped 2026-08-04)

### K1 — call-site amplifiers

**K1.1 — quadratic key rebuilding (`Generate/MLIR/Context.elm`).**
`processWorklist` now carries `( key, type )` pairs plus a `Set String` of the
keys already queued. Three rebuild sources died at once: the
`List.any (\t -> toComparableLayoutKey t == currentKey) toRegister` membership
test (a full key per element, per step, over a list that grows with the
program's whole type set) became `Set.member`; `registerSingleType` takes the
key it was queued under instead of re-deriving it; `getNestedTypes` takes it as
a parameter for the `MCustom` ctor-shape lookup. Added a fast path:
`getOrCreateTypeIdForMonoType` keys the requested type once and returns
immediately when it is already registered — previously the worklist ran, popped
it, found it in `typeIds` and returned an unchanged context. Registration order
(hence type-id assignment, hence emitted MLIR) is unchanged by construction.

**K1.2 — probe-then-insert (`Monomorphize/Analysis.elm`).**
`collectCustomTypesFromMonoType` hoists the key into a `let` and uses new
key-taking `Data.Set.memberKeyed` / `insertKeyed` (backed by
`Data.Map.memberKeyed` / `insertKeyed`) — one key per `MCustom` node, not two.

**K1.3 — the sweep found no further amplifiers.** Every remaining site builds
one key per operation. Two findings worth keeping:

- `Generate/MLIR/Patterns.elm:1189-1193` and the `getNestedTypes`
  self-reference filter compare *many* types against one key, and look like
  candidates for the allocation-free `Mono.eqLayout`. **They are not.**
  `eqLayout` is STRICTER than layout-key equality: its `_ -> a == b` fallback
  distinguishes `MVar` ids that the key erases (MONO_003) and separates
  `MVar _ CNumber` from `MInt`, which the key deliberately merges (D4).
  Substituting it silently changes which types count as identical.
- Everything else is a single `Dict.get (key x) d`. Only interning (K4)
  removes those.

### K2 — helper mechanics (K2.1 and K2.2 landed together)

`toComparableMonoTypeHelper` (explicit `WorkItem` stack, fragments accumulated
in reverse, `List.reverse` before `String.concat`) is replaced by
`toComparableFragments : Bool -> MonoType -> List String -> List String`, which
emits fragments in forward order onto a tail, plus a tail-recursive
`toComparableFragmentsRev` for children. Deleted per call: the `WorkItem`
wrappers, the work-stack cons cells, the `List.reverse` copy, and (not in the
plan) the `Dict.toList` pair list in the `MRecord` arm, which `Dict.foldl`
replaces. What remains is the fragment cons cells and the result string.

**Order preservation is the whole correctness story.** The old stack was built
with `List.foldl (::)`, so it popped children LAST-TO-FIRST, and each `acc`
push listed its own fragments reversed. The new arms emit children
last-to-first explicitly and their own fragments forward. `MRecord` relies on
`Dict.foldl` (ascending) prepending, which lands fields in the same descending
order the stack produced.

**Stack depth** is now type NESTING depth; breadth is tail-recursive. The §5
K2.1 concern (JS stack limit) is discharged by the bootstrap itself: stages 2,
3 and 4a run the compiler under node, and Stage 4b's byte-exact JS fixed point
(`eco-boot-2.js == eco-boot-3.js`) passed.

### Gate

New `compiler/tests/TestLogic/Monomorphize/ComparableKeyEncodingTest.elm` keeps
the previous work-stack encoder verbatim as `referenceKey` and asserts
byte-identical keys over a 428-type corpus (22 goldens + 7 deep handwritten
shapes + 400 deterministic pseudo-random trees) in BOTH flavours, plus literal
golden strings, a lambda-set flavour-separation test, and an arm-coverage guard
so the differential cannot pass vacuously. 6/6 pass.

Gate results: Stage-4b JS fixed point PASS; **old-binary output ≡ new-binary
output byte-identical on the same source, ×3** (two wall pairs + the census
pair); `elm-tests` 13,052 pass with only the 12 known pre-existing typechecker
failures; **full E2E 1619/1619 PASSED**.

### Measured (benchmarks/tier2-opt.md Run B)

Same-source interleaved pairs, cold cache, equal majors (11=11) throughout:

| | old binary | new binary | delta |
|---|---|---|---|
| wall, pair 1 | 3:48.46 | 3:45.45 | −3.01 s (−1.3%) |
| wall, pair 2 | 3:47.08 | 3:44.55 | −2.53 s (−1.1%) |
| bytes (census, inline-alloc off) | 156,089.88 MB | 153,383.93 MB | **−2,706 MiB (−1.74%)** |
| objects (census) | 3,899,289,075 | 3,907,988,879 | +8.7M (+0.22%) |

Per-tag: `Custom −61.6M` (the `WorkItem` pool — the §2 prediction, confirmed),
`Tuple2 −10.2M` (`Dict.toList` pairs), `ListBacking −10.1M / −2,973 MiB` and
`ConsChunk −28.1M` (the `List.reverse`), against `Cons +116.7M`.

**The surprise, and it is a general lesson: `List.reverse` is a COMBINATOR, so
under the shipped chunked-list representation it produced chunked backings —
few, large objects (`ListBacking` averages 274.6 B). Forward `::` building
replaces them with many small cells.** Hence bytes fall 1.74% while the object
COUNT rises 0.22%. Any future "remove a `List.reverse`" optimization should
expect the same signature and be judged on bytes, not object count. (The
standard binary's counter is inline-alloc-blind and read +18% objects /
−4.68% bytes for the same change — census legs are mandatory here.)

## 10. Decision on K3 and K4 (measured 2026-08-04)

The §5 decision point said: measure after K2, do not do both without
re-measuring. Measurement (DEV-JS `--cpu-prof` of the whole self-compile,
116.7 s sampled, post-K2):

- **key CONSTRUCTION** (`toComparableMonoType` / `toComparableLayoutKey` /
  `toComparableSpecKey` inclusive, 2,192 call roots): **3.64%** (4.25 s).
- **ALL comparison in the entire compiler** (`_Utils_cmp` self time, every
  `Dict`/`Set` of every key type, not only `MonoType`-keyed ones): **≤1.94%**
  (2.27 s) — an upper bound on what K3 could ever address.

**K3 — NO-GO.** Its premise is that comparison, not construction, dominates.
It does not: construction is ~2× all comparison in the compiler put together,
and the `hash-prefix-comparable-keys.md` figure this plan inherited (`Dict.get`
at 14.8% of Stage-5) does not reproduce — §3 already flagged it as stale and
told us to re-measure before quoting it; now it is measured. K3 also is **not
byte-identity-safe**, which §5 did not say: prefixing a hash changes the
LEXICOGRAPHIC order of every key, and key order drives `Dict` fold order, spec
indices (`defName$v<idx>`) and type-registry numbering — so it changes emitted
MLIR and forfeits the cheap gate, for a lever aimed at ≤1.94%.

**K4 — DEFERRED, with numbers.** Perfect interning caps out at the 3.64%
construction figure (JS-hosted, GC-inflated); natively the encoder is 158.3M
cons of a 3.9B-object, 152.8 GiB-allocation workload (~2.4% of bytes), so with
GC ~29% of native wall the realistic ceiling is **1–2%**. The cost is §5's:
routing ~356 `MList`/`MTuple`/`MCustom`/`MFunction` construction sites through
smart constructors, threading an intern table through the modules that build
types most, and the iteration-order hazard — noting that the "lower-risk
memoizing variant" does NOT avoid the hard part, because a memo still needs a
lookup key, which is the chicken-and-egg interning solves. Per §5's staging
rule ("stop whenever the measured return stops justifying the next stage's
risk"), this stops here.

**Re-open K4 if** a workload appears where key construction is materially
larger than 3.64% (a program with far deeper or wider types than this
compiler), or if `MonoType` gains an id field for unrelated reasons — at which
point interning is nearly free.

**SUPERSEDED 2026-08-05: K4 was built anyway, by explicit decision, accepting
that the byte-identity gate would be lost. See §11 — the deferral reasoning
above was borne out on wall time and refuted on allocation.**

## 11. K4 as built (2026-08-05)

Implemented as **hash-consing-lite**: structural hashes stored IN the type,
hash-keyed dictionaries, and an exact-equality confirm on lookup — not the
global intern table §5 K4 describes. Both give ids-in-the-data and Int-keyed
dictionaries; the difference is that a hash is context-free, so obstacle 2
(threading an intern table through every construction site, in pure Elm)
disappears entirely, at the cost of a confirm walk on each hit. Given that the
measured cost was allocation, not comparison (§10), that trade was the right
shape — and see the verdict below for what it cost us.

### Design

`MonoType`'s five composite constructors carry a leading `Int`:
`layoutHash * 2^26 + specHash`, two 26-bit hashes packed into one field (2^52,
inside the exact-integer range of both the native i64 and the JS-hosted
double). Smart constructors `mList` / `mTuple` / `mRecord` / `mCustom` /
`mFunction` are the only way to build them; each computes the pair in
**O(arity) from the children's already-stored hashes — never a tree walk, and
never a string walk** (only `String.length`, so construction stays cheap;
names are compared by the eq functions on the rare bucket collision).

Two hashes because there are two key FLAVOURS: `specHashOf` mirrors
`toComparableMonoType` (annotation-sensitive), `layoutHashOf` mirrors
`toComparableLayoutKey` (arrows erased). `eqKeySpec` / `eqKeyLayout` are
exactly the two key equalities, allocation-free with early exit.

`Data.HashMap` stores entries in per-hash buckets, so the hash need only
satisfy **equal key ⇒ equal hash**; the eq confirm decides. A degenerate hash
would cost performance, never correctness.

### Scale

641 constructor sites across 39 source and 28 test files (508 patterns widened,
344 constructions routed). Converted to hash keys: the codegen type registry
(`typeIds`), `ctorShapes` (graph-level and per-context, all seven consumers),
`Analysis`'s custom-type set, `Specialize`'s `localMulti`/`valueMulti` instance
maps, and the specialization `Registry` (`SpecKey`, hashing the global's name
characters plus canonical lengths). **Zero `toComparableLayoutKey` call sites
remain**; the survivors are two composite string keys in GlobalOpt
(`CafHoist`, `Staging/Rewriter`) and solver-only paths.

### Verification (byte-identity deliberately given up)

- **Stage A** — field and smart constructors added, dictionaries still
  string-keyed. Semantics unchanged, so byte-identity MUST hold, and it did:
  pre-K4 and Stage-A binaries emitted identical MLIR from the same source.
  That is a complete check on the 641-site mechanical refactor, and staging it
  this way is what kept refactor bugs separable from ordering changes.
- **Stage B** — dictionaries switched to hashes. Output is byte-different by
  design but **the same SIZE** (12,953,038 B both), the signature of a pure
  permutation of spec indices and type ids.
- `ComparableKeyEncodingTest` gained five K4 tests proving the contract over
  ~8,900 type pairs: `eqKeySpec`/`eqKeyLayout` are EXACTLY the two string-key
  equalities, equal keys imply equal hashes, hashes stay in range, and the
  hash recovers ≥90% of the keys' discrimination.
- elm-tests 13,058 pass / 12 known pre-existing failures; E2E 1619/1619;
  bootstrap fixed points.

**One real bug, and it is the lesson of this stage: hash-ordered iteration
broke a multi-specialization emission path** (`eco.papCreate` referencing an
SSA var outside its region, in a `$_1` instance). Emission folds these maps,
so bucket order leaked into generated code. `Data.HashMap` iteration is now
**INSERTION-ordered** — entries carry a sequence number and folds sort on it,
replacement keeping its original position, exactly as `Dict.insert` does. Cost
is a sort on the rare fold, nothing on lookups.

### Measured (benchmarks/tier2-opt.md Run C) — and the verdict

Same-source interleaved against the K1+K2 binary, equal majors (10=10):

| | pre-K4 | K4 | delta |
|---|---|---|---|
| wall | 3:49.17 | 3:49.09 | **flat** |
| minor GC | 894 | 876 | −18 |
| objects promoted | 375,909,857 | 375,940,792 | **identical** |
| GC time | 85.41 s | 85.76 s | flat |
| **census objects** | 4,003,260,018 | 3,933,552,762 | **−66.7M (−1.67%)** |
| **census bytes** | 156,662 MiB | 154,614 MiB | **−2,048 MiB (−1.31%)** |

(census columns are the FINAL state, after the bucket-churn fix below)

**READ THE CENSUS, NOT THE STANDARD COUNTER.** The standard binary reported
objects −13.5% and bytes −21.3%; both are artefacts of the inline-alloc fast
path bypassing the per-tag counter, and this is the SECOND consecutive run it
misread (Run B flipped the sign of the object delta). The census legs above
(`ECO_INLINE_ALLOC=0`, same source, both binaries) are the real numbers.

Per-tag, the mechanism is exactly as designed — and so is its offset:

| tag | pre-K4 | K4 | delta |
|---|---|---|---|
| Cons | 549,056,575 | 405,863,365 | **−143.2M (−26.1%, −3,278 MiB)** |
| StringRope | 9,592,484 | 313,084 | **−9.3M (−96.7%)** |
| StringUtf8Leaf | 57,806,094 | 52,504,057 | −5.3M |
| **Tuple2** | 357,449,843 | 451,263,288 | **+93.8M (+26.2%, +2,148 MiB)** |
| Int | 95,544 | 7,572,907 | +7.5M (boxed hashes) |

The fragment lists and key strings die as intended (Cons −26%, StringRope
−97%), but **`Data.HashMap` gives most of it back in `Tuple2` churn**: bucket
entries, the `( List, Bool )` that `replaceInBucket` returns per recursion
step, and the `( k, v )` pairs `toList` materialises on every fold. That is a
concrete, fixable ~94M-object overhead — see "next lever" below — not an
intrinsic cost of the design.

**So K4 bought no wall time, and the allocation win is ~1%, not the 21% the
naive counter claimed.** The §10 estimate of a 1–2% ceiling was accurate. Two
independent reasons the allocation that IS removed buys nothing, both visible
in the table:

1. **The deleted allocation was short-lived nursery garbage.** Objects PROMOTED
   are identical to within 31K. A copying collector pays for SURVIVORS, not for
   allocation volume — garbage that dies in the nursery is free. This is the
   same lesson the CAF-memoization arc recorded as "retention deltas ≠
   recurring mark/scan costs", and the borrow perf-tune loop as "allocation
   reduction is not proportional to wall".
2. **The CPU saved building strings is spent confirming hits.** Hash-consing-
   lite still walks the tree once per lookup, in `eqKey` instead of in the
   encoder — allocation-free, but not free.

Only TRUE interning (globally unique ids, so equality is id equality and no
confirm walk exists) can convert this into time, and that is precisely the
global-table variant whose state threading K4-as-built was designed to avoid.
On this workload it would be chasing a wall win the profile says is ~3.6% of
JS-hosted time at the absolute maximum.

### Follow-up: the bucket-churn fix (done, and it settled the attribution)

`Data.HashMap.insert` was allocating a `( List, Bool )` per bucket step via
`replaceInBucket`, and `foldl`/`values` went through `toList`, materialising a
`( k, v )` per entry per fold. Fixed: insert now scans with `bucketMember` and
then either replaces in place or prepends (buckets are almost always one
entry, so the extra scan is free); `foldl`, `toList` and `values` share one
`orderedEntries` walk and only `toList` builds pairs, because its result type
demands them.

Worth **−11.2M objects / −286 MiB**, and wall moved from flat to −0.80 s
(−0.35%) on an interleaved pair. **More usefully, it settles the attribution:
removing EVERY bucket-step pair recovered only 5.3M of the +93.8M `Tuple2`, so
bucket churn was never the bulk of that pool.** The rest is unattributed —
ruled out so far: `List.sortBy` (native, extracts an i64 key, does not
decorate), bucket entries (`Tuple3` barely moved, so inserts are only
millions), and `Dict.get`'s `Maybe` (`Custom` moved +505K). Whatever it is, it
is not in `Data.HashMap`, and the per-tag census has no per-SITE attribution to
chase it with.

**What K4 IS worth keeping for:** a compiler that no longer builds a comparable
string per dictionary probe (`Cons −26%`, `StringRope −97%`), −96 MB RSS, and
headroom for workloads whose types are deeper or wider than this compiler's.
**What it is not:** a self-compile speedup, and not the 21% allocation cut the
standard counter advertised.

---

## 12. K5 — TRUE interning (built, measured, REVERTED 2026-08-05)

§11 shipped hash-consing-*lite*: hashes in the type, buckets, and a confirm
walk per hit. K5 removed the confirm walk the way §5 K4 originally specified —
a global table handing out **globally unique ids**, so equality is id equality.
Built and benchmarked on explicit instruction, accepting the cost.

**What was built.** A second `Int` field on the five composite constructors
holding packed `layoutId * hashBase + specId` (0 = uninterned, 522 pattern
sites widened); `Compiler.AST.Intern` (one bucketed table per flavour, ids
from 1); `internTypeDeep`, which interns a type and all its subterms
bottom-up; `MonoTraverse.mapNodeTypesS`, the state-threaded twin of
`mapNodeTypes` (the pure one cannot thread a growing table); and id fast paths
in `eqKeySpec`/`eqKeyLayout` that fall back to the structural walk whenever
either side is uninterned, so partial coverage is always CORRECT.

**Where it ran.** `Prune.pruneUnreachableSpecs` — the single point BOTH engines
funnel through (subst via `Monomorphize`, solver via
`MonoSolver.Monomorphize`), so nodes, registry `reverseMapping` and
`ctorShapes` were all interned before GlobalOpt and codegen. Gate: a new K5
test proves independently-built equal types receive identical ids, every
composite gets one, and id equality is still exactly key equality. elm-tests
13,059 pass / 12 known.

**Measured — an 18% REGRESSION** (subst, same source, equal majors, identical
output size 12,978,169 B):

| | K4+fix | K5 | delta |
|---|---|---|---|
| wall | 3:56.35 | 4:39.50 | **+43.2 s (+18.3%)** |
| objects | 394,281,186 | 616,215,747 | **+221.9M (+56%)** |
| bytes | 18,688.90 MB | 23,860.96 MB | +5,172 MB |

**Why, and this is the durable result: ids retrofitted onto an already-built
graph cost a REBUILD of every type in it.** An Elm value cannot be updated in
place, so `internTypeDeep` allocates a fresh node for every subterm of every
type, and `mapNodeTypesS` rebuilds the graph around them. +221.9M objects to
delete confirm walks that the §10 profile capped at ≤1.94% of runtime *in
total*. The arithmetic never had a chance.

**Therefore: interning must happen at CONSTRUCTION or not at all** — types must
be born with ids, which is exactly what §5 K4's "state threading in pure Elm"
obstacle described. Measured cost of doing it properly, both engines:
`applySubstFV` (57 refs), `applySubstPure` (46), `applySubst` (31),
`unifyHelp` (31) and their kin all return BARE types from pure expression
contexts, so each must become state-returning and every caller must thread —
a multi-day refactor of the substitution/unification/translation cores. The
solver's `Step` monad (`S -> Result Failure ( a, S )`) would carry the table
for free at the function level, but its 94 construction sites still sit inside
pure expressions that would need monadic restructuring.

**REVERTED** to the §11 state (the verified one: elm-tests 13,058/12 known,
E2E 1619/1619, bootstrap both fixed points). K5's code is not in the tree.

**If anyone revisits post-hoc interning** — and the measurement says don't —
the one idea not yet tried is making `internType` return the table's CANONICAL
representative instead of the freshly rebuilt copy, and probing BEFORE
rebuilding. Recurring structures would then cost a walk instead of a rebuild,
and the graph would gain structure sharing. It would have to overcome a 43-second
deficit to break even.

## 13. Duplicate-construction census (2026-08-05) — the number that decides K6

§12 closed the RETROFIT. The remaining question was whether interning at
CONSTRUCTION would pay, and that turns on one measurement: how often does the
monomorphizer build a type that already exists? Measured by wrapping the five
smart constructors in the DEV-JS compiler (`design_docs/js-instrumenting-guide.md`
pattern, identity = the spec comparable key) over a full subst self-compile:

| constructor | calls | distinct | duplicates | dup% |
|---|---|---|---|---|
| `mCustom` | 8,837,865 | 4,992 | 8,832,873 | 99.9% |
| `mRecord` | 2,114,126 | 366 | 2,113,760 | 100.0% |
| `mList` | 1,928,404 | 709 | 1,927,695 | 100.0% |
| `mTuple` | 1,067,294 | 2,433 | 1,064,861 | 99.8% |
| `mFunction` | 831,176 | 107,822 | 723,354 | 87.0% |
| **TOTAL** | **14,778,865** | **116,322** | **14,662,543** | **99.2%** |

**99.2% of type construction is duplicate work** — 14.8M nodes built for 116K
distinct types. That vindicates the DESIGN: construction-time hash-consing
would never allocate those 14.66M nodes, making it allocation-NEGATIVE, the
exact opposite of §12's retrofit. And the probe is cheap: with interned
children the bucket confirm compares child ids, so it is O(arity), not
O(tree).

**But the pool is small.** 14.78M constructions against the 3.93B objects a
census-lowered self-compile allocates is **0.376% of allocation**. So the
ceiling on K6 is a fraction of a percent of wall — the same answer §10 gave
for comparison (≤1.94%) and §11 gave for the K4 allocation win (~1%). Nothing
on this track is a wall lever.

**The one argument this census cannot settle is RETENTION.** Sharing would
collapse 14.8M live type objects to 116K distinct ones. §11 established that
GC cost here follows SURVIVORS, not allocation volume — which is precisely why
K4's −21% allocation bought nothing. If MonoTypes are a meaningful share of
the 376M promoted objects, sharing would cut promotion in a way no
allocation-side measurement predicts. **Sizing that requires a live-heap
composition census, and that — not another allocation count — is the
prerequisite for K6.**

**Cheaper variant, if K6 is ever attempted:** `mFunction` holds 107,822 of the
116,322 distinct types (93%) because lambda sets fragment the spec-key space,
while every other constructor has fewer than 5,000. A LAYOUT-only intern table
(arrows erased) would be dramatically smaller and would still serve the codegen
type registry and `ctorShapes`, which are the layout-keyed dictionaries.

## 14. K6 — construction-time hash-consing: DESIGNED, NOT LANDED

§13 established the case: 99.2% of type construction is duplicate work, so
hash-consing at construction would be allocation-NEGATIVE — the opposite of
§12's retrofit. This section records the design and the exact remaining work.
**It was not implemented: the session ran out of runway before the 57-site
cascade could be landed AND verified, and a half-threaded monomorphizer is
worse than none.** The tree is on the §11 state.

### Why the payoff is bounded (derived, no new measurement needed)

Sharing removes at most the 14.66M duplicate constructions. Against the
**375.9M objects this workload promotes**, that is **≤3.9% of promotion even if
every constructed type survived** — and most are substitution intermediates
that die in the nursery. Allocation-side it is 0.376%. Since §11 established
that GC cost here follows survivors, both mechanisms land under 1% of wall.
That bound is why this is documented rather than shipped.

### Design (module written; kept at the scratch path below)

`Compiler.AST.Intern`: `Intern = HashMap MonoType MonoType`, structure →
canonical object, with `hashCons : MonoType -> Intern -> ( MonoType, Intern )`.

**The one subtlety that must not be lost: canonicalisation is by EXACT
structure (`==`), never by comparable-key equality.** The key equivalences
deliberately merge distinct structures — `MVar _ CNumber` keys as `MInt` (D4),
`MVar` ids are erased (MONO\_003) — so canonicalising by them would return a
type that is *keyed* the same but *shaped* differently, silently changing
emitted code. `specHashOf` is the bucket hash (equal structure ⇒ equal hash is
all a hash must promise); `==` decides.

No id field is needed, which is the simplification §12 lacked: the runtime's
structural equality short-circuits on pointer identity
(`elm-kernel-cpp/src/core/Utils.cpp`), so canonical objects already compare in
O(1). `eqKeySpec`/`eqKeyLayout` would gain an `a == b ||` fast path — sound
because `==` is STRICTER than key equality.

### Remaining work, in order

1. Thread `Intern` through `TypeSubst.applySubstPure` and its helpers
   (`applySubstList`, `applySubstLambdaChain`). **This is contained** —
   `applySubstPure` has no callers outside `TypeSubst`. Leave `resolveMonoVars`
   pure (its results stay uncanonical: sound, just fewer pointer-equal probes).
2. Make the entry point `applySubstFiltered` return `( MonoType, Intern )`.
3. Put the table in `MonoState.ctx`; change
   `applySubstFV : MonoState -> Substitution -> Can.Type -> MonoType` to return
   `( MonoType, MonoState )`.
4. Convert its **57 call sites** in `Specialize.elm`. Most are `let` bindings
   (mechanical), but some sit in pure expression positions that need
   restructuring, e.g.
   `( name, applySubstFV state refinedSubst paramCanType )` inside a
   `List.map` (→ threaded fold) and
   `if not (Mono.containsAnyMVar (applySubstFV state subst rootCanType))`
   (→ let-bind first).
5. Add the `a == b ||` fast path to both key-equality functions.
6. Gates: elm-tests, E2E, bootstrap (BOTH fixed points — byte-identity does not
   apply, output ordering is unaffected but sharing is not observable anyway),
   then benchmark against `bin/eco-compiler-k4fix`.

**THE RISK THAT DECIDES HOW TO DO STEP 4: state-threading bugs are SILENT.**
Using `state` where `state1` is required type-checks — both are `MonoState`.
Every other stage of this plan failed loudly (compile error, crash, or a red
test); this one would not. Convert one call site at a time, and treat the
bootstrap as the gate rather than the test suite.

Scratch artefacts from the attempt: `Intern-K6.elm` (the written module),
`src-prek5/` and `tests-prek5/` (the verified §11 sources) under the session's
tmp directory.
