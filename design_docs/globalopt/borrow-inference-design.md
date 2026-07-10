# Automatic Borrow Inference in Eco — Detailed Design

*Status: DETAILED DESIGN v1 (2026-07-10). Supersedes the v0 outline (same
file, same date). Code references verified against the tree as of MonoSolver
runtime parity: `Compiler/AST/Monomorphized.elm`,
`Compiler/GlobalOpt/{MonoGlobalOptimize,AbiCloning,Staging,MonoInlineSimplify}.elm`,
`Compiler/Generate/MLIR/{Expr,Ops,Context}.elm`, `Mlir/Mlir.elm`,
`Compiler/Monomorphize/{KernelAbi,MonoTraverse}.elm`, `Compiler/Graph.elm`,
`Builder/Generate.elm`, `Builder/Eco/Config.elm`, `Compiler/Eco/Config.elm`,
`runtime/src/codegen/{Ops.td,EcoPipeline.cpp,Passes/RCElimination.cpp,Passes/EcoToLLVMHeap.cpp,RuntimeSymbols.cpp}`,
`runtime/src/allocator/{Heap.hpp,HeapHelpers.hpp,AllocatorCommon.hpp,Allocator.hpp,NurserySpace.cpp}`.*

*Basis: Brandon, Driscoll, Dai, Ragan-Kelley, Milano, Aiken —
"Fully-Automatic Type Inference for Borrows with Lifetimes" (OOPSLA 2026),
`design_docs/auto-borrow-inference/full-auto-type-inf-borrow-lifetimes.pdf`
("the paper"). Companions: the LSS design
(`design_docs/monomorphization/lambda-set-specialization-design.md`, whose
§9.4 names borrow inference as consumer M6), the solver-reuse evaluation
(`design_docs/monomorphization/solver-reuse-evaluation.md`), and the Roc
Perceus study (`design_docs/perceus_gc/`).*

---

## 0. Decision summary — what changed from the v0 outline

Verifying the v0 outline against the code forced five revisions and resolved
seven of its nine open questions.

**DS1 — The pass does *not* reuse `Type.Unify`/`Type.UnionFind`.** v0's reuse
map assigned "the equality-constrained subset" to the HM unifier. That was
wrong at this pipeline position: after monomorphization every type is a
ground `MonoType` (`Monomorphized.elm:202`) — there are no type variables to
unify (`MVar _ CEcoValue` is an *erased opaque* type, not an inference
variable). The only inference objects are the pass's own resource variables,
which are dense `Int`s. Equality constraints are handled by a ~80-line
dedicated union-find (`Borrow/Dsu.elm`, §3.2), and structural constraint
broadcast is a deterministic zip of ground types — no `FlatType`, no store.
What *is* inherited from the MonoSolver work is the architecture pattern
(per-item scope, memoized identity, staged fixpoints, worklist + registry,
A/B + census gating discipline) and shared utilities (`Compiler.Graph` SCCs,
`Compiler.Data.BitSet`).

**DS2 — Zero `MonoType` blast radius.** Unlike LSS (whose annotation must
ride `MonoType` through mono, costing a 159-site sweep — LSS §5.2), borrow
inference runs entirely inside one GlobalOpt pass. The annotated type `RTy`
(§3.3) is pass-internal. The *only* AST change is two new `MonoExpr`
constructors added at reification (§7.2), touching the 13 files that
pattern-match `MonoExpr` (list in §7.2) — and only 2 of them non-trivially.

**DS3 — Pipeline position: Phase 6 of `globalOptimize`, after
`annotateCallStaging`.** v0 said "last GlobalOpt family pass"; the code pins
it precisely: after Phase 5 (`MonoGlobalOptimize.elm:131`) so that `CallInfo`
(`callKind`, staging arities) is already stamped and available to the
analysis, and so no later Mono pass observes the new constructors.

**DS4 — ANF is not needed (v0 OQ2 resolved).** The paper wants ANF because
its borrowing decisions attach to variable occurrences. In eco's nested IR
the same effect falls out structurally: dups/borrows/moves attach only to
`MonoVarLocal`/`MonoVarGlobal` occurrences and to projection results; a
*non-variable* operand is a freshly constructed value whose single consumer
receives it by move — zero RC ops by construction. No normalization pass.

**DS5 — v1 interprocedural model: one borrow signature per `SpecId`,
no mode cloning.** Mode specialization (paper §6.2) requires function
cloning; `AbiCloning.abiCloningPass` is a stub (`AbiCloning.elm:39`) and LSS
M3 is scheduled to build the first real cloning machinery. v1 therefore
computes a single signature per specialization and *measures* poisoning
(counters for "param forced owned by minority of call sites", §6.1); v2 adds
cloning on the AbiCloning substrate (§6.2). Closure boundaries and kernels
default to all-owned in v1 (§4.3–§4.4, §11), upgraded later by LSS `LSet`
facts (LSS §9.4) and the audited kernel table.

**DS6 — The copying-nursery insight narrows where RC pays.** The nursery is
a copying space: dead nursery objects cost *nothing* at minor GC (only live
objects are evacuated), so an early `drop`/`free` of a nursery object buys
no memory back. There is also **no per-object free API** in the allocator —
deallocation exists only as old-gen sweep into `Tag_Free` segregated free
lists (HEAP_021/023; the one mid-cycle precedent is `freeLargeBodyCell`,
HEAP_027). Consequently RC reification pays only for (a) **RC-1 in-place
mutation decisions** and (b) **old-gen / pinned objects** — most notably
large string/byte bodies, which are *already* pinned in old gen and
individually reclaimed (HEAP_026). This sharpens option B (v0 §3) to:
**counts on pointer-free flat buffers first** (ByteBuffer, string leaf/body
forms), arrays second. Dup *elision* remains valuable everywhere counts are
maintained; where none are maintained, the analysis still yields static
uniqueness and statistics.

**v0 open questions — disposition:**

| v0 OQ | Disposition |
|---|---|
| 1 runtime strategy A/B/C | Still M0's call, but mechanism fixed: `rcManaged` predicate (§9.1) + stats-first milestones; provisional lean narrowed by DS6 |
| 2 ANF | Resolved — not needed (DS4) |
| 3 reification target | Resolved — Mono constructors carry, existing dialect ops emit (§7.2, §8) |
| 4 mode-spec keys vs LSS keys | Deferred to v2 (§6.2), sized by B2 counters |
| 5 drop-sliding vs safepoints | v1: drops at scope end only, helpers are GC-leaf (§9.4); sliding deferred |
| 6 user escape hatch | Deferred (post-v2) |
| 7 skeleton extraction | Resolved — §3.4 frame classification |
| 8 RC-1 targets under barrier-free GC | Narrowed — pointer-free buffers v1 (§10 S6, DS6) |
| 9 mutation-aware mode heuristic | Deferred to v2; B2 emits the sizing counters |

---

## 1. Objective and scope

Infer, per specialization, an ownership discipline for heap values: each
heap-typed binding and occurrence gets a **mode** — owned (`•`) or borrowed
(`&⟨L⟩`) with a static **lifetime** — such that borrowed handles compile to
nothing, owned final uses compile to moves (nothing), owned non-final uses
compile to `eco.incref`, and unmoved owned bindings compile to `eco.decref`
(or `eco.free` when statically unique) at the end of their precise lifetime.
Programs the discipline cannot type are completed with dups, never rejected.

Deliverables in dependency order: **(1)** the analysis (modes + lifetimes +
signatures) with a census report — valuable stand-alone as a static
uniqueness/sharing oracle; **(2)** reification to the dialect's existing RC
ops behind a flag; **(3)** the runtime RC path scoped by `rcManaged`;
**(4)** RC-1 in-place mutation for the scoped buffer types.

