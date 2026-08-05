# Sum-type wrapper unboxing — closing the `CtorOpts` gap

**Status: D-W PASSED 2026-08-05 on both clauses, but W1's dynamic half
RE-AIMED the plan: build option (a) — generalized nullary embedding —
first, not the payload unboxing this plan was named for. §3 W1 RESULT has
the numbers; the static half of W1 is the remaining open work.**

> **LH1 result (`benchmarks/tier2-opt.md` Run H): `Custom` is 60.7% of all
> promotion on subst (216,982,024 objects, 6,794 MiB) and 61.8% on solver
> (238,406,822, 7,466 MiB) — six times the ≥10% gate this plan set, and the
> largest single retained class by a factor of 1.7 over everything else
> combined.** For contrast, the standard binary's *allocation* histogram
> ranks `Custom` sixth at 2.6%. Retention was the right question.

**Provenance:** `plans/opt-tier2-cons-fusion.md` §5 U-T2.6′, surfaced while
classifying the comparable-key work.

> **CATEGORY B — a representation change in the compiler's front-end and
> codegen, so it changes what eco emits for every program.**
>
> **This plan touches representation invariants. Per CLAUDE.md, read
> `design_docs/invariants.csv` (REP_HEAP_002, MONO_013, MONO_026, TOPT_006,
> CGEN_001/003) and verify compliance before modifying anything here.** It
> is the highest-risk of the four tier-2 descendants by a wide margin.

---

## 0. The gap, precisely

`Can.CtorOpts` (`compiler/src/Compiler/AST/Canonical.elm:413`) has exactly
three cases, assigned by `toOpts`
(`compiler/src/Compiler/Canonicalize/Environment/Local.elm:526`):

```elm
toOpts ctors =
    case ctors of
        [ ( _, ( _, [ _ ] ) ) ] -> Can.Unbox          -- ONE ctor, ONE field
        _ -> if List.all (List.isEmpty << Tuple.second) ... then Can.Enum
             else Can.Normal
```

| union shape | opts | runtime cost |
|---|---|---|
| one ctor, one field — `type Meters = Meters Float` | `Unbox` | **none** — the payload *is* the value |
| all ctors nullary — `type Dir = N \| S \| E \| W` | `Enum` | **none** |
| **everything else** | `Normal` | **one heap `Custom` per value** |

**The gap is the third row's most common inhabitant: multi-constructor
unions whose constructors each carry exactly one field.**

```elm
type WorkItem = WorkType MonoType | WorkMarker String
```

Two constructors, one field each. Neither `Enum` nor `Unbox` applies, so
every stack entry is a heap `Custom` object wrapping a pointer that already
exists.

**The unwrapping machinery downstream already exists** and is not the
obstacle: `TypedPath.Unbox` (TOPT_006), `MonoUnbox`
(`Monomorphized.elm:1597`), and MONO_026's rule that codegen must resolve
the wrapper shape from the wrapper `MonoType` + its `CtorLayout`. What is
narrow is the *admission rule* in `toOpts`, which is four lines of pattern
match written for stock Elm.

## 1. Why it might matter

- `Custom` is the **largest true-allocation class: 38.6% of 6.52B objects**
  on the self-compile workload (borrow census §18.3) — larger than Closure
  (22.1%), Tuple2 (19.2%) and Cons (10.4%).
- The explicit-work-stack idiom is the standard Elm workaround for the
  absence of guaranteed deep recursion, so this pool exists in user programs,
  not only in the compiler.
- K2 measured the compiler's own instance: deleting one `WorkItem` wrapper
  pool was worth **`Custom −61.6M`**.

**And why it might not.** Allocation share is the metric this series has
falsified three times. The question W1 must answer is not "how much `Custom`
is allocated" but **"how much `Custom` is promoted"** — which is why this
plan is gated on LH1 rather than on another allocation census.

## 2. The design space, honestly bracketed

Multi-constructor unboxing is not free: something must still recover *which*
constructor a value is. The options are not equally good and the plan should
not pretend otherwise.

### (a) Generalized nullary embedding — cheapest, probably largest

`Nothing`, `True` and `False` are already **embedded HPointer constants**
(0x4/0x5/0x6, `CONSTANT_TAG=0xFFFD`) and cost no allocation. But the
admission test is a hard-coded name match:

```elm
-- compiler/src/Compiler/Data/CtorTag.elm:68
isEmbeddedConstantCtor name =
    name == "Nothing" || name == "True" || name == "False"
```

