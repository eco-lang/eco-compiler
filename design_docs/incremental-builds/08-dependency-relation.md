# 08: The compiler's dependency relation: parts, directions, SCCs

**Status:** analysis plus measurement, 2026-10-06.
- **The catalogue** in §5 merges three read-only code sweeps: front end and monomorphization,
  GlobalOpt and codegen, and the back end. Every row cites where the relation is formed.
- **The graph measurements** in §3 use the X1 census of the compiler's own program
  (`exp-x1-blast-radius.md`). The script is `experiments/x08-scc-analysis.py`.

## 1. Framing

**Nodes.** Program entities: source definitions and modules, types and constructors, specs (a
global at a concrete type, including LSS-keyed variants), lambdas and local tail functions, emitted
symbols (`$cap`/`$clo`/`$sret`/`$psplit`, wrappers, eval descriptors, CAF slots), kernels.

**Relation.** `X ⇐ Y` means *the compiled output of X depends on some fact about Y*. The
compiler's total dependency relation is a union of named parts:

  D = calls ∪ type-from-interface ∪ instance-type-from-demand ∪ lss-signature-from-callee ∪
      inlines-body-of ∪ shares-staging-class-with ∪ stamped-with-representative-from ∪
      cap-budget-from-callee ∪ covered-requires-all-callers-instrumented ∪ … (≈ 120 parts, §5)

**Direction is relative to the call graph.**

| Direction | Meaning | Across modules |
|---|---|---|
| **callee→caller** (c→C) | the caller's output depends on a fact about the callee | follows Elm import order |
| **caller→callee** (C→c) | the callee's output depends on its callers or uses | runs *against* import order |
| **symmetric / global** | union-find classes, joins over all members of a group, equality-based merging, whole-program aggregate bits, discovery-order counters | — |

**Strength: what the edge carries.**

| Strength | Payload | Early cutoff |
|---|---|---|
| **BODY** | Y's code is copied or inspected (inlining, constant thunks, `$cap` import copies) | weak |
| **SUMMARY** | a type, signature, ABI shape, bit, set or number | strong: if the summary is unchanged, nothing downstream changes |
| **IDENTITY** | Y's name, number or existence | none: a renumbering changes every byte that mentions it |

**Elm's baseline.** In stock Elm, D is essentially `calls` plus `type-from-interface`. Both are
c→C, and modules form a DAG because import cycles are rejected (`Builder/Build.elm:1356-1416`). So
every SCC lies inside one module, and the IR names them:
- `Can.DeclareRec`, from `Graph.stronglyConnComp` (`Canonicalize/Module.elm:198-218`);
- `TCan.Decls` (`AST/TypedCanonical.elm:114-117`);
- `TOpt.Cycle` with `Link _M$<first>` (`LocalOpt/Typed/Module.elm:598-629`).

Lowering module by module never splits an SCC, and facts flow bottom-up.

## 2. Is "SCCs of the total relation" the ideal unit?

**Partly.** The idea is right as a *necessary condition*, but three refinements change what the
ideal unit is.