**Non-goals (v1):** exclusive/mutable borrows; Perceus reuse
(`eco.reset`/`eco.reset_ref` stay reserved); mode specialization (v2, §6.2);
drop-sliding; the user-facing dup escape hatch; multi-threaded RC.

---

## 2. Pipeline position and configuration

### 2.1 Insertion point

`Builder/Generate.elm` is untouched: `runGlobalOptPhase`
(`Generate.elm:780-788`) already wraps `MonoGlobalOptimize.globalOptimize`
in `FEStats.PhaseGlobalOpt`. The pass becomes Phase 6 inside
`globalOptimize` (`MonoGlobalOptimize.elm:108-132`):

```elm
-- MonoGlobalOptimize.elm (Phase 5 tail today):
--     annotateCallStaging stagingSolution.dynamicSlots graph4
-- becomes:
    let
        graph5 =
            annotateCallStaging stagingSolution.dynamicSlots graph4
    in
    -- Phase 6: borrow inference (analysis always-on when enabled;
    -- reification per borrowConfig.reify). Runs LAST: no other Mono
    -- pass ever observes MonoRcDup/MonoRcDrop (BORROW_002).
    Borrow.run borrowConfig graph5
```

`globalOptimize` gains the config parameter
(`globalOptimize : Config.BorrowConfig -> Mono.MonoGraph -> Mono.MonoGraph`);
`runGlobalOptPhase` threads `ecoConfig` (it already has it in scope one
frame up — `runInlineSimplifyPhase` consumes `ecoConfig.inline` the same
way, `Generate.elm:768`).

Rationale for after-Phase-5: (a) `CallInfo.callKind`
(`CallDirectFlat`/`CallDirectKnownSegmentation`/`CallGenericApply`,
`Monomorphized.elm:1147`) tells the walker which call boundaries are
direct-known vs closure-generic without re-deriving staging; (b) staging
wrappers and closure normalization are final, so occurrence structure is
stable; (c) `MonoInlineSimplify` has already run
(`Generate.elm:762-776`), maximizing borrowable occurrences.

### 2.2 Config surface

`Compiler/Eco/Config.elm` (pattern: `MonoConfig`, `Config.elm:49-64,154-182`):

```elm
type BorrowReify
    = ReifyOff      -- analysis + census only (B2/B3 default)
    | ReifyRc       -- emit MonoRcDup/MonoRcDrop → eco.incref/decref/free


type alias BorrowConfig =
    { enabled : Bool          -- master gate; False ⇒ Phase 6 is identity
    , reify : BorrowReify
    , report : Bool           -- census to stderr at end of pass
    }


borrowDecoder : D.Decoder x BorrowConfig
borrowDecoder =
    D.pure BorrowConfig
        |> D.apply (D.optionalField "enabled" D.bool False)
        |> D.apply (D.map reifyFromString (D.optionalField "reify" D.string "off"))
        |> D.apply (D.optionalField "report" D.bool False)
```

`EcoConfig` gains `borrow : BorrowConfig` (`Config.elm:32-37`). Env
overrides in `Builder/Eco/Config.elm` beside `ECO_MONO_ENGINE`
(`Builder/Eco/Config.elm:89-93`): `ECO_BORROW=1`, `ECO_BORROW_REIFY=rc`,
`ECO_BORROW_REPORT=1`. Default `enabled = False` ⇒ byte-identical pipeline
(the LSS "every knob's fallback is off" discipline, LSS §10).

### 2.3 Module map (all new, under `Compiler/GlobalOpt/Borrow/`)

| Module | Contents | ~lines |
|---|---|---|
| `Borrow.elm` | `run : BorrowConfig -> MonoGraph -> MonoGraph`; SCC driver; census | 250 |
| `Borrow/Rty.elm` | `RTy`, `freshRTy`, ground-type zip, `rcManaged` | 250 |
| `Borrow/Lifetime.elm` | `Path`, `Life`, `Lifetime`; `join`, `leq`, `endsBefore (≺)`, `onBoundary (≍)` | 250 |
| `Borrow/Dsu.elm` | Int union-find (path compression, Dict-backed) | 80 |
| `Borrow/Constrain.elm` | the per-def constraint-generation walk (§4) | 600 |
| `Borrow/Solve.elm` | staged fixpoints + worklist propagation (§5) | 300 |
| `Borrow/Sig.elm` | `BorrowSig`, kernel table hook, sig fixpoint (§5.5, §11) | 200 |
| `Borrow/Reify.elm` | occurrence classification → `MonoRcDup`/`MonoRcDrop` insertion (§7) | 400 |
| `Borrow/KernelSigs.elm` | audited kernel borrow signatures + all-owned default (§11) | 150 + data |

---

## 3. Analysis data model

### 3.1 Resource variables

```elm
type alias ResVar =
    Int   -- dense, minted per heap position per def-analysis; DSU quotients them
```

One `ResVar` per heap position (not two): the paper tracks `storage(𝔯)` and
`access(𝔯)` as two lattice maps over one variable set (its Fig. 7 `fresh` /
`fresh-heap` mark which one is `primary`). We mirror that: `Solve.State`
keeps `access : Array Mode`, `ltA/ltP : Array Lifetime` indexed by DSU root,
and storage modes *are* the DSU classes joined with an `anyOwned` bit (§5.1).

### 3.2 Heap positions of a `MonoType`

From `Monomorphized.elm:202-214` and the REP invariants (only Int/Float/Char
are unboxed; Bool/Unit are embedded HPointer constants, never allocated —
REP_CONSTANT_001, HEAP_010):

| MonoType | Resource? | Notes |
|---|---|---|
| `MInt`, `MFloat`, `MChar` | no | unboxed scalars |
| `MBool`, `MUnit` | no | only embedded constants `0x4/0x5/0x6`; immortal |
| `MString` | yes | all six string forms (HEAP_025/032) behind one resource |
| `MList t` | yes + element resources | `Nil` is the Empty constant — runtime skip via `ptr_ind` (§9.4), resources still minted |
| `MTuple ts` / `MRecord fs` | yes + per-slot resources | precise interior |
| `MCustom home name args` | yes + per-*arg* resources | interior beyond args **collapsed** (§3.3) |
| `MFunction ps r` | yes (closure env) + param/result RTys | v1 poisoned at boundaries (§4.4) |
| `MVar _ CEcoValue` | yes | opaque erased box; interior unknown (§3.3) |
| `MVar _ CNumber` | no | resolved to MInt/MFloat before codegen (CGEN_013 sibling rule) |

### 3.3 `RTy` — the annotated type (pass-internal)

```elm
-- Borrow/Rty.elm
type RTy
    = RScalar                                        -- MInt/MFloat/MChar/MBool/MUnit/MVar CNumber
    | RString ResVar
    | ROpaque ResVar                                 -- MVar _ CEcoValue
    | RList ResVar RTy
    | RTuple ResVar (List RTy)
    | RRecord ResVar (List ( Name, RTy ))            -- sorted field order
    | RCustom ResVar (List RTy)                      -- type-arg positions only
    | RClosure ResVar                                -- env resource; param/result handled at boundaries


freshRTy : Mono.MonoType -> Gen -> ( RTy, Gen )     -- mints one ResVar per row above
zipRTy : RTy -> RTy -> List ( ResVar, ResVar )      -- structural pairing of GROUND shapes
```

Two deliberate precision cuts, both sound-by-conservatism:

