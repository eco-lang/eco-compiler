# Kernel intrinsic annotations — give kernels real types and make the typechecker enforce them

**Status: PLAN (2026-08-20; investigation COMPLETE, implementation NOT started).**
Successor to the occurrence-verification arc of
`plans/kernel-parametricity-license.md`, which established the problem this plan
removes. All code refs verified at HEAD 2026-08-20.

---

## §0 The problem, precisely

`Elm.Kernel.*` references generate **no type constraint whatsoever**:

```elm
-- Type/Constrain/Typed/Expression.elm:1524
Can.VarKernel _ _ _ ->
    IO.pure CTrue
```

So a kernel is typed entirely by its context. An ANNOTATED kernel (one with an
eta-free aliasing def like `map2 = Elm.Kernel.List.map2`) is bounded indirectly
— every use goes through the alias, whose annotation constrains it. An
UNANNOTATED kernel is bounded by nothing: `toArray` does not operate as
`List a -> Array a`; it effectively operates as `α -> β` with the two sides
never connected — measured directly during the license work (the occurrence of
`List.fromArray` inside `String.split` is `β -> List String` with β UNSOLVED,
and shape-bisection proved β matches neither `Array` nor `JsArray`, only a bare
variable).

Two whole subsystems exist to work around this hole:

- **`PostSolve`'s kernel-type inference** (`Type/PostSolve.elm:350-1250`, ~900
  lines): alias seeding + first-usage-wins inference + special-cased kernel
  handling in Call/Binop/Case-branch/ctor-arg positions — all reconstructing,
  after the fact and heuristically, what a constraint would have established
  during solving. Its own comment admits the result is "wrong for polymorphic
  kernels used through aliases" (`LocalOpt/Typed/Expression.elm:412-416`).
- **`KernelSetFacts.TransportsAs`** (LSS_022): a declared shape checked against
  the occurrence — which cannot assert anything the occurrence does not already
  carry, and the occurrence carries nothing.

The fix is the obvious one: a compiler-internal table of kernel type
annotations, and the `VarKernel` arm emits a real constraint when a row exists.

## §1 The mechanism already exists — this is a table plus one arm

Everything needed is in place and verified:

- **There is ONE constraint generator.** `Constrain/Erased/Module.elm` is 25
  lines: the erased (annotation-only, package-validation) pathway calls
  `Typed.constrainErased` — the same generator with node recording disabled. So
  `Typed/Expression.elm:1524` is the single arm to change, and both pathways
  (`Compile.typeCheck` :271 and `Compile.typeCheckTyped` :310) pick the change
  up automatically and consistently.
- **`CForeign` is exactly the constraint form needed.**
  `CForeign region name (Can.Forall freeVars srcType) expected`
  (Type/Type.elm:97) is what `VarForeign`/`VarCtor`/`VarDebug` already emit;
  the solver arm (Type/Solve.elm:254-279) instantiates the annotation FLEXIBLY
  per occurrence via `srcTypeToVariable` and unifies with the expectation.
- **The Call path connects everything.** `callSpineGo` constrains the callee
  against `NoExpectation (VarN funcVar)` and `assembleCall` emits
  `CEqual funcType (argTypes ==> resultType)` (Typed/Expression.elm:859-874),
  so a `CForeign` on the kernel callee links args to result through the
  instantiated annotation with zero further work — identical to how a foreign
  function call solves today.