1. **The union is the wrong object. Split it by stratum.**
   - The compiler runs in phases: front end → pre-mono → mono/LSS → inline → GlobalOpt → codegen →
     MLIR passes → back-end solves → LLVM. Each part of D belongs to one phase (stratum s).
   - Build the work graph over pairs (unit U, stratum s). Each artifact depends on:
     - stratum s of its own D_s-neighbours;
     - strata < s of its D_<s-neighbours.
   - **This product graph is acyclic iff, *within each stratum*, the unit-level image of D_s is
     acyclic.** A cycle that passes through *different* strata (A's stratum-3 output feeds B's
     stratum-5 output, which feeds A's stratum-7 output) is harmless, because the strata are
     ordered.
   - So **only each stratum's own SCCs must stay inside a unit**, not the SCCs of the union. The
     union's SCCs are much larger (§3, §4).
2. **Summary strata can be solved globally, and do not need to be respected by units.**
   - Many strata are fixpoints over small per-node *summaries*: reachability BFS 9 ms; cap-hoist
     B+C 14 ms; gc-free 11 ms; staging vote; AbiCloning representative choice; sret table;
     kernel-bit union.
   - Recompute these globally every build from cached per-unit summaries, at negligible cost. Feed
     each unit only the slice of the result it consumes, with early cutoff on that slice.
   - In the work graph such a stratum is one *hub* node: every unit feeds it and it feeds every
     unit, but it is cheap, and cutoff stops propagation unless a consumed answer changed.
   - Only **BODY strata and per-body fixpoints** (mono translation, inlining, codegen, lowering,
     LLVM opt) need their SCCs kept inside one unit.
3. **IDENTITY relations should be eliminated, not respected.**
   - Discovery-order counters (SpecIds, lambda uids, `mono_inline_N`, `_tail_<opId>`, type ids,
     member ints, `__eco_str_N`, bytecode table indices) make an entity's *name* depend on
     unrelated entities.
   - They form no meaningful SCC. They simply make everything depend on everything. Stable naming
     removes them (03).

**Refined statement of the ideal unit:**
- Take the BODY-carrying and per-body-fixpoint parts of D.
- Under **requester ownership** (02 §2, with ownership by key per X7), their SCCs collapse back
  onto modules, just as in Elm (§3).
- **Units = modules**: split when hot by instruction count (X4), merged when tiny and rarely
  edited.
- Every SUMMARY stratum is solved globally over per-unit summaries, with early cutoff.
- Every IDENTITY relation is renamed away.

**Separately: blast radius is not SCC size.** Invalidation is the *forward closure* of an edit in
the (unit, stratum) work graph, pruned wherever an artifact's consumed payload is unchanged. SCCs
determine *what must be computed together*. Closure plus cutoff determines *what must be
recomputed*. X1 measured the latter: median 1 dirty unit, about 0.25 % of the program.

## 3. Measured graph facts (compiler's own program, post-GlobalOpt census)

The base graph is 32,739 specs and 75,791 reference edges (calls, closure references,
fast-dispatch targets).

| Graph | SCCs | Nontrivial | Largest SCC | Nontrivial SCCs crossing modules |
|---|---:|---:|---|---|
| `calls/refs` spec graph (C→c references only) | 26,800 | 1,729 | 176 specs (1.2 % of cost) | **1,232 span more than one *definition* module** (6,273 specs) |
| The same graph, as per-requester copies (variant A ownership) | — | 2,081 | 176 | **2 span more than one *owner* module** (54 nodes) |
| Module graph by definition home | — | 1 | **287 of 326 modules in one SCC** | — |
| `calls` plus the reverse of every call edge (a c→C *and* a C→c fact on each edge) | 2 | 1 | **32,738 of 32,739 specs** (the whole program) | — |

**Reading the table:**
- **Monomorphization's own call edges keep Elm's property.** Every mono `callEdge` comes from a
  `MonoVarGlobal` in the spec's own TOpt body, so a spec SCC projects into one `TOpt.Cycle`
  (catalogue F-38/F-41; `Monomorphize.elm:5086-5120`).
- **After GlobalOpt, devirtualization breaks it when specs are attributed to their *definition*
  module.** AbiCloning fast-dispatch stamps and post-settle devirt turn a generic instance's
  closure calls into direct calls back into its requester. Example: a `Compiler.Parse.Primitives`
  combinator instance calls `Compiler.Parse.Expression` code that called it, giving a 176-spec
  SCC. At module level the program becomes a single 287-module SCC.
- **Requester ownership restores the property almost exactly: 2 cross-owner SCCs remain.**
  - Both come from one lambda *identity* shared by two specs in different modules. For example,
    `Terminal_Main_lambda_9344`, created from both `Compiler.Elm.Docs.bytesUnionDecoder` and
    `Compiler.Elm.Compiler.Type.bytesDecoder`, is emitted once and defined by whichever spec
    drains it first (G-43).
  - Giving each owner its own copy removes them.
- **The naive union collapses the whole program into one SCC.** As soon as any part of D runs
  C→c along call edges while another runs c→C, every call edge becomes a 2-cycle. That is the
  risk you described, and it is real.

## 4. Does the total relation swallow the graph? Which parts cause it, and the cure for each

Yes, if D is treated as one relation. Grouped by cause:

| Cause | Parts (§5 ids) | Cure | Evidence |
|---|---|---|---|
| **Identity and order counters** | F-2, F-12, F-17, F-33, F-35, F-36, F-37; G-8, G-10, G-20, G-26, G-28, G-31, G-43, G-44, G-45, G-48; B-23, B-24, B-32 | **Rename**: owner-local numbering, content keys, per-unit tables (03) | X1: one added spec renumbers 5-9k SpecIds and dirties 83-96 % of units |
| **C→c instance shaping** (generic and caller-shaped keys) | F-19, F-23, F-31, F-34; F-24 (join) | **Requester ownership by key**: the instance lives with its caller | §3: 1,232 cross-module SCCs → 2. X7: 2,379 caller-shaped non-generic specs |
| **Group unions over all members** (symmetric) | F-26, F-27, F-28 (settles); F-30 (number taint); G-13, G-14 (staging classes); G-17, G-18, G-19, G-21, G-22 (AbiCloning index and representative); G-46 / B-16 (kernel bit) | **Scope to the owner** (X3: staging is free; AbiCloning costs +2.9 %), or **globalize as a summary stratum** (settles, X7 option a) | X7 settles counterexample; X3 R2/R3 |
| **"Exists a call site anywhere" gates** (C→c) | G-7, G-35, G-38; B-2, B-3, B-11, B-21, B-27, B-30 | **Decide from the callee alone for exported symbols** (separate-compilation rule), or **globalize as a summary** (cap eligibility, linkage, `$sat` set, list-template licence) | X3 R4: coverage restriction costs no runtime |
| **Whole-module bits** | B-17 (veq), B-18 (list chunks), B-31 (init-globals set) | **Pin as configuration** in the plan stamp (hand-off plan §5.10) | — |
| **Body copies** (c→C, weak cutoff) | G-1, G-4, G-34, G-41; B-19, B-20, B-22; F-10, F-14 | **Keep**, but within a unit, or across units only from stable code (packages, small exposed unfoldings) | X3 R1: package-only inlining costs +4.9 % |

**What remains after the cures:**
- c→C SUMMARY relations, which are bottom-up and cacheable like `.eci`;
- intra-unit BODY relations;
- cheap global SUMMARY strata acting as cut-off hubs.

That is Elm's structure, generalized.

## 5. Catalogue

Columns: id, name, `X ⇐ Y`, strength, direction (✕ = crosses modules), fixpoint, where formed,
treatment (§4 cure: **K**eep, **R**ename, **O**wn, **S**cope, **G**lobalize-summary, **P**in,
**A**rtifact of partitioning). Full rows with early-cutoff notes are in the sweep reports. Paths are
under `compiler/src/Compiler/` (F, G) or `runtime/src/codegen/` (B).

### F. Front end, pre-mono, monomorphization and LSS

| id | Name | X ⇐ Y | Str | Dir | Fixpoint | Where | Tr |
|---|---|---|---|---|---|---|---|
| F-1 | imports-interface | module ⇐ imported module's `.eci` | S | c→C ✕ | acyclic (import cycles rejected) | `Builder/Build.elm:783-785`, cutoff `:1618-1627` | K |
| F-2 | interface-carries-solver-roots | `.eci`/`.ecot` types ⇐ the module's whole solve order (`SolverRoot` index) | I | order, leaks out through F-1 | module counter | `Compile.elm:477-487`; `AST/Canonical.elm:405-443` | R (**may defeat `.eci` early cutoff on private edits**: verify) |
| F-3 | type-from-interface | expr ⇐ foreign annotation | S | c→C ✕ | instantiate | `Canonicalize/Environment/Foreign.elm:128-275` | K |
| F-4 | type-from-generalized-scc | def ⇐ earlier SCC's scheme (same module) | S | c→C | union-find solve | `Type/Constrain/Typed/Module.elm:141-159`; `Type/Solve.elm:344-397` | K |
| F-5 | scc-membership | def ↔ its SCC peers | I | sym, intra-module | SCC | `Canonicalize/Module.elm:198-218` | K |
| F-6 | kernel-type-first-use | kernel node type ⇐ first use in the module | S | order, intra-module | ordered pass | `Type/PostSolve.elm:18-47` | K |
| F-7 | ctor-repr-from-union | constructor use / decision tree ⇐ union declaration | S | c→C ✕ | one-shot | `LocalOpt/Typed/Names.elm:225-260` | K |
| F-8 | refs-global | TOpt node ⇐ referenced globals | I | c→C ✕ | — | `LocalOpt/Typed/Names.elm:160-260` | K |
| F-9 | cycle-group-identity | cycle member ⇐ group handle `_M$<first>` | I | sym, intra-module | per SCC | `LocalOpt/Typed/Module.elm:598-629` | K |
| F-10 | port-codec-from-payload-type | port ⇐ payload type (generated body) | B | c→C ✕ | one-shot | `LocalOpt/Typed/Port.elm:36-416` | K |
| F-11 | merge-all-ecot | global graph ⇐ every module's `.ecot` | B | global | union | `Builder/Generate.elm:607-673` | G (0.6 s, X6) |
| F-12 | id-from-global-key-order | MVar/Arrow/SrcLambda ids ⇐ the id count of every earlier annotation and node (and `author/…` sorts before `elm/…`) | I | **global order** ✕ | one counter | `Monomorphize/AssignMVarIds.elm:224-262, 483-509` | R |
| F-13 | solver-root-sharing | binder id ⇐ first user of the same root | I | sym (exporter roots resolved with the importer's key) | per module | `AssignMVarIds.elm:179-197, 349-374` | R (latent mis-identification) |
| F-14 | flags-decoder-from-main-type | `main$flagsDecoder` ⇐ main's flags type | B | c→C | one-shot | `Monomorphize/EntryPrep.elm:92-157` | K |
| F-15 | alias-forward | caller body ⇐ final target of an alias chain | S | c→C ✕ transitive | one-shot | `GlobalOpt/PreMono/AliasForward.elm:186-572` | K |
| F-16 | eta-arity-from-callee | X's arity/body ⇐ callee's arity and cost (depth 2) | S | c→C ✕ | one round | `PreMono/EtaExpand.elm:213-2016` | K |
| F-17 | eta-mint-counter | new wrapper lambdas/arrows ⇐ shared counters | I | order ✕ | counter | `EtaExpand.elm:238, 536-551`; `PreMono/Fresh.elm:787-813` | R |
| F-18 | demand-enqueue | callee spec *exists* ⇐ caller spec's body | I | **C→c** ✕ | LIFO worklist | `MonoSolver/Translate.elm:1745, 2993-3138`; `Engine.elm:2133-2215` | O |
| F-19 | instance-type-from-demand | callee spec key ⇐ caller's computed type, *including the caller's lambda-set members* | S+I | **C→c** ✕ (non-generic globals too) | keyed get-or-create | `Translate.elm:3106-3140`; `Engine.elm:2316-2420`; `Monomorphize/Registry.elm:168-214` | O (by key) |
| F-20 | type-from-callee-scheme | caller translation ⇐ callee annotation | S | c→C ✕ | per site | `LssInfer.elm:249-256`; `Translate.elm:4782-4797` | K |
| F-21 | lss-signature-from-callee | caller ⇐ callee LSS signature (member ints) | S(+I) | c→C ✕ | monotone union-find per `TOpt.Cycle` | `LssInfer.elm:81-552, 1659-1700` | K (publish in interface; X7: 90 % of reads cross owners) |
| F-22 | arity-from-callee-decl | stamp depth / PAP slow path ⇐ callee declared arity | S | c→C ✕ | one-shot | `LssInfer.elm:2180-2260`; `Translate.elm:2733-2738` | K |
| F-23 | self-spine-stamp | callers' types ⇐ the callee's `g\|` member id | I | callee identity into callers ✕ | idempotent | `Translate.elm:4265-4359` | R |
| F-24 | lss-join-across-callers (LSS_010) | shared spec's stored type ⇐ join of *all* callers' demands | S | **C→c, symmetric over sharers** ✕ | monotone join + flush rounds | `Registry.elm:181-199`; `Engine.elm:2197-2300`; `Monomorphize.elm:4039-4117` | O |
| F-25 | completion-join-from-body | spec's registry type ⇐ join(own body type, stored demand) | S | self + C→c | monotone | `Monomorphize.elm:4275-4400` | O |
| F-26 | settle-ctor-row-union | ctor row ⇐ union over every spec row of the same constructor | S | **global/sym** ✕ | sweep after drain | `Monomorphize.elm:226-345` | G (X7) |
| F-27 | settle-var-ctor-cells | var payload slot ⇐ cell union keyed by constructor *name* | S | global; couples unrelated modules sharing a name | sweep | `Monomorphize.elm:354-650` (key `:377-381`) | G (+ key by global) |
| F-28 | settle-var-lambda | LVar slots ⇐ bodies of all recorded closures of the members | S | global, both directions | sweep | `Monomorphize.elm:689-894` | G |
| F-29 | settle-var-successors | row ⇐ member table + declared arity | S+I | row-local + global counter | one pass | `Monomorphize.elm:1182-1460` | K / R |
| F-30 | number-taint-from-earlier-item | zonk, number-multi eligibility, Prune close ⇐ Number bindings harvested from *earlier* items | S | **global order** ✕ | monotone, grows only | `Monomorphize.elm:4249`; `Engine.elm:2715-2884`; `Store.elm:2896-2901`; `Prune.elm:285-345` | S (scope to owner) |
| F-31 | mu-tie-from-demand | lambda mint ⇐ smallest qualified member id in the stored demand | I | C→c + numbering | per item | `Monomorphize.elm:4450-4475`; `Engine.elm:800-986` | R (content order) |
| F-32 | root-lambda-fold (`rootLamOf`) | mint key ⇐ whether the root was translated first | I | discovery order | write-once | `Translate.elm:1646-1690`; `Engine.elm:679-823` | R (0 order effects measured) |
| F-33 | member-id-from-intern-order | every LSet, signature and key ⇐ first-mint order of content keys | I | **global order** ✕ | append-only intern | `Engine.elm:1793-1825`; seed `Monomorphize.elm:3930` | R |
| F-34 | lambda-member-qualified-by-enclosing-key | member id ⇐ enclosing spec's caller-shaped key | I | C→c | write-once | `Engine.elm:844-973` | O / R |
| F-35 | spec-id-from-discovery-order | SpecId (in bodies, later in symbol names) ⇐ `nextId`, LIFO order | I | **global order** ✕ | counter | `Registry.elm:128-214` | R |
| F-36 | lambda-id-counter | `AnonymousLambda <entry module> n` ⇐ run-wide counter; **every mono lambda is homed at the entry module** | I | global order | counter | `Translate.elm:1727-1729`; `Engine.elm:1340` | R |
| F-37 | residual-mvar-counter | residual MVar ids ⇐ `nextMVarId` | I | global order | counter | `Translate.elm:4574, 7518`; `Store.elm:2526` | R |
| F-38 | cycle-member-enqueues-siblings | spec ⇐ its cycle siblings' specs | I | intra-module | worklist | `Monomorphize.elm:4560-4577`; `Translate.elm:946-985` | K |
| F-39 | ctor-shapes-from-union | layout ⇐ union declaration (*set* of instantiations is global) | S | c→C | recomputed at prune | `Monomorphize/Analysis.elm:554-587` | K |
| F-40 | kernel-set-facts | kernel call sites ⇐ static audited table | S | c→C | static | `MonoSolver/KernelSetFacts.elm` | K |
| F-41 | prune-reachability | spec liveness ⇐ reachability from main, ports, flags | I | **C→c** (demand) | DFS | `Monomorphize/Prune.elm:48-91` | G |

### G. Inlining, GlobalOpt, codegen-entry derivations and codegen

| id | Name | X ⇐ Y | Str | Dir | Fixpoint | Where | Tr |
|---|---|---|---|---|---|---|---|
| G-1 | inlines-body-of | spec ⇐ callee's mono body (to depth 4) | B | c→C ✕ | ≤ 4 rounds per caller | `GlobalOpt/MonoInlineSimplify.elm:2433-2780, 4818-5001` | K within the unit; S across (X3 R1 +4.9 %) |
| G-2 | inline-candidacy | spec ⇐ callee cost, whitelist, bits | S | c→C ✕ | one-shot | `MonoInlineSimplify.elm:1257, 2455-2522` | K |
| G-3 | shares-SCC-blocks-inline | spec ↔ its SCC peers (isRecursive) | S | sym in SCC | SCC | `MonoInlineSimplify.elm:1104-1245` | K |
| G-4 | loopify-copies-tailfunc | spec ⇐ callee tail func body | B | c→C ✕ | one-shot | `MonoInlineSimplify.elm:1819-2290` | K / S |
| G-5 | partial-merge-arity | spec ⇐ callee param count through an alias chain | S | c→C ✕ | bounded | `MonoInlineSimplify.elm:2525-2576` | K |
| G-6 | consults-kernel-fact-row | spec ⇐ kernel facts | S | c→C | static | `MonoInlineSimplify.elm:1370-1400` | K |
| G-7 | arity-raise-by-site-census [off] | callee ⇐ all call sites | S | **C→c** global | one-shot | `MonoInlineSimplify.elm:415, 618-866` | S |
| G-8 | lambda-uid-from-run-counter | post-mono closure names ⇐ all earlier mints | I | order ✕ | counter | `MonoInlineSimplify.elm:2588, 2623-2700`; `MonoGlobalOptimize.elm:52-63`; `Staging/Rewriter.elm:40-62` | R |
| G-9 | lambda-home-from-origin | inlined lambda copy's name ⇐ callee's module | I | c→C ✕ | one-shot | `MonoInlineSimplify.elm:2632-2678` | R |
| G-10 | local-name-from-varCounter | `_tail_mono_inline_N_…` symbol ⇐ all earlier inlining | I | order ✕ | never-reset counter | `MonoInlineSimplify.elm:2587-2620, 2107, 4528` | R |
| G-11 | exists-iff-reachable-after-inline | callee spec ⇐ every caller's post-inline body + roots | S | **C→c** ✕ | DFS | `Monomorphize/Prune.elm:48-179` | G |
| G-12 | wrapper-adopts-singleton-identity | member's blocked bit ⇐ wrappers minted anywhere | S | sym/global ✕ | one-shot | `MonoGlobalOptimize.elm:508-650`; `AbiCloning.elm:410-418, 669-686` | S |
| G-13 | shares-staging-class-with | producer ↔ every slot with the same structural key | S | **sym/global** ✕ | union-find + majority vote | `Staging/GraphBuilder.elm:279-683`; `Staging/Solver.elm:170-260`; `Staging/Rewriter.elm:74-226` | S (X3 R2: free) |
| G-14 | dynamic-slot-from-class | tail-func call ⇐ its class's producer set | S | global ✕ | union-find | `Staging/Solver.elm:380-413`; `MonoGlobalOptimize.elm:1155-1172` | S |
| G-15 | staging-wrapper-blocks-member | member ⇐ any staging wrapper carrying it | S | global ✕ | one-shot | `Staging/Rewriter.elm:44-55`; `AbiCloning.elm:688-691` | S (0 wrappers today) |
| G-16 | mu-tie-blocked | member ⇐ mono's blocked set | S | global | — | `AbiCloning.elm:786-797` | S |
| G-17 | member-instances-of | singleton call site ⇐ every instance of the member program-wide | S | **sym/global** ✕ | global index | `AbiCloning.elm:300-640` | S / G |
| G-18 | verbatim-fingerprint-fence | stamp licence ⇐ hashes of *all* instances in a layout group | B (by hash) | sym ✕ | one-shot | `AbiCloning.elm:566-625, 3212-3700` | S / G |
| G-19 | stamped-with-representative-from | fast-dispatch call bytes ⇐ representative instance = first in SpecId walk order | I+S | **global order** ✕ | one-shot | `AbiCloning.elm:248-262, 1410-1575`; `Expr.elm:290-316, 2247-2330` | S (X3 R3 +2.9 %) + R |
| G-20 | kind-id-from-stamp-order | site ⇐ first-stamp order (**not emitted**) | I | order | counter | `AbiCloning.elm:2636-2649` | — |
| G-21 | post-settle-devirt-unique-spec | `MonoVarLocal` site ⇐ set of all surviving specs of g | S+I | global ✕ | one-shot | `AbiCloning.elm:850-870, 3021-3116` | S / G |
| G-22 | pap-global-stamp | PAP site ⇐ g's spec rows and uniqueness | S+I | global ✕ | one-shot | `AbiCloning.elm:2844-3000` | S / G |
| G-23 | callinfo-from-callee-staging | call ⇐ callee node kind, arity, stage arities | S | c→C ✕ | one-shot | `MonoGlobalOptimize.elm:1130-2175` | K |
| G-24 | borrow-sig [off] | def ⇐ callee sigs; member ⇐ meet over all instances | S | c→C + global meet | SCC fixpoint | `Borrow.elm:222-297` | K / S |
| G-25 | debug-purity [off] | spec ⇐ callees transitively | S | c→C | poison fixpoint | `CsePurity.elm:13-30` | K |
| G-26 | cse-binder-counter [off] | let names ⇐ earlier nodes | I | order | counter | `MonoCse.elm:162-352` | R |
| G-27 | caf-dedupe-canonical [off] | CAF references ⇐ all equal CAFs (smallest SpecId) | I | sym | capped fixpoint | `CafDedupe.elm:1-66` | S / linker |
| G-28 | caf-hoist-shared-mint [off] | hoisted subexpression ⇐ first minter; global budget | I | global order | counter | `CafHoist.elm:48-287` | S / R |
| G-29 | map-template-licence [off] | `List.map` spec ⇐ callback purity, stamp, member meet | S+I | c→C + global meet | settle | `MapTemplate.elm:765-1327` | S |
| G-30 | signature-of-callee | caller ⇐ callee FuncSignature | S | c→C ✕ | one-shot | `Generate/MLIR/Context.elm:867-1000` | K |
| G-31 | callee-symbol-name | caller bytes ⇐ `<Mod>_<name>_$_<specId>` | I | c→C ✕ | discovery order | `Expr.elm:306-316` | R |
| G-32 | nullcons/const-ctor-folded | reference ⇐ nullary ctor / enum | S | c→C ✕ | one-shot | `Backend.elm:1425-1500`; `Expr.elm:765-806` | K |
| G-33 | ctor-shape-for-saturated-call | caller ⇐ ctor shape | S | c→C ✕ | one-shot | `Backend.elm:1377-1391` | K |
| G-34 | const-thunk-body-copied-into | reference ⇐ arity-0 thunk body | B | c→C ✕ | memoized | `ConstThunks.elm:65-200`; `Expr.elm:808-816` | K |
| G-35 | sret-promoted-because-of-caller-site | callee worker + shim ⇐ some let-bound site anywhere | S | **C→c** ✕ | one-shot set | `Backend.elm:568-584, 833-841` | S (decide from callee) |
| G-36 | sret-admitted-via-result-leaf-callees | spec ⇐ result-leaf callees' membership | S | c→C ✕ | greatest fixpoint (≤ 30) / least fixpoint fallback | `Backend.elm:600-760` | G |
| G-37 | sret-site-migrates | let-bound site ⇐ callee ∈ table | S | c→C | — | `Expr.elm:5672, 7848-7860` | K |
| G-38 | psplit-justified-by-caller-site | callee `$psplit` ⇐ some site passing a constructish argument | S | **C→c** ✕ | monotone, ≤ 4 rounds | `Backend.elm:965-1130, 1308-1375` | S |
| G-39 | psplit-admissible-via-passthrough | param plan ⇐ callee's promoted positions | S | c→C ✕ | same fixpoint | `Backend.elm:1004-1060` | G (needs conditional summaries) |
| G-40 | psplit-site-migrates / excluded-if-sret | site ⇐ callee ∈ psplit; spec ∉ sret | S | c→C | — | `Expr.elm:3484-3650`; `Backend.elm:1086` | K |
| G-41 | bytes-fusion-inlines-final-body | fused encoder/decoder ⇐ *final* bodies of callees | B | c→C ✕ | transitive reify | `MonoInlineSimplify.elm:118-160`; `Expr.elm:3062-4351` | K / S |
| G-42 | lowering-by-callee-origin | call lowering ⇐ the callee's package (core intrinsic, fusion, chunk shunt) | I | c→C | — | `Expr.elm:3786-4011`; `Functions.elm:320-340` | K |
| G-43 | lambda-defined-by-first-drainer | lambda func ⇐ whichever spec drains it first (dedup by name) | I | sym/order ✕ | drain order | `Generate/MLIR/Lambdas.elm:30-80` | O (per-owner copies; the 2 cross-owner SCCs in §3) |
| G-44 | tail-name-from-op-counter | `_tail_<name>_<nextOpId>` ⇐ op count of *all* earlier functions | I | order ✕ | never-reset counter | `Context.elm:615-619`; `Expr.elm:5958` | R |
| G-45 | type-id-from-first-use-order | `eco.dbg` / `Debug.toString` constants, type table ⇐ first use | I | order | counter | `Context.elm:407-560`; `TypeTable.elm:124` | R |
| G-46 | kernel-decl-gcleaf-or-merged (+ CGEN_038 ABI) | kernel declaration ⇐ all callers of that symbol | S | sym hyper-edge ✕ | union | `Context.elm:744-822` | P (function of the symbol) |
| G-47 | layout-from-ctor-shapes | construct/case/project attributes ⇐ ctorShapes | S | c→C (definition → use) ✕ | (mono) | `Patterns.elm:139-212`; `LogicalTypes.elm:91-130` | K |
| G-48 | bytecode-table-index | each op's bytes ⇐ string/attr/type indices first met in earlier batches | I | order | append-only | `Mlir/Bytecode/StreamEncode.elm:1-152` | R (per-unit tables) |

### B. MLIR and LLVM back end

| id | Name | X ⇐ Y | Str | Dir | Fixpoint | Where | Tr |
|---|---|---|---|---|---|---|---|
| B-1 | reach-from-roots (+ internalize) | symbol liveness and linkage ⇐ transitive referrers to the roots | I | **C→c** ✕ | BFS 9 ms | `Passes/EcoReachability.cpp:70-167`; `Passes/EcoSymbolGraph.cpp:78-125` | G |
| B-2 | address-taken-by | callee ⇐ each referrer's `addressof` use | S | **C→c** ✕ | one-shot | `EcoSymbolGraph.cpp:86-233`; `EcoCapHoistPlan.cpp:203-209` | G / S |
| B-3 | covered-requires-all-callers-instrumented | callee eligibility ⇐ not interposable, not address-taken, local | S | **C→c** | one-shot | `EcoCapHoistPlan.cpp:178-235` | S (X3 R4: free in time) |
| B-4 | site-signature-matches-callee | caller's call kind (Call vs CallMismatch) ⇐ callee converted signature (then feeds B-2) | S | c→C, then C→c | one-shot | `Passes/EcoToLLVMClosures.cpp:1355-1370` | G |
| B-5 | cap-local-scan (Phase A) | own bytes, ⊤, callee list ⇐ callee kinds | S | c→C | per body 0.47 s | `EcoCapHoistPlan.cpp:219-374`; `EcoMarkerFacts.h:57-73` | K (cache per function) |
| B-6 | cap-budget-from-callee (Phase B) | budget ⇐ callee budgets and eligibility | S | c→C (+ two-hop C→c) ✕ | SCC fixpoint 14 ms | `Passes/EcoCapHoistCore.cpp:135-285` | G |
| B-7 | covered-iff-eligible-and-budgeted | covered ⇐ B-3 ∧ B-6 | S | **sym** | combine | `EcoCapHoistCore.cpp:287-289`; `EcoCapHoistPlan.cpp:380-403` | G |
| B-8 | caller-ensure-for-covered-callee | caller body (ensure, unchecked bumps) ⇐ callee coverage and budget | S | c→C ✕ | per body | `EcoBackend.cpp:3490-3790` | K |
| B-9 | owner-verifies-plan | owner check ⇐ callee contributions | S | c→C | per body | `EcoBackend.cpp:3347-3405` | K |
| B-10 | gc-leaf-from-callee | stamp ⇐ no poisoned callee | S | c→C ✕ | greatest fixpoint 11 ms | `Passes/EcoGcFreePropagation.cpp:204-342` | G |
| B-11 | gc-leaf-from-own-coverage | own allocation markers leaf ⇐ own coverage ⇐ callers (B-3) | S | **C→c** (two hops) | local | `EcoMarkerFacts.h:86-88`; `EcoGcFreePropagation.cpp:271-275` | G |
| B-12 | ensure-poisons-noncovered-caller | caller poison ⇐ covered callee ∧ ¬covered caller | S | c→C | local | `EcoGcFreePropagation.cpp:250-254` | G |
| B-13 | statepoint-at-call-site (RS4GC) | caller body ⇐ callee gc-leaf bit | S | c→C ✕ | per body | `EcoBackend.cpp:934-985` | K |
| B-14 | cross-partition-gc-leaf-join | declaration ⇐ owner stamped | S | c→C | driver join | `EcoBackend.cpp:625-670` | A |
| B-15 | declaration-carries-owner-facts (S6) | declaration ⇐ owner's facts | S | c→C | per partition | `EcoSplit.cpp:62-368` | A |
| B-16 | kernel-gc-leaf-at-site | site root set and statepoint ⇐ kernel declaration bit | S | c→C (front end: all callers ↔) | — | `Passes/EcoMarkGCLeafCalls.cpp:73-93` | P |
| B-17 | value-eq-leafness (veq) | every value-eq site ⇐ whether `Utils_equal` survived the declaration strip | S | **global** | whole module | `EcoCapHoistPlan.cpp:164-170`; `EcoGcFreePropagation.cpp:175-193`; `EcoToLLVM.cpp:791-830` | P |
| B-18 | list-chunks-gate | every list lowering ⇐ `@main`'s attribute | S | **global** | whole module | `EcoToLLVM.cpp:222-266`; `EcoListTemplate.cpp:336-345`; `EcoBackend.cpp:2481-2491` | P |
| B-19 | cap-inline-prepass | caller body ⇐ body of small `$cap` callees (post-expansion) | B | c→C | per body, bottom-up | `EcoBackend.cpp:3884-3969, 4171-4181` | K |
| B-20 | imported-$cap-copy | partition ⇐ `$cap` bodies owned elsewhere | B | c→C | closure per partition | `EcoSplit.cpp:179-206, 292-300` | A (X5: module units need ≈ none) |
| B-21 | linkage-from-cross-partition-referrer | linkage ⇐ whether another partition references it | I | **C→c** | one-shot | `EcoSplit.cpp:226-356`; `EcoBackend.cpp:4159-4249` | A / G |
| B-22 | inlined-into (-O2) | caller body ⇐ callee body (gc-leaf callees only, same partition) | B | c→C | CGSCC | `EcoBackend.cpp:549-595, 4394-4398` | K |
| B-23 | partition-ownership-by-LPT | every function's partition ⇐ op counts and names of all functions | I | **global** | global sort | `EcoSplit.cpp:117-153`; `EcoBackend.cpp:848-874` | A (module units) |
| B-24 | global-owner-by-first-referrer | global's partition ⇐ first referrer in module order | I | global order | one-shot | `EcoSplit.cpp:154-166` | A |
| B-25 | caf-slot-fast-path | caller body ⇐ callee's `eco.caf_memo` (+ slot address) | I | c→C | per body | `EcoToLLVM.cpp:236-243`; `EcoToLLVMGlobals.cpp:580-736` | K |
| B-26 | wrapper-minted-for-closure-target | wrapper and descriptor *existence* ⇐ any closure creation anywhere; body ⇐ the target's signature | I/S | existence **C→c**, body c→C | one-shot | `EcoToLLVMClosures.cpp:292-420, 3274-3345` | O (owner rule, hand-off §7.3) |
| B-27 | sat-signature-set-from-call-sites | `$sat` entries ⇐ the *global* set of indirect-call signatures and min captured | S | **global** | whole module | `EcoToLLVMClosures.cpp:1494-1700, 3172-3270` | G (safe both ways) |
| B-28 | pap-simplify-direct-call | caller rewrite ⇐ target signature (removes B-26 demand and B-2 edges) | S | c→C | greedy per body | `Passes/EcoPAPSimplify.cpp:95-260, 600-630` | K |
| B-29 | compare-case-cmp3 | caller site ⇐ producer is `Utils.compare` | I | c→C (kernel) | per site | `Passes/EcoCompareCaseRewrite.cpp:119-152` | K |
| B-30 | list-template-protocol | callee rewrite ⇐ **every** use is a rewritable direct call; every caller rewritten | S | **sym** ✕ | whole module | `Passes/EcoListTemplate.cpp:400-418, 1124-1330` | G (licence) |
| B-31 | init-globals-root-set | `__eco_init_globals` ⇐ all internal i64 globals + type graph | S | global | whole module | `Passes/EcoToLLVMGlobals.cpp:466-540` | P / A |
| B-32 | ordinal-symbol-numbering | `__eco_str_N`, `__eco_str_case_…`, `__eco_strlit$…` ⇐ count emitted earlier | I | order | counter | `EcoToLLVMTypes.cpp:179-192`; `EcoToLLVMControlFlow.cpp:1185-1205`; `EcoToLLVMGlobals.cpp:800-890` | R |

## 6. Cycles that cross modules on a single call edge

These are the pairs that make the naive union collapse. Each is a cycle *across strata* or a C→c ×
c→C pair. Each is broken by the §4 cure in brackets.

| Cycle | Relations | Cure |
|---|---|---|
| Instance shaping | F-19 × F-21: `M2.f` calls `List.map g`. The instance's key carries `M2`'s lambda, and `M2.f` reads the instance's signature. | Own |
| Join across callers | F-24 × F-18: `M3`'s edit re-joins the `List.foldl#k` that `M2` calls. | Own |
| Settles | F-26 / F-27 / F-28 × F-7 / F-3: the lower module's row is shaped by the importer's constructions (X7 counterexample). | Globalize |
| Number taint | F-30 × F-20 | Scope |
| Input numbering | F-12 / F-17 × any c→C relation: elm/core's ids depend on user modules. | Rename |
| sret | G-35 × G-37 (+ G-36) | Scope + globalize |
| psplit | G-38 × G-39 × G-40 | Scope + globalize |
| inline × prune | G-1 × G-11: every caller inlining f kills it; one stopping revives it. | Globalize liveness |
| inline × AbiCloning | G-1 × G-17 / G-18 / G-19: a copy's representative may name a lambda living in the other module. | Scope + rename |
| staging × CallInfo | G-13 × G-23 | Scope |
| Wrapper blocks member | G-12 / G-15 × G-17 | Scope |
| Coverage ↔ caller | B-2 / B-3 / B-4 × B-6 / B-8 / B-12 | Globalize (cheap) or scope (exported ⇒ not covered) |
| gc-leaf ↔ own coverage | B-10 × B-11 | Globalize |
| list-template protocol | B-30 | Globalize the licence |
| PAP-simplify ↔ wrapper / address | B-28 × B-26 × B-2 | Own + globalize |

## 7. New findings and corrections from the sweeps

- **F-2: a front-end cutoff leak (to verify).** Interface types carry `SolverRoot` cell indices
  that depend on the module's whole solve order (`Compile.elm:477-487`), and `.eci` equality
  compares them. A private edit that shifts solve order could therefore change the `.eci` and
  recompile every importer, defeating Elm's early cutoff. X6's literal edit did not trigger it,
  but an edit adding a definition might.
- **F-12: id order is author-sensitive.** `AssignMVarIds` numbers in key order, so packages under
  `elm/…` are numbered *after* `author/…` user modules, and elm/core's ids depend on user code.
- **F-36: lambda homes are lost.** Every mono lambda is homed at the *entry* module. The mono →
  module mapping of lambdas must be rebuilt for ownership.
- **G-43: shared lambda identity.** One emitted lambda can be created from specs in different
  modules. This is the only source of cross-owner SCCs under requester ownership (§3).
- **Corrections to 02 §3:**
  - The case/if ABI normalization (`rewriteCaseForAbi`/`rewriteIfForAbi`) is dead code.
  - AbiCloning kind ids are never emitted.
  - `mono_inline_N` names reach `_tail_` symbol names, but do not shift lambda ids (separate
    counters).
  - Kernel gc-leaf is nearly a function of the symbol already: only the legacy name-only
    registration path disagrees.
- **Correction to 04 §2.** At the default unlimited budget the LSS_010 join can still fire, e.g.
  when a completion-joined stored type collides with a fresh demand. X7 measured 1 changed join
  and 1 flush round.
- **Doc nit.** `Builder/Generate.elm:819` says EtaExpand is "Default OFF"; it is on
  (`Config.elm:525`).

## 8. Summary answer

- **Agree, with refinements.** The ideal unit keeps SCCs together, but the SCCs to respect are
  *per-stratum SCCs of the BODY-carrying relations*, not SCCs of the union.
  - Taken naively, the union is a single SCC (measured: 32,738 of 32,739 specs).
  - Requester ownership by key brings the body-relation SCCs back inside modules (measured: 2
    exceptions from one shared lambda identity).
- **The rest is handled without touching unit boundaries:**
  - SUMMARY relations become cheap global solves with early cutoff;
  - IDENTITY relations are renamed away;
  - the "exists a caller anywhere" gates are either decided from the callee alone (separate-
    compilation rules) or solved as global summaries.
- **The remaining risk of "rebuild everything"** is then confined to edits that change a
  *widely consumed summary*, such as a type used in many keys (X1 e4: ~9 %). Under the current
  numbering scheme, it also includes any edit at all, which is why stable naming comes first.