- **`RCustom` interior collapse.** The paper's recursive-type rule already
  collapses all same-μ nested occurrences onto one mode ("the • on `rc a` is
  a statement about … all subsequent nested rc values", paper §5.2). v1
  extends the collapse to *all* non-type-arg interior of a custom: any
  projection out of a custom whose projected type is heap-typed gets its
  storage class merged with the custom's own class, and its access mode
  related by the vertical (get) rules. Per-ctor field precision (via
  `MonoGraph.ctorShapes`, `Monomorphized.elm:464`) is a v2 refinement with
  the same constraint shapes.
- **`ROpaque` (erased) flows.** Zipping `ROpaque r` against a concrete `RTy`
  pairs `r` with the concrete *top-level* resource and **forces every nested
  resource of the concrete side to owned** (interior identity is lost across
  the erased boundary). This is the erased-polymorphism analog of the
  paper's dup-completion; counted in the census as `poisonedByErased`.

`zipRTy` never fails on well-typed graphs (both sides derive from the same
ground `MonoType`); a shape mismatch is a compiler bug → `Debug.todo` crash
with both types (the MonoSolver "loud failure" policy,
`MonoSolver/Engine.elm:144-153`).

### 3.4 Lifetimes: paths, trees, and the skeleton

The paper's lifetimes generalize to eco's n-ary IR as follows
(`Borrow/Lifetime.elm`):

```elm
type Step
    = Seq Int Int          -- sequential child i of n (evaluation order)
    | Arm Int Int          -- alternative arm i of n (disjoint executions)


type alias Path =
    List Step              -- root-relative, function-local


type Life
    = Star                                  -- ends exactly here
    | InSeq Int Int Life                    -- ends within sequential child i of n
    | InAlts Int (Dict Int Life)            -- per-arm ends; missing arm = (— ∥ ℓ) case


type Lifetime
    = LEmpty                                -- unused
    | LLocal Life
    | LParams (Set Int)                     -- ⊔ of param-position lifetime vars α;
                                            --   ordered after all LLocal (paper §5.1)


join : Lifetime -> Lifetime -> Lifetime
-- LEmpty ⊥ ; LParams s ⊔ LParams t = LParams (union s t)
-- LLocal ⊔ LParams s = LParams s          -- α ≥ every local lifetime
-- LLocal: InSeq i _ ⊔ InSeq j _ = keep the LATER index, recurse on tie
--         InAlts   ⊔ InAlts     = pointwise arm join


leq : Lifetime -> Lifetime -> Bool          -- L ≤ L' : every branch covered
endsBefore : Lifetime -> Path -> Bool       -- L ≺ p : no branch of L contains p
onBoundary : Lifetime -> Path -> Bool       -- L ≍ p : p coincides with a branch
```

**Skeleton classification** — which `MonoExpr` children are `Seq` vs `Arm`
(from the constructor list at `Monomorphized.elm:579-598`):

| Node | Frame |
|---|---|
| `MonoLet def body` | `Seq 0 2` = RHS, `Seq 1 2` = body |
| `MonoCall f args` | `Seq` over `f :: args` (left-to-right evaluation) |
| `MonoIf pairs else` | desugared to nested binary ifs: each `(cond, branch)` contributes cond at `Seq 0 2`, then `Arm 0 2` = branch / `Arm 1 2` = rest |
| `MonoCase _ _ decider jumps` | decider tests are reads at the case's own path (no frame); alternation `Arm i n` where the arms are: each *inline* `Leaf` once, each jump-table entry **once** (a `Jump j` from several decider leaves targets the same arm — join point, arity n = #inline + #jumps) |
| `MonoDestruct d body` | `Seq 0 2` = the projection read, `Seq 1 2` = body |
| `MonoTupleCreate` / `MonoList` / `MonoRecordCreate` / `MonoRecordUpdate` | `Seq` over element/field exprs |
| `MonoClosure info body` | captures are `Seq` positions at the creation site; `body` is a *separate function* (own skeleton) |
| `MonoTailCall _ args` | `Seq` over args; see tail rule §4.5 |
| leaves (`MonoLiteral`, `MonoVarLocal`, `MonoVarGlobal`, `MonoVarKernel`, `MonoUnit`, `MonoAccessorValue`) | occurrence point = current path |

Termination: for a fixed def, all lifetimes are trees over that def's finite
skeleton — a finite lattice; every solver update is a join; Kleene iteration
terminates (paper §4.4's argument verbatim).

### 3.5 Constraints and occurrences

```elm
-- Borrow/Constrain.elm
type alias Constraints =
    { flows : List ( ResVar, ResVar )        -- bind → use (lateral; paper I-Use)
    , gets : List Get                        -- container read (paper I-Get)
    , storageEq : List ( ResVar, ResVar )    -- nested/heap-storage equalities
    , scopes : Dict ResVar Path              -- binding resource → its scope path (I-Let)
    , seeds : List ( ResVar, Path )          -- ltA/ltP ≥ p (reads, borrowed-call args)
    , forcedOwned : List ( ResVar, Reason )  -- construction / kernel / closure / erased
    , occs : List Occ                        -- reification records
    }


type alias Get =
    { container : ResVar, out : List ( ResVar, ResVar ), path : Path }
    -- out = (containerInterior, projected) pairs: vertical-flow candidates


type alias Occ =
    { occId : Int
    , binder : Name                          -- MonoVarLocal it refers to
    , path : Path
    , res : List ResVar                      -- top-level resources of the occurrence RTy
    }


type Reason
    = RConstruct | RKernel | RClosureBoundary | RErased | RPort | RTailArg
```

---

## 4. Constraint generation (`Borrow/Constrain.elm`)

### 4.1 Walker shape

Direct recursion in the Design-B style (no DSL), threading:

```elm
type alias Env =
    { vars : Dict Name RTy                   -- binding → its RTy (binding side)
    , sigs : SpecId -> Maybe BorrowSig       -- current signature table (§5.5)
    , kernels : ( Name, Name ) -> KernelSig  -- §11; total via all-owned default
    }


constrainExpr : Env -> Path -> Mono.MonoExpr -> Gen -> ( RTy, Gen )
-- Gen threads the ResVar supply + accumulating Constraints.
```

Every `MonoExpr` carries its `MonoType` (`Mono.typeOf`,
`Monomorphized.elm:790`), so `freshRTy` is always available for
result/boundary minting.

### 4.2 Per-constructor rules

| Constructor | Constraints emitted |
|---|---|
| `MonoLiteral (LStr _)` | fresh `RString r`; `forcedOwned` **omitted**: interned literals are immortal — mint `r` but mark `immortal` (census; reify skips) |
| other `MonoLiteral` | `RScalar` |
| `MonoVarLocal x` | look up binding RTy; mint use RTy (`freshRTy`); `flows` bind→use pairwise (`zipRTy`); `storageEq` on all *nested* pairs (heap-storage rule, paper §3.3); record `Occ` |
| `MonoVarGlobal _ specId` | zero-arity value: treat as call §4.3 with 0 args; function reference: `RClosure` fresh, `forcedOwned RClosureBoundary` on captured side only (none) |
| `MonoVarKernel _ p home name` | kernel *value* (not call): `RClosure` fresh, boundary-poisoned |
| `MonoList es` / `MonoTupleCreate` / `MonoRecordCreate` | constrain elements; result fresh; element-use resources `storageEq` with the container's slot resources; container top `forcedOwned RConstruct` (paper I-Rc: new value needs an owner) |
| `MonoRecordUpdate base fields` | constrain base (a read: `gets` on base at this path) + fields; result fresh, `forcedOwned RConstruct`; copied-over fields = vertical `Get.out` pairs base→result slots (they are *new references* to old field values) |
| `MonoRecordAccess e f` | constrain `e`; `gets { container = top(e), out = [(slot f, fresh)], path }`; `seeds` on container top |
| `MonoDestruct (MonoDestructor x path) body` | root var's resource: `seeds` at `Seq 0 2`; `gets` with `out` per projected heap position; bind `x` to projected RTy; constrain body at `Seq 1 2`; `scopes` for `x`'s resources = `Seq 1 2` path |
| `MonoCase root _ decider jumps` | decider tests: `seeds` on `root`'s resource chain at the case path (tests read tags/fields); each arm constrained at `Arm i n`; arm results zipped to fresh case-result RTy (`flows` + branch-unification: same rules as `MonoVarLocal` zip both directions ⇒ effectively `storageEq` + access joins) |
| `MonoIf pairs else` | conds/branches per skeleton; branch results zip to fresh result as for case |
| `MonoLet (MonoDef x rhs) body` | constrain rhs at `Seq 0 2`; bind `x`; `scopes(res(x)) = Seq 1 2`; constrain body |
| `MonoLet (MonoTailDef x params rhs) body` | local tail function: analyzed as nested def (own skeleton), signature all-owned v1 (`RClosureBoundary`) |
| `MonoCall f args _ callInfo` | §4.3 |
| `MonoTailCall _ args` | args constrained; every arg occurrence `seeds` **escape** (tail rule §4.5) + flows into the SCC signature params |
| `MonoClosure info body` | §4.4 |
| `MonoAccessorValue` | function value → boundary-poisoned `RClosure` |
| `MonoUnit` | `RScalar` |

`MonoNode` kinds (`Monomorphized.elm:530-538`): `MonoDefine`/`MonoTailFunc`
are the per-def entry points; `MonoCtor`/`MonoEnum`/`MonoExtern`/
`MonoManagerLeaf`/`MonoPortIncoming`/`MonoPortOutgoing` are boundary nodes —
ctor wrappers get the construct rule; ports/extern/manager leaves poison
their whole signature (`RPort`), matching the LSS kernel/port boundary
treatment (LSS §7.5).

### 4.3 Call boundaries

Dispatch on the callee expression + `callInfo.callKind`
(`Monomorphized.elm:1147`, values per `computeCallInfo`,
`MonoGlobalOptimize.elm:1910`):

- **Direct call to `MonoVarGlobal specId`** (`CallDirectFlat` /
  `CallDirectKnownSegmentation`, single-stage saturated): fetch
  `BorrowSig` for `specId` (§5.5). Zip each arg RTy against the sig's param
  RTy:
  - param resource **Owned** → arg occurrence is an owned use: `flows`
    bind→param-instance; nested `storageEq`;
  - param resource **Borrowed** → the arg must be live for the call:
    `seeds (argRes, callPath)`; *no* ownership transfer;
  - result: `freshRTy`; for each result resource whose sig lifetime is
    `LParams s`, add `flows argRes → resultRes` for every param position in
    `s` (this reproduces the paper's §5.1 argument–return coupling and
    makes the caller's ltA/ltP propagation see through the call).
- **Kernel call** (callee `MonoVarKernel`): as above with
  `KernelSig` from `Borrow/KernelSigs.elm` (§11). Default all-owned = the
  Perceus baseline for that call.
- **Closure/generic** (`CallGenericApply`, `CallSegmentationUnknown`,
  multi-stage PAP chains): v1 poisons — every arg `forcedOwned
  RClosureBoundary`, result fresh all-owned. Census counter
  `poisonedByClosure` sizes the cost; LSS `LSet` singletons (LSS §9.2/§9.4)
  later upgrade exactly this branch by routing to the member's `BorrowSig`.
- **Under/over-application** (partial application, `Types.isFunctionType
  resultType` route in `generateCall`, `Expr.elm:1276`): args are captured
  into a PAP heap object → same as closure capture: `forcedOwned`.

### 4.4 Closures and captures

`MonoClosure info body` (`ClosureInfo`, `Monomorphized.elm:618`): captures
`List ( Name, MonoExpr, Bool )` are stores into a heap closure environment.
v1 rule: each captured heap resource is `forcedOwned RClosureBoundary`
(closure env lifetime unknown to local analysis), nested `storageEq` with
the env's interior; the body is analyzed as its own function with all-owned
params/result. This is sound and matches what the paper's system would do
with ⊤ closure knowledge; the census (`poisonedByClosure`,
`capturesForcedOwned`) quantifies what LSS-M6 integration will recover.

### 4.5 Tail calls

Per the paper §6.3: setting tail-call argument *modes* to owned would be
wrong; instead their occurrences are treated as **escaping during ltA** —
`seeds` each arg resource with a path ordered after the whole body — which
lets borrows-from-outside-the-SCC survive while preventing reification from
placing drops after the tail call (which would break TCE in the backend's
tail-call emission, `MonoTailCall`/`MonoTailFunc` looping).

---

## 5. Solving (`Borrow/Solve.elm`)

Four stages per SCC iteration; all maps are `Array`s indexed by DSU root.

### 5.1 Stage A — storage classes

Union in `Dsu`: all `storageEq` pairs **and all `flows` pairs** (the paper's
Fig. 8 storage rules are a bidirectional `≥` pair, i.e. equality along every
flow edge). Each class carries one bit `storageOwned`, set by `forcedOwned`
members; a class containing any owned-forced resource stores owners.

### 5.2 Stage B — approximate lifetimes (`ltA`)

Seeds from `seeds`; propagate along `flows` in the **bind ≥ use** direction:

```elm
solveLtA : Array (List Int) -> Array Lifetime -> Array Lifetime
solveLtA predsOf lt0 =
    -- worklist of DSU roots; pop u, for each bind b with flow(b, u):
    --   new = Lifetime.join (get b) (get u)
    --   if new /= get b then set + push b
    -- terminates: finite lattice per def (§3.4)
```

### 5.3 Stage C — access modes

For every flow edge `(b, u)` on class roots:

- `access(b) := access(b) ⊔ access(u)` (owned occurrence ⇒ owned binding —
  the paper's rule (2), which converts would-be `dup(&x)` into moves);
- if `not (Lifetime.endsBefore (ltA u) (scope b))` — the occurrence escapes
  the binding's scope — then `access(u) := access(u) ⊔ access(b)` (rule (1)).

Plus: `forcedOwned` roots start Owned; `gets` impose
`access(interior) = access(projected)` (paper get-constr). Iterate to
fixpoint (two-point lattice ⇒ ≤ 2 passes per edge in practice).

### 5.4 Stage D — precise lifetimes (`ltP`)

Same seeds; propagate along:

- **lateral-flow**: flow edges whose use side is Borrowed (`access(u) = &`);
- **vertical-flow**: `Get.out` pairs where the container interior is Owned
  and the projected value is Borrowed (the get's output borrows the
  container ⇒ container must outlive it — the paper's surprising
  "approximate lifetimes are not conservative for drops" case).

`ltP` is what reification consults for moves and drop placement.

### 5.5 Interprocedural fixpoint

```elm
-- Borrow/Sig.elm
type alias BorrowSig =
    { params : List SigTy            -- RTy shape + solved Mode per position
    , result : SigTy
    , resultLts : List ( ResPos, Set Int )   -- result position → LParams set
    }
```

Driver (`Borrow.run`):

1. Recompute call edges by folding over the pruned graph
   (`MonoTraverse.foldExpr` collecting `MonoVarGlobal` SpecIds per def) —
   `MonoGraph.callEdges` (`Monomorphized.elm:487`) is mono-time truth that
   `MonoInlineSimplify` may have stale-ified; a fresh fold is one cheap pass.
2. `Compiler.Graph.stronglyConnCompInt` (`Graph.elm:38`) over SpecId edges;
   process SCCs in reverse topological order (callees first).
3. Per SCC: initialize member sigs optimistically (params Borrowed with
   fresh α, results `LParams ∅`); run §4 + §5.1-5.4 for each member;
   read back sigs from solved param/result resources; repeat until sigs
   stable. Modes only ever go `& → •` and lifetime sets only grow ⇒
   monotone on a finite lattice ⇒ terminates.
4. Acyclic SCCs solve in one iteration.

### 5.6 Complexity

Per def: minting O(type sizes), edges O(occurrences × type width), each
fixpoint O(edges × lattice height); lattice height for `Life` is bounded by
expression depth. Whole-program: SCC iteration count bounded by the longest
mode/lifetime-set chain in a signature — in practice 2–3. Benchmarked at B2
against the self-compile (§13); the elm-aws-codegen pathological input is
the canary (deep let chains from the inliner — the GlobalOpt staging
incident's lesson).

---

## 6. Signatures, poisoning, and mode specialization

### 6.1 v1: one signature per SpecId — measured poisoning

A single ownership-demanding call site drags a param to Owned for all
callers (paper §6.2's poisoning). v1 accepts this and **counts it**: for
each param forced Owned, the census records how many call sites demanded
Owned vs would have accepted Borrowed (`poisonedParams`,
`poisoningCallSites`). This directly sizes v2's win before any cloning code
is written.

### 6.2 v2 sketch: mode specialization on the AbiCloning substrate

When LSS M3 lands real cloning in `AbiCloning.elm` (LSS §9.2), mode
specialization reuses it: clone = copy the `MonoNode`, allocate a fresh
`SpecId` via `registry.nextId` (`Monomorphized.elm:438-448` — the
`mapping : Dict String SpecId` key gains a mode-signature suffix, the exact
analog of LSS §5.3's key extension), rewrite `MonoVarGlobal` SpecIds at the
demanding call sites, re-run Phase-5 `annotateCallStaging` on the clones.
Merge rule from the paper: clones whose modes induce identical RC ops
collapse to one. Deferred entirely out of v1; the analysis output (§5.5
sigs + per-call demands) is its complete input.

---

## 7. Reification (`Borrow/Reify.elm`)

### 7.1 The decision table (normative)

Elision is not emit-then-delete: reification is the only producer of RC
ops, choosing the zero-op lowering wherever the solved facts allow. The
soundness transfer: the refcount tracks *owners only*; a borrow is
bit-identical to the owner's HPointer and invisible to the count — its
safety is discharged statically by lifetime containment, not dynamically.

| Solved facts at a site | Emitted |
|---|---|
| Occurrence mode `&` | **nothing** |
| Occurrence `•`, `ltP` ends here (last use on path) | **nothing** — move |
| Occurrence `•`, value needed later | `MonoRcDup` (→ `eco.incref`) |
| Borrowed binding leaves scope | **nothing** |
| Owned unmoved binding's `ltP` ends | `MonoRcDrop` (→ `eco.decref`) |
| …and zero dups reach its class (static unique) | drop strengthens to `eco.free` |
| resource not `rcManaged` (§9.1), or immortal | **nothing** (census only) |

### 7.2 Two new `MonoExpr` constructors

```elm
-- Monomorphized.elm, appended to MonoExpr (:598)
    | MonoRcDup MonoExpr MonoType
      -- evaluate inner; increment its top-level rcManaged resources; value = inner
    | MonoRcDrop (List ( Name, DropKind )) MonoExpr MonoType
      -- evaluate inner; then decref/free the named in-scope bindings; value = inner


type DropKind
    = DropDec        -- eco.decref
    | DropFree       -- eco.free (statically unique)
```

`Mono.typeOf` gains the two arms (both return the carried type). Produced
only by Phase 6 (BORROW_002); never serialized (MonoGraph is per-build,
in-memory only). **Blast radius** — the 13 files matching `MonoExpr`
constructors (grep-verified): `AST/Monomorphized.elm` (decl + `typeOf`),
`Monomorphize/{MonoTraverse,Closure,Analysis,Specialize,ResolveAccessorValues}.elm`,
`GlobalOpt/{MonoInlineSimplify,MonoGlobalOptimize}.elm`,
`MonoSolver/{Translate,Diff}.elm`,
`Generate/MLIR/{Expr,BytesFusion/Emit,BytesFusion/Reify}.elm`. Only
**MonoTraverse** (recurse-through arms) and **Generate/MLIR/Expr** (emission,
§8.2) are non-trivial; all pre-Phase-6 files get
`Debug.todo "MonoRc* before borrow pass"` arms — loud, unreachable, and
Elm's exhaustiveness checking guarantees none is forgotten.

### 7.3 Placement rules

- **Dups** wrap the classified occurrence expression in place (the `Occ`
  records carry the tree position).
- **Drops** attach at scope ends only (v1, no sliding): a `MonoLet` whose
  binder's resources are Owned-unmoved wraps its body:
  `MonoLet d (MonoRcDrop [(x, k)] body t) t`. Case/if arms that move a
  binding on a sibling arm but not locally get the balancing drop in the
  non-moving arm (the paper's reification rule for `if`), placed by
  comparing per-arm move sets.
- **Tail calls**: §4.5's escape seeds guarantee no binding's `ltP` ends
  after a `MonoTailCall`, so no drop is ever placed behind one.

### 7.4 Worked example

```elm
count : String -> List String -> Int
count w xs = case xs of
    [] -> 0
    x :: rest -> (if x == w then 1 else 0) + count w rest
```

All-owned (Perceus-mode, `KernelSigs` default + sigs constrained Owned)
reifies per element roughly `incref x; incref rest; decref xs; decref x` —
four count mutations. With inference: `count`'s sig solves to
`w : & , xs : &⟨α⟩ List (• String)`, the recursion re-borrows, equality is
a borrowing kernel (`Utils.equal` reads only) — **zero RC ops in the
loop**; the caller keeps one ownership and emits a single drop (or
`DropFree` if the list is local and never shared) after its last use.

---

## 8. MLIR emission

### 8.1 New op builders (`Generate/MLIR/Ops.elm`)

Modeled on the zero-result `ecoReturn` (`Ops.elm:525-535`); the ops already
exist in the dialect (`runtime/src/codegen/Ops.td:2760,2776`):

```elm
ecoIncref : Ctx.Context -> String -> Int -> ( Ctx.Context, MlirOp )
ecoIncref ctx operand amount =
    mlirOp ctx "eco.incref"
        |> opBuilder.withOperands [ operand ]
        |> opBuilder.withAttrs
            (Dict.fromList
                [ ( "_operand_types", ArrayAttr Nothing [ TypeAttr Types.ecoValue ] )
                , ( "amount", IntAttr (Just I64) amount )
                ]
            )
        |> opBuilder.build


ecoDecref : Ctx.Context -> String -> ( Ctx.Context, MlirOp )   -- same, name "eco.decref"
ecoFree   : Ctx.Context -> String -> ( Ctx.Context, MlirOp )   -- same, name "eco.free"
```

### 8.2 `generateExpr` arms (`Generate/MLIR/Expr.elm:345`)

```elm
Mono.MonoRcDup inner _ ->
    let
        r = generateExpr ctx inner
        ( ctx2, op ) = Ops.ecoIncref r.ctx r.resultVar 1
    in
    { r | ops = r.ops ++ [ op ], ctx = ctx2 }

Mono.MonoRcDrop targets inner _ ->
    let
        r = generateExpr ctx inner

        emitOne ( name, kind ) ( accCtx, accOps ) =
            case Ctx.lookupVar accCtx name of
                Just info ->
                    let
                        ( c2, op ) =
                            case kind of
                                Mono.DropDec  -> Ops.ecoDecref accCtx info.ssaVar
                                Mono.DropFree -> Ops.ecoFree accCtx info.ssaVar
                    in
                    ( c2, accOps ++ [ op ] )

                Nothing ->
                    -- BORROW_004: drop target must be an in-scope binding
                    Debug.todo ("MonoRcDrop: unbound " ++ name)

        ( ctx2, dropOps ) = List.foldl emitOne ( r.ctx, [] ) targets
    in
    { r | ops = r.ops ++ dropOps, ctx = ctx2 }
```

Both are structurally value-transparent: `resultVar`/`resultType` pass
through, so surrounding emission (calls, staging chains, case yields) is
untouched. Drops emit *before* the value flows onward, matching Mono-level
placement (the wrapped `inner` is the scope body whose result is returned).
The drop's SSA name lookup uses the same `varMappings` scoping machinery
that let-binding emission maintains (`Expr.elm:4217-4406`) — targets are by
construction in scope at the wrap point.

---

## 9. Runtime

### 9.1 `rcManaged` scope and count coherence

`rcManaged : Mono.MonoType -> Bool` (compiler, `Borrow/Rty.elm`) and the
matching runtime tag set define which objects carry live counts. v1 per DS6:
**pointer-free flat buffers** — `Tag_ByteBuffer`, `Tag_String`,
`Tag_StringUtf8Leaf`, and the pinned large bodies (HEAP_026); compiler-side
`MString` and the Bytes kernel types. Arrays (`Tag_Array` /
JsArray-backed `MCustom`) are the v2 target (their slots hold pointers —
child-count obligations, §9.5).

**Coherence rule (RC_001):** for `rcManaged` objects the count must never
UNDER-count owners — an undercount makes RC-1 unsound (§10 S1). Every
reference-creating site must inc: compiled code does so via reification
(dup at owned non-final uses, including stores into containers — the
storage-mode rules force Owned there); *kernel* code must be audited (§11.3)
before a type enters `rcManaged`. Overcounts are safe (missed optimization,
GC remains the backstop collector: `rcManaged` objects are still traced, so
leaked counts are reclaimed by major GC — RC is an accelerator, not the
collector of record, in option-B mode).

### 9.2 `RCElimination` becomes a mode gate

`EcoPipelineOptions` gains `bool rcMode` (default false, set from the
`--rc-mode` ecoc flag that the compiler driver passes when
`borrow.reify = rc`):

```cpp
// EcoPipeline.cpp:53
    if (!opts.rcMode)
        pm.addPass(eco::createRCEliminationPass());   // verifier: RC ops are a bug
    // rcMode: ops flow through Stage 2/2.5 untouched (they are not
    // GCRootCarriers and have no results) and lower in EcoToLLVM (§9.3).
```

The existing hard-error behavior (`RCElimination.cpp:43-67`) is preserved
verbatim for tracing mode — it remains the guard that stats-only builds
never leak RC ops into codegen.

### 9.3 Lowering patterns (`Passes/EcoToLLVMRc.cpp`, new)

Following the `BoxOpLowering` / runtime-call pattern
(`EcoToLLVMHeap.cpp:151-206, 412-463`):

```cpp
struct IncrefOpLowering : public OpConversionPattern<IncrefOp> {
    const EcoRuntime &runtime;

    LogicalResult
    matchAndRewrite(IncrefOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        auto loc = op.getLoc();
        auto fn = runtime.getOrCreateRcIncref(rewriter);  // (i64, i64) -> void
        Value word = rewriter.create<LLVM::PtrToIntOp>(
            loc, rewriter.getI64Type(), adaptor.getValue());
        Value amt = rewriter.create<LLVM::ConstantOp>(
            loc, rewriter.getI64Type(), op.getAmount());
        rewriter.create<LLVM::CallOp>(loc, fn, ValueRange{word, amt});
        rewriter.eraseOp(op);
        return success();
    }
};
// DecrefOpLowering / FreeOpLowering identical shape → eco_rc_decref / eco_rc_free.
```

The helpers are **GC-leaf**: they never allocate and never trigger a
safepoint, so their declarations carry the `gc-leaf-function` attribute and
RS4GC inserts no statepoint (the pointer argument crosses as a plain i64
word — legal because the callee does not survive a relocation point).
Registered in `RuntimeSymbols.cpp` beside `eco_store_field`
(`RuntimeSymbols.cpp:223-240` pattern).

### 9.4 Runtime helpers (`allocator/RefCount.cpp`, new)

Header bit facts (`Heap.hpp:153-164`, `TAG_BITS = 5` at `Heap.hpp:64`): the
`refcount : 15` field occupies **bits [16, 30]** of the 64-bit header word
(tag 5 + color 2 + pin 1 + age 2 + unboxed 6 = 16 bits below it; `builder`
is bit 31, `size` bits [32, 63]).

```cpp
static constexpr u32 RC_SATURATED = 0x7FFF;   // sticky ceiling (RC_002)

extern "C" void eco_rc_incref(u64 word, i64 amount) {
    HPointer hp = hpFromBits(word);           // NOT HPointer{word}: first-field init trap
    if (word == 0 || hp.ptr_ind) return;      // null / embedded constant (RC_003,
                                              //   REP_CONSTANT_002: never range checks)
    Header *h = reinterpret_cast<Header *>(word);   // HEAP_028: word IS the address
    u32 rc = h->refcount;
    if (rc == RC_SATURATED) return;           // saturated → trace-only object
    u64 next = rc + static_cast<u64>(amount);
    h->refcount = next >= RC_SATURATED ? RC_SATURATED : static_cast<u32>(next);
}

extern "C" void eco_rc_decref(u64 word) {
    HPointer hp = hpFromBits(word);
    if (word == 0 || hp.ptr_ind) return;
    Header *h = reinterpret_cast<Header *>(word);
    u32 rc = h->refcount;
    if (rc == RC_SATURATED || rc == 0) return; // sticky / untracked (count started 0
                                               //   before reify coverage — safe: GC backstop)
    h->refcount = rc - 1;
    if (h->refcount == 0)
        eco_rc_reclaim(h);                     // §9.5
}
```

Allocation sites for `rcManaged` tags initialize `refcount = 1` (today the
field is zero-initialized and ignored — one-line change per alloc helper);
the interning table stamps `RC_SATURATED` on interned literals (S5), and
`mark_as_builder`/`clear_builder` (`HeapHelpers.hpp:1102-1120`) are
untouched — builder objects are pre-escape, count 1.

### 9.5 `eco_rc_reclaim` — per-generation semantics

There is **no existing single-object free API** (agent-verified; sweep-only
+ `Tag_Free` free lists, HEAP_021/023/027). Reclaim dispatches on residency
(`Allocator::isInNursery/isInOldGen`, `Allocator.cpp:376-399`):

- **Nursery object:** no-op. A copying nursery reclaims dead objects for
  free at the next minor GC; the count reaching zero is still profitable —
  it's what RC-1 and `DropFree` classification consumed statically.
- **Old-gen object:** convert to `Tag_Free` (header.size = byte count via
  `getObjectSize`, `AllocatorCommon.hpp:213-327`) and link into the
  size-class free list — the exact mechanism `freeLargeBodyCell` already
  uses mid-major-GC (HEAP_027), generalized to mutator time. v1 restricts
  this to **pointer-free** tags, so no child traversal is needed and
  `eco.decref_shallow` vs `eco.decref` is moot; v2 (arrays) adds the
  child-decref walk sharing `markChildren`'s per-tag layout switch
  (HEAP_003/004 discipline).
- **Pinned large bodies** (HEAP_026): reclaim via the existing
  `OldGenSpace::large_bodies_` bookkeeping rather than the generic path.

### 9.6 Statepoints and GC interplay

RC ops are attached to values the emitting sites already hold as live SSA
`!eco.value`s; the helpers are GC-leaf (§9.3) so no new safepoints, no new
roots, no stackmap changes. Header refcount writes are invisible to tracing
(mark/sweep reads `color`/`age`/`tag` only). HEAP_005 (no old→young, no
write barrier) is untouched by counting itself; it constrains only RC-1
*mutation* (§10 S6).

---

## 10. Optimistic mutation (RC-1): soundness conditions

RC-1 in-place mutation — at a mutating primitive (array push, buffer
write), check the header count; 1 ⇒ mutate in place, else copy-on-write —
is the headline consumer (§1). "Optimistic" because it is a per-run dynamic
bet: the same program point mutates on the hot path and copies on the rare
shared path, value semantics preserved either way. It is sound iff:

- **S1 — Exact owner counting.** count == number of owning references
  (unmoved stack owners + heap slots), maintained eagerly at every
  dup/drop. No deferred/coalesced RC scheme unflushed at the check
  (`eco.incref`'s `amount` batching is fine — still eager at one point).
  Undercount risk concentrates in kernels → §9.1 coherence rule + §11.3
  audit gate.
- **S2 — Owned entry via move.** The mutating primitive takes the object
  `•` and reification delivers it by move; only then does count 1 mean
  "sole owner". A borrow-taking mutator is unsound by construction.
- **S3 — No live uncounted aliases.** Borrows are count-invisible, so
  count 1 proves nothing by itself — the statics close the gap: a move at
  `p` requires the owner's lifetime to have ended (`endsBefore ltP p`), and
  every borrow's liveness flows into its owner's lifetime, so sole owner +
  legal move ⇒ **zero live borrows anywhere** (paper §6.7 + its §4.3
  ok-invariants). Corollary: borrows materialized as *data* —
  `Tag_StringUtf8View` interior pointers (HEAP_032) — are invisible to both
  the count and the statics; the backing must hold a counted reference or
  be excluded from RC-1 mutation. There is no third option.
- **S4 — Thread exclusivity.** count 1 must imply no concurrent reader:
  single-threaded Elm heap (HEAP_007's one-heap-per-thread model), else
  atomic counts plus external happens-before.
- **S5 — Immortals never pass.** Interned literals / embedded constants
  carry saturated counts (§9.4) or are `ptr_ind`-skipped so they can never
  look unique.
- **S6 — GC coexistence (the eco-gating condition).** The generational GC
  is barrier-free by design: "Elm's immutability means no old→young
  pointers exist, so no write barrier or remembered set is needed"
  (`NurserySpace.cpp:25`); the only sanctioned mutation is builder-flagged
  objects, nursery-pinned precisely so slot writes cannot create old→young
  edges (HEAP_BUILDER_001–003, `Heap.hpp:135-152`). RC-1 mutation of a
  *promoted* object that stores a nursery pointer creates an edge the
  collector never sees — a freed-while-reachable bug. v1 resolution
  (= DS6): RC-1 mutation restricted to **pointer-free buffers** (no
  HPointer slots ⇒ no edges possible, zero GC interaction). v2 options for
  arrays: builder-style nursery pinning of mutable-capable arrays, or a
  scoped remembered set — decided in the v2 arrays design, not here.

What borrow inference contributes — and what it does not:

- **H1 — Soundness of the check itself.** All-owned Perceus RC-1 is
  trivially sound (every alias is counted). Borrow inference deliberately
  stops counting most aliases; S3's exclusivity theorem is the price of
  admission for having borrows and RC-1 in the same system.
- **H2 — Honest counts.** With transient dups elided, the count reflects
  genuine sharing only: a fold accumulator stays at 1 through every
  iteration (the paper's `map_rec` — push guaranteed in-place).
- **H3 — Static upgrade.** Where zero dups reach a class on any path,
  count 1 is a compile-time fact ⇒ `DropFree`/unchecked mutation — no
  branch, no COW fallback code. Under a no-RC consumption model this
  static form is the *only* mechanism — all-or-nothing, no per-run
  adaptivity.
- **H4 — Propagation through abstraction.** Owned-taking mutator builtins
  plus §5.3's ownership-propagation rule pull the demand up through
  user-defined wrappers, keeping layered update helpers on the mutate path.
- **C1 — Caveat: borrowing can *hurt* RC-1.** A borrow living past a
  mutation point forces dup-not-move into the mutator → count 2 → copy.
  Measured in the paper: `unify`, 6.4% of RC-1 mutations fell back to
  copies vs the Perceus baseline; mutation-aware flow analysis is their
  named future work. For eco: a v2 cost heuristic in Stage C (penalize
  borrows whose lifetimes cross flows into owned mutator arguments) —
  never a soundness issue; the fallback is a copy, not UB. B2's census
  counts borrow-lifetimes-crossing-mutator-flows to size it.

---

## 11. Kernel borrow signatures

### 11.1 The table

~322 C-linkage kernel functions (413 CSV entries,
`design_docs/elm_kernel_functions.csv`); calling convention is `HPtr`
(u64 HPointer word) for boxed values with `_Int/_Float/_Char` unboxed
suffix instances (`KernelAbi.suffixSelectingKernels`,
`KernelAbi.elm:145-192`).

```elm
-- Borrow/KernelSigs.elm
type ParamMode
    = PBorrowed        -- reads only; never stores or returns-by-identity
    | POwned           -- default; may store, return, or hand to unknown code


type alias KernelSig =
    { params : List ParamMode
    , resultAliases : Maybe Int   -- Just i: result may alias param i (borrow-through)
    }


lookup : ( Name, Name ) -> KernelSig   -- total: unlisted ⇒ all POwned, resultAliases = Nothing
```

Keyed by `(home, name)` exactly as `KernelTypeEnv`
(`Type/KernelTypes.elm:43`). All-owned default = the Perceus baseline —
sound without any audit.

### 11.2 The v1 audited allowlist

Same spirit as the paper's Perceus-fairness set (borrowed inputs for:
union-tag checks, tuple projection, array indexing/length, stdout/stderr).
Initial eco entries (each verified against its `elm-kernel-cpp`
implementation before listing — the audit criterion is: *reads argument
heap data; does not store the argument or any interior pointer into a
result or global; result shares no identity with the argument unless
declared via `resultAliases`*):

`Utils.{equal,notEqual,compare,lt,le,gt,ge}`, `List.length`,
`String.{length,isEmpty,startsWith,endsWith,contains}`,
`JsArray.{length,unsafeGet}` (result of `unsafeGet` `resultAliases = Just 0`
— it returns interior data), `Basics.*` numeric ops (scalar-only anyway),
`Debug.{log,toString}` (read-only formatting), `Console.write`-family
sinks. Growing this list is cheap, per-entry, and independently testable —
each upgrade is pure RC-op savings.

### 11.3 Kernel counting obligations (RC mode)

Before a type enters `rcManaged`, every kernel that can create a
*surviving* reference to a value of that type must inc it (S1). For the v1
pointer-free-buffer scope this set is small and byte/string-local: the
`Bytes` codecs, the string builders/slicers (which create views —
S3 corollary: an *uncounted* view excludes its backing from RC-1 mutation;
the M0 report decides count-at-view-creation vs exclusion per form), and
`Json.Encode.string`. The audit lands as a checklist in the M0 report; this
is the borrow-flavored twin of the MonoSolver kernel-honesty frontier
(solver-reuse-evaluation §6.3) and is deliberately scheduled before B4, not
before the analysis milestones.

---

## 12. Invariants delta

New (land with the milestone that makes them meaningful):

- **BORROW_001** (B2) — Borrow analysis mints resources only at the §3.2
  heap positions; scalars, Bool, Unit never carry RC operations.
- **BORROW_002** (B4) — `MonoRcDup`/`MonoRcDrop` are produced only by
  GlobalOpt Phase 6 and never serialized; any pre-Phase-6 pass observing
  them is a bug (enforced by `Debug.todo` arms).
- **BORROW_003** (B4) — Reified RC ops target only `rcManaged`-typed,
  non-immortal resources; analysis results for everything else are
  statistics/uniqueness facts only.
- **BORROW_004** (B4) — Every `MonoRcDrop` target is an in-scope let/param
  binding at its wrap point (checked at emission via `Ctx.lookupVar`).
- **BORROW_005** (B3) — No drop is placed after a `MonoTailCall` in the
  same body (tail-argument escape seeding guarantees it; TestLogic check).
- **RC_001** (B4) — For every `rcManaged` heap object, `Header.refcount` ==
  number of owning references, maintained eagerly; kernels creating
  surviving references to `rcManaged` values inc before the reference
  escapes.
- **RC_002** (B4) — `refcount = 0x7FFF` is sticky saturation: never
  incremented, never decremented, object becomes trace-only.
- **RC_003** (B4) — RC helpers treat `ptr_ind != 0` and null words as
  no-ops (REP_CONSTANT_002 conformance; never address-range checks,
  FORBID_HEAP_001).
- **RC_004** (B5) — RC-1 in-place mutation is permitted only for
  pointer-free `rcManaged` tags (preserves HEAP_005 without barriers).

Amended: **HEAP_005** gains a clarifying note (counting writes touch only
the header refcount field and are not pointer stores; the no-old→young
guarantee is preserved by RC_004's mutation scope). `RCElimination`'s
description changes from "removes/errors" to "verifies absence in tracing
mode; bypassed in RC mode" (§9.2).

---

## 13. Testing and migration

Strangler-style, each milestone landing in the production pipeline behind
the existing suites (the MonoDirect post-mortem's lesson 6, applied by
MonoSolver and LSS alike).

- **B0 — M0 foundation report** (doc-only): runtime strategy A/B/C call
  with DS6's evidence; dup-site instrumentation numbers (count would-be RC
  sites via a census-only run of B2 if sequenced late, or a cheap
  Perceus-style syntactic count first); kernel counting-audit checklist
  (§11.3); `rcManaged` v1 set fixed.
- **B1 — foundations** : `Borrow/{Lifetime,Dsu}.elm` + unit tests
  (property tests: `join` assoc/comm/idem, `leq` ⇔ `join` absorption,
  `endsBefore`/`onBoundary` vs paths on randomized skeletons). No pipeline
  wiring. Gate: elm-tests green.
- **B2 — intra-def analysis + census** : `Rty/Constrain/Solve` wired as
  Phase 6 with `enabled=True, reify=off`; all call boundaries all-owned
  (no sigs yet). Census (`ECO_BORROW_REPORT=1`, LSS §10 report pattern):
  per-def resources, %borrowed, would-be dups/drops/frees,
  `poisonedBy{Closure,Erased,Kernel}`, RC-1 sizing counters (C1). Gates:
  full E2E green with flag on (graph byte-identical — analysis only);
  self-compile wall-time delta measured; elm-aws-codegen canary.
- **B3 — interprocedural** : `Sig.elm`, SCC fixpoint, kernel allowlist v1.
  Gates: B2 gates + census deltas showing boundary recovery
  (`poisonedParams` down); BORROW_005 TestLogic check; wall-time budget.
- **B4 — reification + runtime RC path** (flag `reify=rc` + ecoc
  `--rc-mode`): `MonoRcDup/Drop` + 13-file sweep; `Ops.elm` builders +
  `Expr.elm` arms; `EcoToLLVMRc.cpp` + `RefCount.cpp` + symbol
  registration; alloc-site count init for `rcManaged` tags; interning
  saturation. Gates: full E2E green flag-on; `ECO_RC_STATS` dynamic
  dup/drop counters vs census predictions (they must reconcile);
  ECO_HEAP_VALIDATE runs clean (count writes don't perturb GC); tracing
  mode byte-identical with flag off.
- **B5 — RC-1 + free** : `eco_rc_reclaim` old-gen path; RC-1 check in the
  scoped buffer kernels (Bytes ops first); `DropFree` classification on.
  Gates: E2E + the string/slice suite; benchmark suite (self-compile,
  elm-aws-codegen, micro-benchmarks mirroring the paper's `text_stats` /
  parser-combinator shapes); memory-footprint watch (paper saw ≤2.5%
  regressions — borrowing extends liveness).
- **B6 (v2 program)** — mode specialization on AbiCloning (§6.2), arrays
  in `rcManaged` (+ child decref + S6 mutation story), LSS-M6 closure
  upgrade, mutation-aware Stage-C heuristic (C1), drop-sliding, per-ctor
  `RCustom` precision. Each gets its own plan doc, sized by B2/B3 census
  data.

A/B discipline throughout: `enabled=False` is byte-identical by
construction; `reify=off` is graph-identical; all-owned mode (force every
`access` to Owned — one flag in `Solve`) reproduces Perceus behavior and
is both the baseline and the soundness-isolation tool.

---

## 14. Performance considerations

- **Compile time.** Phase 6 adds one full-graph analysis: per-def work is
  linear-ish in AST size × type width (§5.6); the SCC fixpoint multiplies
  only within cycles. Budget: ≤3% self-compile wall time at B3 (measured
  each milestone; the backend rounds have made Stage-7a timing a sensitive,
  well-instrumented gate).
- **Run time (RC mode).** Helper-call dup/drop first (correctness), inline
  header RMW later if the counters say it matters — the paper measured
  1–3ns per elided dup/drop pair, so *elision* dwarfs per-op cost tuning.
- **Code size.** Zero-result ops with no regions are cheap in both text
  and bytecode serialization paths (`Backend.elm:127`, StreamEncode).
- **Memory.** Borrowing extends owner liveness (paper: only `unify`
  regressed, +2.5% peak). The census tracks max-borrow-extension per def;
  the B5 gate includes footprint on the E2E corpus.

---

## 15. Remaining open questions

1. **M0's A/B/C call** — narrowed but not made: is the v1 payoff
   (pointer-free buffer RC + RC-1 on Bytes/strings + static uniqueness)
   worth the B4/B5 runtime work, or should the program stop at B3
   (analysis + census as an optimization oracle) until arrays justify the
   runtime path? The B2 census is the deciding evidence.
2. **View counting** (S3 corollary): count-at-view-creation (defeats some
   zero-copy wins) vs excluding view-backed forms from RC-1 — per-form
   decision in M0 with the UTF-8 slice machinery owners.
3. **`resultAliases` propagation**: a kernel whose result aliases a param
   (e.g. `JsArray.unsafeGet`) returns a *borrow-as-value*; v1 treats the
   result as owned-fresh unless the alias is declared, in which case it is
   modeled as a get (vertical flow). Are there kernels whose aliasing is
   conditional? (Audit question, lands with §11.3.)
4. **Whether `MonoRcDup` needs a selector** (paper's per-field `dup s`):
   v1 dups only top-level resources of an occurrence; field-granular dup
   selectors become necessary only with per-ctor `RCustom` precision (B6).
5. **eco-boot / JS backend**: the JS pipeline shares the Mono graph. v1:
   `reify=rc` is rejected for JS targets (RC ops have no JS lowering);
   analysis/census still runs. Long-term: ignore-arms in the JS emitter.

---

## 16. References

- Paper: `design_docs/auto-borrow-inference/full-auto-type-inf-borrow-lifetimes.pdf`
- LSS design (§9.4 = this pass as consumer M6):
  `design_docs/monomorphization/lambda-set-specialization-design.md`
- Solver-reuse evaluation (architecture pattern, kernel honesty):
  `design_docs/monomorphization/solver-reuse-evaluation.md`
- Roc Perceus study (kernel borrow signatures model):
  `design_docs/perceus_gc/{README,borrow,inc_dec}.md`
- Mono IR: `compiler/src/Compiler/AST/Monomorphized.elm:202,479,530,579,769`
- Pipeline: `compiler/src/Compiler/GlobalOpt/MonoGlobalOptimize.elm:108-132`,
  `compiler/src/Builder/Generate.elm:721-790`
- Emission: `compiler/src/Compiler/Generate/MLIR/{Expr.elm:345,Ops.elm:192,525}`,
  `compiler/src/Mlir/Mlir.elm:101`
- Dialect ops: `runtime/src/codegen/Ops.td:2750-2841`; guard:
  `runtime/src/codegen/Passes/RCElimination.cpp`; pipeline:
  `runtime/src/codegen/EcoPipeline.cpp:49-113`
- Heap: `runtime/src/allocator/Heap.hpp:64,153-200`,
  `HeapHelpers.hpp:1102-1178`, `AllocatorCommon.hpp:213-327`
- Invariants: `design_docs/invariants.csv` (REP_*, CGEN_*, HEAP_*,
  HEAP_BUILDER_*, FORBID_*)
