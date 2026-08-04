# Mono comparable-key optimization (compiler-source refactor)

**Status: NEW 2026-08-04 — extracted from `plans/opt-tier2-cons-fusion.md`
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