- **Constrained variables come free.** `srcTypeToVariable`'s `nameToContent`
  (Solve.elm:889-902) maps annotation variables BY NAME: a var literally named
  `number`/`comparable`/`appendable` instantiates as the corresponding
  `FlexSuper`. So even `String.fromNumber : number -> String` — the kernel with
  two different aliasing types — is expressible. (This is also a footgun:
  an innocently-named `number` var in a table row silently becomes a super.
  Document it in the table's module doc.)
- **No serialization or AST change.** `Can.Expr` keeps its shape; the table is
  consulted at constraint generation. Interfaces, typed-artifact FORMATS, and
  golden fixtures are untouched (`GoldenConstraintTest` has zero kernel
  fixtures — checked).

### The change itself

New module `compiler/src/Compiler/Type/KernelIntrinsics.elm`
(imports: `Can`, `Name`, `IO`/ModuleName helpers — no cycle; `Type/` sits below
everything that would want to consult it):

```elm
type alias Row =
    { annotation : Can.Annotation Name
    , useSites : String   -- EVERY syntactic use site, enumerated + verified (§3 H2)
    , evidence : String   -- C++ heap-contract citation + audited date (§3 H1)
    , files : List String -- the audited C++, for the rot manifest (§5)
    }

lookup : Name -> Name -> Name -> Maybe Row   -- PREFIX, home, name — see below
```

and the one-arm change:

```elm
Can.VarKernel prefix home name ->
    case KernelIntrinsics.lookup prefix home name of
        Just row ->
            IO.pure (CForeign region (errorName prefix home name) row.annotation expected)

        Nothing ->
            IO.pure CTrue
```

**The key MUST include the kernel prefix** (`Can.VarKernel` carries it; the arm
currently discards it). `KernelSetFacts.factFor` is keyed `(home, name)` and
already collided on `Elm.Kernel.File.size` vs `Eco.Kernel.File.size` — two
kernels with DIFFERENT types sharing a key. The license table tolerates that
(one row covering both, both vacuous); an ANNOTATION table cannot: unifying
`Eco.Kernel.File.size`'s occurrences against `File -> Int` would be a type
error at best and a representation lie at worst. The prefix is available here;
use it.

`errorName` renders `"Elm.Kernel.List.fromArray"` — `CForeign`'s Name is only
used for error text (`Error.Foreign name`, Solve.elm:273), and the audience is
kernel-package authors, the only people who can write a kernel reference.

## §2 What v1 annotates — three rows, each already audited

The license audit (plan `kernel-parametricity-license.md`, execution record)
already did the C++ work; these annotations are the same claims in type form.

| kernel | intrinsic annotation | basis |
|---|---|---|
| `Elm.Kernel.List.fromArray` | **`List a -> List a`** | C++ is a pass-through: Nil/Cons inputs returned BY IDENTITY (ListExports.cpp:306-354), and `Elm_Kernel_String_split` returns a proper List (:322-325 comment). NOT `Array a -> List a` — see H1. |
| `Elm.Kernel.List.toArray` | **`List a -> List a`** | Same: pass-through (:356-392); `String.join`'s C++ consumes the list directly. |
| `Elm.Kernel.Json.addEntry` | `(a -> Value) -> a -> Value -> Value` | JsonExports.cpp:1761-1793: applies the encoder to the entry, conses the RETURN onto an ENC_ARRAY. `Value` positions are heap-honest the same way every annotated `Json.Encode.*` function already is (ENC_* Customs behind the opaque `Value`, per json_heap_representation_theory.md). |

Use-site totality (H2), verified: `fromArray`/`toArray` have exactly one use
each (`String.elm:191`/`202`, both at `a = String`); `addEntry` has three
(`Json/Encode.elm:162/170/178`), each `foldl (addEntry func) (emptyArray ())`
— all instances of the annotation. Nothing else in any installed package
references these names (closed set: kernel refs are only legal in
kernel-package source).

The **eco-kernel package needs no table**: we own
`eco-kernel-cpp/src/Eco/*.elm`, so its kernels get real aliasing defs there —
the zero-compiler-change mechanism that vendored `elm/*` packages can't use.

## §3 Hazards — the two that decide everything, plus housekeeping

**H1 — Annotations are REPRESENTATION claims, and the C++ contract wins.**
An intrinsic annotation tells the solver what heap values inhabit each
position, and solved types feed layout- and ABI-sensitive passes downstream.
The "documented" JS-era type can be a LIE about the eco backend:
`fromArray`'s JS type is `Array a -> List a`, but eco's C++ receives and
returns Cons lists — and `Array` in elm/core is a real 4-field custom type.
Annotate the JS type and `String.split`'s intermediate value is statically an
`Array String` while dynamically a Cons list: a layout-trusting consumer away
from a miscompile, in the same class as the REP regressions this repo has
already paid for. **Rule: the annotation describes the ECO C++ contract,
evidenced from the C++ exactly like a license row.** The pleasant irony: the
honest `List a -> List a` is also the type under which the license tunnel is
trivial.

**H2 — This is FAIL-STOP, the license's opposite.** A wrong license poisons
nothing worse than precision; a wrong intrinsic annotation is a TYPE ERROR in
package code — and the typechecker sees DEAD code too. Standing
counterexample: the `Bytes.write_*` family. elm/bytes 1.0.8 contains a dead,
unexposed `write` helper calling them JS-style (3-4 args, `Int` results) while
eco's C++ builds 1-2-arg `Encoder` nodes. Any honest annotation for `write_*`
makes elm/bytes FAIL TO COMPILE. So: strictly per-kernel opt-in; a row
requires the enumerated, verified list of every syntactic use site in every
installed package (including dead defs); `write_*` is unannotatable without
patching vendored source and goes on the module doc's rejected list.

Housekeeping hazards:

- **H3 — stale package artifacts make the change invisible.** `~/.eco`'s
  per-package `typed-artifacts.dat` persist across compiler changes (Run U/V
  lesson), and every interesting kernel occurrence lives INSIDE a package
  (`String.elm`, `Json/Encode.elm`). Without a fresh-`~/.eco` re-lower leg the
  new constraints never touch the code they exist for. The battery must
  include one, plus the seed-cache nuke the JS-bootstrap memory prescribes.
- **H4 — parity suite.** The typed/erased parity tests exercise the shared
  generator and carry 12 pre-existing failures; the gate is "same 12", not
  green. Unit-test fixtures contain no `VarKernel` nodes (kernel refs can't be
  written in test source; the mock env's kernel-alias nodes are synthesized
  post-typecheck), so no churn is expected — verify, don't assume.
- **H5 — artifact movement.** Solved occurrence types flow into
  `TOpt.VarKernel` meta, KernelAbi derivation inputs, and mono spec keys:
  `out.mlir` legitimately moves. ABI stays boxed for non-suffix-selecting
  kernels (the three rows are not in `KernelAbi.suffixSelectingKernels`), but
  the run is an analysis change and gets the full battery + one lss-opt.md row.

## §4 What it buys — and an honest zero

- **The typechecker enforces kernel usage.** Today a kernel-package author can
  apply `addEntry` to a `String` and learn about it at runtime. The license
  audit surfaced real divergences of exactly this species (`Debug.toString`
  arity, `Bytes.decodeFailure`, `sendToApp`'s `void`); intrinsic rows turn the
  annotated subset into compile-time errors.
- **Licenses get a real basis.** With occurrences SOLVED, `TransportsAs`
  shapes verify against facts instead of unsolved mush:
  `fromArray`/`toArray` become licensable at `List a -> List a` (they are
  currently ROWLESS — refused for want of any auditable type), and
  `addEntry`'s weak arity-only shape upgrades to the full sharing shape.
  Derive the shape mechanically from the annotation
  (`shapeOfAnnotation : Can.Annotation Name -> TypeShape`, or a unit test
  pinning the two tables equal) so they cannot drift.
- **The PostSolve retirement path.** ~900 lines of usage-inference exist
  because kernels have no types. A grown table makes `KernelTypeEnv` readable
  FROM the table and the inference machinery deletable. Not v1 — recorded as
  the structural payoff.
- **The honest zero: expected LSS precision gain on the CURRENT ecosystem is
  nil, and v1 must not be sold otherwise.** `fromArray`/`toArray` only ever
  carry `String` elements (no arrows, no set content), and `addEntry`'s
  `a`-sharing between encoder-arg and entry ALREADY holds at its occurrences —
  `list`'s own annotation plus `foldl`'s pins it; only the `Value`/accumulator
  positions are unsolved, and `Value` is concrete (no set slots). This is a
  soundness-and-discipline investment with a Run-Y-shaped census expectation:
  counters sharpen (a few boundaries move from `byKernel` to `kernelLicensed`),
  precision flat.

Two matcher notes that fall out of the investigation, for the phase-2 rows:

- `sameType`'s `TVar ~ TVar = True` makes repeated-var claims in a `TypeShape`
  VACUOUS against unsolved occurrences (sound — matching gates, it never
  creates sharing — but it means today's shapes cannot REQUIRE sharing). Once
  occurrences are solved this looseness stops mattering for the three rows;
  tightening it (compare var ids via a threaded eq) is optional v2.
- The measured addEntry mechanism, corrected: position 1 was ALWAYS solved
  (`list`'s annotation); the killers were the `Value`-naming positions against
  the unsolved accumulator. The row comment in `KernelSetFacts.elm` now says
  this accurately.

## §5 Rot discipline

An intrinsic annotation is the same species of claim as a license — a
statement about C++ the compiler cannot see — so it gets the same guard:
rows carry `files`, and `test/scripts/check-kernel-license-manifest.sh` learns
to harvest `KernelIntrinsics.elm` alongside `KernelSetFacts.elm` (same
`( ( "Home", "name" )`-anchored awk; add the file to the top-level
`KERNEL_LICENSE_DEPS` in CMakeLists.txt so edits re-run the check). Manifest
lines gain nothing structurally; the kernel column already carries `Home.name`.

Beyond C++ rot, intrinsic rows add a NEW rot axis the manifest cannot see:
**vendored package source**. A future elm/core bump that changes `String.elm`'s
use sites can invalidate the use-site-totality evidence (H2) silently — the
symptom is a package that stops compiling, which is loud, so this is
acceptable; say it in the module doc rather than build machinery for it.

## §6 Execution order

1. **Mechanism + three rows** (§1, §2): `KernelIntrinsics.elm`, the one-arm
   change, manifest-script extension. Unit tests: a fixture typechecking a
   synthetic module against a table row (positive + a deliberate-mismatch
   negative asserting the error, not a crash); table-discipline pins in the
   KernelLicenseTest style (evidence markers, non-empty files, prefix-keyed).
2. **Battery**: `--target full`; elm-tests (parity gate = same 12); fresh
   `~/.eco` re-lower leg (H3) + differential probe re-run (the §"probe" harness
   from the license arc: `Base`/`UsesJson`/`UsesSplit` through the Stage-1
   compiler, diffing `byKernel`/`kernelLicensed`); one lss-opt.md PLAIN run
   (analysis change — `out.mlir` legitimately moves; say so in the entry).
3. **License follow-through**: add `TransportsAs (List a -> List a)` rows for
   `fromArray`/`toArray` (currently rowless — their audit evidence is in
   `survey-list.md` and stays valid; only the type basis was missing); upgrade
   `addEntry`'s shape to full sharing; shape-vs-annotation sync test; probe
   must now show the licensed counts move where the diagnostic bisection said
   they would.
4. **Invariants**: new TYPE-row for the intrinsics contract (fail-stop,
   C++-contract-wins, prefix-keyed, use-site totality) + LSS_022 amendment
   pointing `TransportsAs` at it.
5. **Later, separately**: eco-kernel aliasing defs in `Eco/*.elm`; PostSolve
   retirement census (how much of the ~900 lines is still exercised once the
   table covers the hot kernels); more rows strictly on demand.

Effort: the mechanism is small (a table module, six lines in the generator, a
script extension — a day including tests). The battery dominates, as always:
bootstrap + fresh-corpus leg + benchmark row. Do not start phase 3 before the
phase-2 probe confirms occurrences actually solve.

## §7 Alternatives considered and rejected

- **Mono-time declared-scheme unification** (unify the occurrence with an
  instantiated declared type inside the `TransportsAs` arm): no typechecker
  change, but it CREATES type sharing in the item memo at mono time — solving
  vars the typechecker left open, which is precisely the taint class
  `deriveKernelAbiTypeWith`'s remap machinery exists to defend against
  (ConsNumberTaint, RecordNarrow). Solving at the proper phase is the whole
  point of the user-proposed design; this shortcut re-imports the hazard.
- **Patching vendored elm/* source with aliasing defs**: real annotations,
  no compiler change — but vendored churn on every upgrade, and it cannot fix
  `write_*` (the contradicting dead code is in the same file).
- **Annotating via `KernelTypeEnv`/PostSolve instead of constraints**: types
  would exist but nothing would ENFORCE them at solve time, and the entire
  first-usage machinery stays; this is the status quo's shape with extra rows.

---

# EXECUTION RECORD — Phases 1 & 2 (2026-08-20)

## What landed

- `compiler/src/Compiler/Type/KernelIntrinsics.elm` — the table, keyed
  `(prefix, home, name)`, three rows, each carrying `annotation` / `useSites`
  (the fail-stop evidence) / `evidence` (the C++ heap contract) / `files`.
- `Type/Constrain/Typed/Expression.elm` — the `Can.VarKernel` arm emits
  `CForeign region "<Prefix>.Kernel.<Home>.<name>" row.annotation expected` when
  a row exists, and `CTrue` otherwise. Six lines plus a helper. Both pathways
  (typed + erased) pick it up, as predicted, because they are one generator.
- `test/scripts/check-kernel-license-manifest.sh` harvests the intrinsics table
  alongside the license table (three-tuple key, no `TypeFaithful` flag,
  `<Prefix>.Kernel.<Home>.<name>` label so an intrinsic pin is never confused
  with a license pin on the same file); `KernelIntrinsics.elm` added to
  `KERNEL_LICENSE_DEPS`. Manifest: 311 → 314 pins.
- `compiler/tests/TestLogic/Type/KernelIntrinsicsTest.elm`, 8 tests;
  `TestPipeline` exposes `runToTypeCheck` (it existed, unexported).

Fixtures can write kernel syntax directly: `Canonicalize.findVarQual` produces a
`VarKernel` when the prefix is `Elm.Kernel.*`/`Eco.Kernel.*` and the enclosing
package satisfies `Pkg.isKernel` — and the harness canonicalizes as
`( "eco", "example" )`, whose author IS a kernel author. No import needed (the
kernel branch is the fallback when the prefix misses `q_vars`). That made real
end-to-end typecheck tests possible rather than table-shape pins.

## The pin that matters, and its counter-proof

Test 2 asserts `List String -> List Int` through `fromArray` does NOT
typecheck — i.e. that the two `a`s in `List a -> List a` are now the same `a`.
**Verified meaningful by disabling the table and re-running: it fails**, with
`List String -> List Int` typechecking happily. That is the `α -> β` behaviour
the plan set out to remove, reproduced and then removed under test.

Tests 3-4 pin fail-stop from the other side (a contradicting use is a type
ERROR, not a crash and not silent acceptance); test 5 is the opt-in negative
control (an unannotated kernel stays unconstrained); 6-8 are discipline pins,
including that a wrong PREFIX misses the row.

## Measured — a clean A/B, and a bigger effect than §4 predicted

Differential probe (three one-module programs through the Stage-1 compiler,
`ECO_MONO_LSS_REPORT=1`), both arms on freshly re-lowered packages:

| probe | table OFF (`byKernel` / `kernelLicensed`) | table ON | delta |
|---|---|---|---|
| `Base` (control, no annotated kernel) | 2 / 1 | 2 / 1 | unmoved |
| `UsesJson` (`Json.Encode.list`) | 8 / 3 | **6 / 5** | −2 poisoned, +2 licensed |
| `UsesSplit` (`String.split`/`join`) | 10 / 0 | **6 / 4** | −4 poisoned, +4 licensed |

**§4's "honest zero" was wrong, and the reason is the interesting part.** The
newly-licensed boundaries are NOT the annotated kernels — `fromArray`/`toArray`
still have no `KernelSetFacts` row at all. They are `String.split`,
`String.join` and `Json.emptyArray`, which have `Inert` license rows that
LSS_022 occurrence verification was CORRECTLY REFUSING: an unsolved type
variable is function-capable by `isInertType`'s (deliberately blunt) rule, so
every one of those boundaries failed verification and fell back to poison.
Solving the neighbouring kernel's type solved theirs too, and the existing
licenses started applying.

So the two mechanisms compose exactly as intended: verification refuses claims
it cannot check, and intrinsics supply the missing facts. Neither alone would
have moved these counters — verification alone made them stricter, intrinsics
alone would have had nothing to unblock.

A methodology trap worth recording: **a new compiler `.elm` file is not in
ninja's dependency glob until a reconfigure**, so the first A/B "OFF" arm was
silently the ON binary (identical numbers, `ninja: no work to do`). Run
`cmake --preset build` after adding a module before trusting any A/B.

## Gates

`--target full` 1685/1685 — and this is the load-bearing fail-stop evidence:
`elm/core` and `elm/json` were RE-LOWERED during the run with the annotations
active (`typed-artifacts.dat` regenerated 19:23), so the packages genuinely
typechecked against the new constraints. H3's stale-artifact hazard is
discharged, not assumed. elm-tests 13,153 passed / 12 failed — the same 12
pre-existing typechecker-parity failures, so the H4 parity gate holds.

Rot guard green; benchmark row recorded separately in `benchmarks/lss-opt.md`.

## Benchmark (lss-opt.md Run Z) — and why it attributes nothing

Wall 322.2 s, minors 1,381, majors 13, promoted 13,597 MiB, `out.mlir`
13,713,430 B. Against Run Y: wall +0.5 s, majors 13 = 13, promoted +0.36%,
`devirtDirect`/`devirtKernel`/`dispatchUpgraded` identical to the object —
FLAT, no regression.

**The self-compile counters must NOT be read as this change's effect.** Run Y
ran against package `typed-artifacts.dat` dated 2026-08-19 20:53; Run Z's were
regenerated at 2026-08-20 19:23, because the fail-stop gate REQUIRES the
packages to be re-lowered. That is two variables — the same break Run V
documented — so `byKernel` 1,575 → 1,608 and `kernelLicensed` 2,490 → 2,464 are
unattributed and are recorded as such. (Both directions are consistent with a
+7-boundary corpus growth plus re-lower churn; neither is evidence for or
against the annotations.)

Clean attribution comes from the differential probe, which holds the package
state fixed and toggles only the table — and that is where the effect is real
and one-directional. The lesson for future intrinsic rows: **measure them with
the probe, not the self-compile.** The self-compile has ~4,080 kernel
boundaries and a handful of `String.split`/`Json.Encode.list` sites; the signal
is a rounding error there, and re-lowering is a confound the protocol cannot
remove.

## Phase 3+ status

NOT started, and now better informed. Phase 3 (license follow-through) should
add `TransportsAs` rows for `fromArray`/`toArray` at `List a -> List a` — their
audit evidence in `survey-list.md` remains valid and the type basis now exists —
and upgrade `Json.addEntry`'s arity-only shape to the full sharing shape, since
its occurrence positions are now solved. Note the shapes to declare have changed
with the annotations: `fromArray`/`toArray` are `List a -> List a`, NOT the
`Array a -> List a` the earlier bisection failed to match.

---

# EXECUTION RECORD — Phase 3 (2026-08-20)

## What landed

- **`List.fromArray` / `List.toArray` are licensed again**, at
  `TransportsAs (List a -> List a)` — the type the intrinsic annotation pins,
  NOT the `Array a -> List a` that earlier shape-bisection proved matches
  nothing. Their C++ audit evidence (`survey-list.md`) never lapsed; only the
  type basis was missing, and §2's annotations supplied it.
- **`Json.addEntry`'s shape upgraded** from the arity-only stub to the full
  sharing claim `(a -> Value) -> a -> Value -> Value`.
- **`sameType`'s variable rule tightened** from "any two `TVar`s are equal" to
  identity. The loose rule made EVERY repeated-variable claim vacuous — a shape
  could assert sharing while checking none. It was tolerable only while
  occurrences were unsolved; now that they are solved the strict rule is both
  meaningful and satisfiable. (Sound in either direction: matching only GATES a
  license, it never creates sharing.)
- **`shapeOfAnnotation`** + a sync test pinning every `TransportsAs` shape equal
  to the kernel's intrinsic annotation. The two tables live in different
  subsystems and would otherwise drift silently, the failure mode being a
  license that quietly stops applying — which no gate would catch. Verified
  NON-VACUOUS by desyncing one shape and watching test 13 fail.

## Measured — the acceptance criterion, met

| probe | pre-intrinsics | Phases 1-2 | **Phase 3** |
|---|---|---|---|
| `UsesSplit` byKernel / kernelLicensed | 10 / 0 | 6 / 4 | **2 / 8** |
| `UsesJson` | 8 / 3 | 6 / 5 | 6 / 5 |
| `Base` (control) | 2 / 1 | 2 / 1 | 2 / 1 |

`UsesSplit`'s `byKernel` reaches **2 — identical to the control** — so every
kernel boundary that program adds beyond the baseline is now licensed rather
than poisoned. The four newly-licensed boundaries are `fromArray`/`toArray`,
landing exactly where the diagnostic bisection said they would.

`UsesJson` holding at 6/5 is the POSITIVE result for `addEntry`, not a null one:
had the full sharing shape failed to match, its boundaries would have fallen
back to poison and the split would have moved to 8/3. It didn't, so the
stronger claim verifies against the real occurrence — which is precisely what
was impossible before the annotations solved those positions.

## Gates

`--target full` 1685/1685; elm-tests 13,155 passed / same 12 pre-existing
typechecker-parity failures; rot guard green (manifest 314 → 316 pins). No
benchmark row: Run Z already established that the self-compile cannot attribute
this class of change (≈4,080 kernel boundaries, a handful of relevant call
sites, and a package re-lower confound the protocol cannot remove). The probe is
the instrument for intrinsic and shape work.

## Where the three plies ended up

Worth stating plainly, because the arc took three passes to get right:

1. **Licenses** (LSS_022) removed poison but could not tell a true claim from an
   unverifiable one.
2. **Occurrence verification** made them honest — and correctly refused a large
   set of them, because unsolved occurrence types are function-capable under
   `isInertType`'s blunt rule.
3. **Intrinsic annotations** (TYPE_KERNEL_001) supplied the missing facts, at
   which point the refused licenses started applying AND declared shapes became
   strong enough to assert sharing.

Each ply is inert or negative without the next: verification alone makes things
stricter, annotations alone have nothing to unblock. The composition is the
result.

---

# EXECUTION RECORD — "annotate the rest" (2026-08-20)

## The scope question, answered by measurement rather than by counting

A static scan finds **99 kernels referenced inline** (no eta-free aliasing def)
out of 290 referenced in package source. Annotating all 99 would have been
fail-stop roulette — VirtualDom's types are known-dishonest, `Bytes.write_*` is
known-unannotatable — and most of the 99 need nothing anyway: an eta-EXPANDED
def like `readString path = Eco.Kernel.File.readString path` is "inline" by that
scan, yet `assembleCall` already equates the kernel's type with the enclosing
annotation's. All ~20 `Eco.*` kernels are this shape, as are the 97
`VirtualDom.node` sites inside `Html.elm`.

So the population was measured instead. First attempt — a census of kernels
reaching the boundary with a free var in the occurrence type — was **too
blunt**: it flagged `List.cons`, `Utils.compare`, `Basics.add` and friends,
whose occurrences inside polymorphic callers are *correctly* free. Retargeted to
the actionable signal: **licensed kernels whose occurrence verification was
REFUSED**, i.e. exactly where an annotation would pay. On a broad probe
(`Json.Encode` list/object/dict, `Json.Decode`, `Bytes` encode/decode,
`String.split/join`, `Dict`, `Set`, `Array`):

    Basics.add=1 Basics.mul=1 Basics.sub=1 Utils.compare=1 Utils.gt=1 Utils.lt=1
    Json.addField=1 Json.emptyObject=1

## Six of the eight were a BUG in verification, not a missing annotation

`number` and `comparable` bottom out in scalars, so `Utils.compare : comparable
-> comparable -> Order` and `Basics.add : number -> number -> number` have no
function-capable position at all — that is ruling R1, stated in
`KernelSetFacts`'s own module doc since the license work. But
`hasFunctionCapable` never implemented it: it answered `True` for EVERY `TVar`,
so those licenses were refused wherever the kernel appeared inside a polymorphic
caller. On the hottest kernels in the compiler (`Utils.compare` alone is ~53% of
kernel calls on the self-compile).

Fixed by threading an `isScalarVar` predicate read from the solver's own super
table (`Engine.isScalarVar`, `Dict Int IO.SuperType` keyed by `mvarIdKey`), so
this is the typechecker's truth rather than a guess from a variable's spelling.
`appendable`/`compappend` stay function-capable — their `List a` arm reaches a
bare element variable — and a table MISS answers `False`, so the failure
direction is a missing license, never a wrong one.

## The remaining two were genuine, and one annotation closed both

`Json.addField : String -> Value -> Value -> Value` (the `object`/`dict` path,
exactly analogous to `addEntry`'s `list`/`array`/`set` path). Annotating it also
solves `Json.emptyObject` transitively through `foldl`'s accumulator — the same
way `addEntry` solved `emptyArray` in Phase 1 — so no separate row was needed,
and none was added: `emptyObject`'s C++ export takes zero parameters against an
Elm `() -> Value`, so an explicit row would assert an arity the export does not
have, for no gain.

## Measured

| probe | before this pass | after |
|---|---|---|
| `Wide` byKernel / kernelLicensed | 34 / 37 | **24 / 47** |
| `UsesJson` | 6 / 5 | 5 / 6 |
| `UsesSplit` | 2 / 8 | 2 / 8 |
| `Base` (control) | 2 / 1 | 2 / 1 |
| licenses REFUSED, all four probes | 8 | **0** |

Zero refusals means every license row now applies wherever its kernel is
reached in this corpus — the state the whole three-ply arc was aiming at.

## The census stays

`sigStats`-style one-shot censuses are normally deleted after their deliverable
run. This one is KEPT (report-gated, and factored so the default path carries
only the flag test) because it is the targeting instrument: annotations are
fail-stop, so "add another row" must be driven by a measured refusal rather than
by reading source. It is printed as `kernel licenses REFUSED at the occurrence:`.

## Gates

`--target full` 1685/1685; elm-tests 13,156 passed / same 12 pre-existing;
KernelLicenseTest 15 tests (new pin 9b covers R1 in both directions); rot guard
green.

## Self-compile refusal census (Run AA) — the first full-workload measurement

`kernel licenses REFUSED at the occurrence: Console.readLine=1 Env.rawArgs=1
File.getCwd=1 Runtime.dirname=1 Runtime.random=1`

Five, all eco IO kernels the four small probes never reached — so "zero
refusals" was a probe-corpus statement and is now correctly narrowed. Against
~4,080 kernel boundaries this is negligible in effect, but the CAUSE matters
because it is a gap in the verification, not in the audit:

All five have fully CONCRETE annotations (`Task Never String`,
`Task IOError String`, `Task Never Float`, `Task Never (List String)`) and
eta-free aliasing defs, so `isInertType` ought to accept them. They reach the
boundary through `deriveKernelAbiTypeRef`, the STANDALONE-reference path, whose
own doc says the type is loaded through the ITEM memo "so the item's demand
concretization (unified against the enclosing definition's annotation) is
visible — a fresh instantiation would isolate the vars and lose it". That is
the tell: on this path the concrete truth lives in the STORE, while
`licenseApplies` inspects the raw `Can.Type`, which can still be a synthetic
placeholder variable. A `TVar` is function-capable, so the license is refused.

Two ways to close it, both cheap, neither done:

1. **Annotate them** (`Eco.Runtime.dirname : Task Never String`, etc.). A
   `CForeign` equates the node's var with the annotation, so `meta.tipe` becomes
   concrete and the existing `Inert` rows apply. Consistent with everything
   above, and it is the mechanism this plan exists to provide.
2. **Verify against the store zonk on the standalone-reference path** rather
   than the raw canonical type. More general — it would fix every standalone
   reference at once rather than kernel by kernel — but it changes
   `licenseApplies`'s interface from a pure `Can.Type` predicate to something
   store-aware, which is a bigger change than the five boundaries justify today.

Recorded rather than fixed: five boundaries is below the threshold at which
either change earns its battery, and option 2 in particular deserves its own
measurement (how many standalone references are there in total?) before being
built. The census now names the population, so this is a decision with data
behind it rather than a guess.

---

# EXECUTION RECORD — the five eco refusals (2026-08-20)

Asked to annotate the five eco IO kernels Run AA's census named. The
annotations were written, and then **measurement said they were not the fix**.

## What actually happened

The five (`Console.readLine`, `Env.rawArgs`, `File.getCwd`, `Runtime.dirname`,
`Runtime.random`) were annotated from their real kernel types — which required
care: `readLine` is NOT `Task IOError String`, because its def is
`Eco.Kernel.Console.readLine |> Task.mapError IOErr.ofKernelTuple`, so the
enclosing annotation describes the MAPPED task. `ofKernelTuple : (Int, String,
String) -> IOError` fixes the kernel's own error type. That is §3 H2 exactly,
caught before it landed.

With the rows in place and the kernels genuinely reachable, **all five were
still refused.** (The first probe appeared to pass only because its task value
was never used from `main` and was tree-shaken before monomorphization — a
probe that measures nothing looks identical to a probe that passes.)

## The real cause was a bug in the verifier, not a missing annotation

`Task Never String` canonicalizes to a **`Holey` alias**: body
`Platform.Task x a`, args `[(x, Never), (a, String)]`. `hasFunctionCapable`'s
`TAlias` arm walked BOTH the args and the body — and the body's `x`/`a` are the
alias's PARAMETERS, placeholders for the args, not free variables. So every
parameterised alias was judged function-capable, and these five concrete types
were refused.

Fixed by walking the body with the parameters treated as non-capable (their
real content is already counted through `args`), which keeps genuine
body-arrows caught: `type alias Handler a = a -> Int` is still capable.
Regression pin added (KernelLicenseTest 9c) covering all three directions.

## And then the annotations were REMOVED

A/B with the intrinsics table disabled but the alias fix kept:
`byKernel=17 kernelLicensed=10 REFUSED=Console.readLine=1` — **byte-identical
to the arm with the five rows in.** They contributed nothing: those kernels'
occurrence types were already solved by their eta-free alias defs, and only the
`Holey` bug was refusing them. Keeping them would have meant five fail-stop
liabilities — five more ways for a future eco signature change to break the
build — for zero measured benefit. Removed.

**The lesson generalises past this instance:** a refusal census names the
SYMPTOM, and the fix is not automatically the mechanism you just built. Four of
five were a verifier bug; annotating them would have "worked" while hiding it,
and would have left every other parameterised alias still refused.

## Status

| probe | byKernel / kernelLicensed | refused |
|---|---|---|
| `Base` (control) | 2 / 1 | none |
| `UsesJson` | 5 / 6 | none |
| `UsesSplit` | 2 / 8 | none |
| `Wide` | 24 / 47 | none |
| `EcoIO` | 17 / 10 | `Console.readLine=1` |

`Console.readLine` remains refused, identically with and without an annotation,
so its cause is a third thing — not the alias bug and not a missing type.
One boundary; cause not established; recorded rather than guessed at.

Gates: `--target full` 1685/1685; elm-tests 13,156 / same 12 pre-existing;
KernelLicenseTest 16; rot guard green. No new benchmark row — the alias fix
lands after Run AA and its self-compile effect is unmeasured; it should be
folded into the next row rather than given a same-day one.