So `Maybe a = Nothing | Just a` is *half* optimized: `Nothing` is free,
`Just x` allocates a `Custom`. And any user union mixing nullary and
single-field constructors — overwhelmingly common in idiomatic Elm — gets no
embedding at all for its nullary arm.

Generalizing this to *"any nullary constructor of any union"* is a
**mechanism that already exists**, applied by a rule instead of by a name
list. It needs a constant-space allocation scheme (more than three reserved
values) and a matching update at every `CONSTANT_TAG` test site
(`Generate/MLIR/Patterns.elm:187,1222-1233`), but it introduces no new
representation concept.

> **Check first, before designing anything:** `isEmbeddedConstantCtor` keys
> on the *bare constructor name* with no home-module qualification. Determine
> whether a user-defined `type Foo = Nothing | Bar Int` is currently treated
> as carrying an embedded constant, and whether that is correct. If it is a
> live miscompile it is a bug fix that outranks this entire plan; if it is
> guarded elsewhere, record where. Do not build on this mechanism until the
> answer is written down.

### (b) Disjoint-payload-tag encoding — narrow but real

If every constructor's field type maps to a **distinct runtime `Tag_*`**,
represent the value as the bare payload and recover the constructor by
reading the payload's own header tag. `WorkType MonoType | WorkMarker
String` qualifies: `Custom` vs `String` are distinguishable.

Constraints, all disqualifying when violated:

- two constructors wrapping the same tag → inadmissible;
- an unboxed `Int`/`Float`/`Char` field has **no header at all**
  (REP_HEAP_002: only Int/Float/Char are unboxed, and Bool is *not*) → a
  constructor with a primitive field is inadmissible unless every other
  constructor is boxed *and* the primitive is distinguishable by HPointer
  constant-bit tests;
- lowering changes from an index switch on the ctor tag to a **tag-dispatch
  decision tree**, which must agree with MONO_026's requirement that field
  index and representation come only from the wrapper `MonoType` and its
  `CtorLayout`.

Real, but expect a small qualifying population — and say so in the census
before measuring it, so the result is a prediction tested rather than a
number rationalized.

### (c) Spare-bit tagging — NO

Stamping a constructor index into spare bits of the payload requires
mutating an object the wrapper does not own; payloads are shared and
immutable. Recorded here only so it is not re-proposed.

## 3. Units

### W1 RESULT (2026-08-05) — the dynamic half, and it RE-AIMS the plan

`benchmarks/tier2-opt.md` Run I. Custom's `Header.size` **is** the field
count (`AllocatorCommon.hpp:268`), so the promoted `Custom` pool splits by
arity directly. `nfields == 1` is an exact **upper bound** on option (b)'s
addressable population — single-ctor single-field unions are already
`Can.Unbox` and never allocate a `Custom` at all.

| fields | subst promoted | % of promo'd Custom | bytes | solver | % |
|---|---|---|---|---|---|
| **0** | **19,727,577** | **9.1%** | 301 MiB | 23,839,766 | 10.0% |
| **1** | **26,374,254** | **12.2%** | 604 MiB | 32,952,581 | 13.8% |
| 2 | **121,871,271** | **56.2%** | 3,719 MiB | 125,064,224 | 52.5% |
| 3 | 25,996,919 | 12.0% | 992 MiB | 27,867,003 | 11.7% |
| 4 | 6,631,343 | 3.1% | 304 MiB | 8,320,287 | 3.5% |
| 5 | 16,374,504 | 7.5% | 874 MiB | 20,356,805 | 8.5% |
| 6 | 6,156 | 0.0% | 385 KiB | 6,156 | 0.0% |

**Three findings, and the second one re-aims this plan:**

1. **Option (b) — payload unboxing of multi-ctor single-field unions — is
   capped at 12.2% of promoted `Custom` = 7.4% of total promotion**, and
   that is the *upper bound* over all 1-field Customs regardless of union
   shape. The genuinely admissible subset (every ctor single-field AND
   pairwise tag-disjoint) is a strict, unmeasured subset of it. D-W's ≥3%
   clause passes on the bound, but the bound is doing the work.
2. **Option (a) — generalized nullary embedding — is nearly as large at
   9.1% (5.5% of total promotion) and its win per object is TOTAL.** These
   are 19.7M heap objects carrying **zero fields**: 16 bytes and a header
   apiece for nothing but a constructor index, 301 MiB retained. Embedding
   them removes the object entirely rather than shrinking it. They exist
   only because their union has *some* non-nullary constructor, so `toOpts`
   returns `Normal` and the nullary arms allocate alongside the rest —
   `Can.Enum` requires **all** constructors nullary
   (`Local.elm:526-538`), and `isEmbeddedConstantCtor` is a hard-coded
   three-name list (`CtorTag.elm:68`).
3. **The elephant is 2-field `Custom` at 56.2% / 3,719 MiB**, which this
   plan cannot address at all. It is the single largest identified shape in
   the retained heap and deserves its own investigation — see §6.

**Revised recommendation: do W2 (option a) first and possibly only.** It is
the simpler mechanism (a rule replacing a name list, on machinery that
already ships), it carries none of option (b)'s tag-disjointness fragility
or decision-tree rework, its population is within 3 points of (b)'s, and
its per-object win is larger. Option (b) should not start until (a) has
shipped and been re-measured — they overlap on the same unions, and after
(a) removes the nullary arms the remaining case for (b) shrinks.

**Still owed for option (a):** the static half — how many *distinct* unions
and construction sites produce those 19.7M nullary Customs, and the
constant-space budget needed to embed them (today only three reserved
values exist: `False`=0x4, `True`=0x5, `Empty`=0x6, `CONSTANT_TAG`=0xFFFD).

### W1 — the census (gated on LH1)

Requires `plans/live-heap-composition-census.md` LH1 (per-tag promotion). On
the self-compile corpus **and at least one user workload**, report:

1. `Custom` share of **promotion** and of major-GC mark cost (LH3), not just
   of allocation. *This is the number that admits or kills the plan.*
2. Static breakdown of `Custom`-producing unions by shape: single-ctor
   multi-field / multi-ctor mixed-arity / **multi-ctor all-single-field** /
   nullary-plus-payload (the (a) population) / tag-disjoint (the (b)
   population).
3. Dynamic weight per shape — join the static classes against the per-tag
   allocation and promotion tallies. A shape with 400 declaration sites and
   no dynamic weight is not a target; this series has four precedents.

`ECO_CTOR_SHAPE_REPORT=1`, output-only, excluded from the artifact hash
(`Config.elm:110-111` pattern).

### D-W — the gate

Proceed iff **`Custom` promoted share ≥10% of total promotion** AND a single
identified shape class carries ≥3% of it. Otherwise record the table and
close the plan — that is a legitimate outcome and the honest prior.

Note the asymmetry: (a) may clear the gate on its own even if (b) does not,
and (a) is far cheaper. **Do not bundle them.**

### W2 — generalized nullary embedding (if (a) clears)

Replace the name list with a rule; allocate constant space; update every
`CONSTANT_TAG` test site. Independently shippable and independently gated.

### W3 — disjoint-payload unboxing (if (b) clears)

New `CtorOpts` case, tag-disjointness analysis over `CtorLayout`s, and
tag-dispatch lowering. Only after W2, and only on its own measured evidence.

## 4. Risks

- **Byte-identity is forfeit by construction** — this changes the emitted
  representation. The gate that replaces it is the bootstrap with **both**
  fixed points (Stage 4b JS, Stage 8c native), per the K4 precedent
  (`mono-comparable-key-optimization.md` §11). Stage the refactor so a
  mechanical half *can* be validated by identity before the semantic half
  lands — that method is what made K4's 641-site edit reviewable.
- **This is the deepest-reaching of the four plans.** `CtorOpts` flows from
  canonicalization through typed optimization (TOPT_006), monomorphization
  (MONO_013, MONO_026), pattern lowering and GC layout (REP_HEAP_002). A
  wrong `unboxedBitmap` is a miscompile no emission strategy can repair
  (MONO_029).
- Serialization: `CtorOpts` has explicit byte encoders/decoders
  (`Canonical.elm:817-849`). A new case changes the artifact format —
  purge `~/.eco` and per-package `typed-artifacts.dat`, or expect the
  silent-empty-graph failure mode (`eco-missing-typed-artifacts-silent-empty`).
- Adding a new `.elm` file needs `cmake --preset build` (the `ELM_SOURCES`
  glob is not `CONFIGURE_DEPENDS`).
- `ECO_HEAP_VALIDATE` clean is mandatory, not optional, for any layout
  change.
- Run E2E once, teed, grep the file. Serialize against elm-tests.

## 5. Interaction with the shipped hand-fixes

`plans/mono-comparable-key-optimization.md` K2 hand-deleted the compiler's
own `WorkItem` wrapper pool (`Custom −61.6M`). If W3 ships, that hand-fix
becomes redundant — which makes it a **free measurement of what the pass
would be worth at one site**, already taken. Read it that way rather than as
competing work: one site, −61.6M `Custom`, and *zero* wall movement
attributable to it, which is itself part of the honest prior.
