---
status: not-started
updated: 2026-11-24
---

# Hash a key once per function: inline the SeqDict wrappers, merge repeated hashes in Mono

When one function does several SeqDict or SeqSet operations on the same key, as in
`case SeqDict.get k d of ... Nothing -> SeqDict.insert k v d` or `member k d1 && member k d2`, each
operation hashes the key again. For a structured key (a type tree, a record, a tuple holding a
String) or a long String, each hash walks the key. This plan makes the native compiler hash it once:

1. inliner whitelists and blacklists name functions by **fully qualified name**
   (`package:Module.name`), so that eco/system's wrappers can be listed without catching a user
   module of the same name;
2. `FNV.hash` gets a true **`KernelFacts` row** (compulsory, user decision 2026-11-24);
3. the SeqDict and SeqSet **wrappers are whitelisted** for inlining, so their `FNV.hash` calls appear
   in the caller;
4. a **hash-only mode of the Mono CSE pass** (`Compiler.MonoOpt.Cse`), on by default, merges repeated
   `FNV.hash` calls of one value, seeing through the inliner's `let` aliases.

Scope: repeats **within one function**, **native backend only** (the JavaScript backend is generated
from the optimized graph and runs neither the Mono inliner nor the Mono CSE). Reuse across functions
or data structures is plans/hash-reuse-explicit-vs-cached.md (§11).

## 1. Where things stand (verified 2026-11-24)

### 1.1 The wrappers

`system-kernel-cpp/src/SeqDict.elm`:

| function | body |
|---|---|
| `get key (SeqDict_elm_builtin root _)` | `case getEntry (FNV.hash key) key root of Just (Entry _ _ _ value) -> Just value; Nothing -> Nothing` |
| `member key (SeqDict_elm_builtin root _)` | `case getEntry (FNV.hash key) key root of Just _ -> True; Nothing -> False` |
| `insert key value (SeqDict_elm_builtin root order)` | `insertWithHash (FNV.hash key) key value root order` |
| `remove key dict` | `removeWithHash (FNV.hash key) key (rebuildOnOverflow dict)` |

`update` and `updateIfExists` bind `hash = FNV.hash key` once already. `SeqSet.member`, `insert`
and `remove` (`system-kernel-cpp/src/SeqSet.elm`, `import SeqDict as Dict`) call the SeqDict ones,
so an inlined `SeqSet.member` contains an inlined `SeqDict.member`.

### 1.2 How the hash is represented

- **Mono IR:** `FNV.hash k` is `MonoCall _ (MonoVarKernel _ "Eco" "FNV" "hash" _) [k] _ _` (kernel
  key `( "Eco", "FNV", "hash" )`; the GenerateMlir arm is at `Compiler/GenerateMlir/Expr.elm:4100`).
- **MLIR:** at a known key type it becomes one `eco.hash` (Int, Float, Char, Bool, String or `value`
  kinds) or, for a tuple or record key, a typed chain (`arith.constant` start state,
  `eco.project.*` field reads, `eco.hash.mix` / `eco.hash.walk` steps, `eco.hash.finish`). A String
  field mix calls `eco_hash_mix_string` and a walk field calls `eco_hash_walk`, so those parts of a
  chain are as expensive as a whole hash. Merging at the Mono level, before the chain is generated,
  covers every key shape at once.
- **As a function value** (`List.map FNV.hash`), it calls the kernel `Eco_Kernel_FNV_hash`
  (system-kernel-cpp/src/eco-system/FNV/FNVExports.cpp:14), which returns `eco_hash_value`.

### 1.3 Inlining today

The post-mono inliner (`Compiler.MonoOpt.InlineSimplify`) inlines a non-recursive definition when
`computeCost` of its body is at most `inline.postMonoThreshold` (10), or when it is whitelisted,
and never when it is blacklisted. The wrappers cost about 15-17 (a call is 5 plus its callee and
arguments; an unlisted kernel call costs 6, `kernelCallCost` InlineSimplify.elm:1441), so they stay
calls: 38 direct calls of `SeqDict.get` / `insert` / `member` in the benchmark program's MLIR.

**The whitelist mechanism** (`isWhitelisted`, InlineSimplify.elm:1141) compares
`moduleName ++ "." ++ name` with the list's strings: no package. Its inputs:

- `defaultWhitelist` (InlineSimplify.elm:1050): `Bytes.Encode.*` and `Bytes.Decode.*` (elm/bytes),
  `Utils.Bytes.*` (the compiler's own modules, `compiler/src/Utils/Bytes/`) and `Mlir.Bytecode.*`
  (the package `the-sett/elm-mlir` 6.0.0, compiler/elm.json:30);
- `inline.whitelist` / `inline.blacklist` from `eco-config.json` (Config.elm:744-745, in the config
  hash as `wl=` / `bl=`, Config.elm:1030-1031);
- the pipeline's own blacklist (`Compiler/Pipeline/Steps.elm:684-711`): `List.reverse`,
  `List.append`, `List.concat`, `List.take`, `List.drop` with `list.chunks`, `List.map` with
  `list.mapTemplate`.

No config file in the repository uses `whitelist` or `blacklist`. An application's modules belong to
the placeholder package `author/project` (`Pkg.dummyName`, `Builder/Build.elm:2268`); a package's to
its own name; a kernel application's to its kernel package.

**Experiment (copy of examples/benchmarks under /tmp, `eco-config.json` whitelisting the seven
wrappers by bare name):** direct wrapper calls 38 → 2 (the rest are function values); `eco.hash` ops
13 → 38; seqdict-intern's `probe` then hashes its key twice, the second in the `Nothing` branch:

```mlir
^bb0(%node: !eco.value, %d: !eco.value):
  %7 = "eco.hash"(%node) {kind = "value"} ...          // from SeqDict.get
  ... "eco.case" ... {
      %21 = "eco.hash"(%node) {kind = "value"} ...     // from SeqDict.insert
```

In MLIR both read `%node` because codegen gives an alias `let a = x` the SSA value of `x`. **In Mono
they do not**: the inliner binds every argument to a fresh name (`wrapInLets`,
InlineSimplify.elm:3538, `let mono_inline_<n> = arg`), and `simplifyLets` only drops unused `let`s,
so the two calls are `FNV.hash mono_inline_3` and `FNV.hash mono_inline_9`. Only one function in the
107-workload benchmark program (`SeqLargeKeys_probe`) repeats a hash once inlined.

### 1.4 Merging today

- **Mono CSE** (`Compiler.MonoOpt.Cse`) runs after the inliner (Builder/Generate.elm: inline at
  :1050, CSE at :1637) and binds a repeated pure call once (`let mono_cse_<n> = …` at the lowest
  common ancestor of the occurrences). It is **off by default** (`cse.enabled`, `ECO_CSE`). Its rules:
  a candidate is a `MonoCall` whose result is not a function, with no `let`/destructuring/`case`/
  closure inside, accepted by `CsePurity.isSafeExpr` (a kernel only when its `KernelFacts` row is
  hoistable), costing at least `minCost` (5); occurrences group by equal shape (regions zeroed);
  a group is merged only if no occurrence is inside a closure below the LCA, at least one is reached
  from the LCA through unconditional steps, and no free local of the call is bound below the LCA.
  It would not merge `FNV.hash` today (no row) and could not merge the two calls above even with
  one (different variable names).
- **MLIR general CSE** (`ECO_MLIR_CSE`) is off by default because merging constructs that hold a NaN
  into one object changes `==` (EcoPipeline.cpp:110-121).

### 1.5 Measured upper bound

Four builds of the benchmark, interleaved runs, medians of 3 (ms):

| workload | base | wrappers inlined | inlined + `ECO_MLIR_CSE=1` | `ECO_MLIR_CSE=1` only |
|---|--:|--:|--:|--:|
| seqdict-intern | 335 | 337 | **319** | 337 |
| seqdict-int / -string / -churn / -prefixkey, seqset-distinct | | ±3 (noise) | ±3 | ±3 |

General MLIR CSE merges the duplicate hash in `probe`; the Mono hash merge must give the same −5 % on
seqdict-intern. Code size: +7.6 KB for inlining alone. The compiler does not use SeqDict, so its
self-build time can only show a cost.

## 2. Review history

- **First review (2026-11-24):** whitelist reach verified by experiment; wrapper cost computed;
  typed-chain merging found impossible for an MLIR hash-only pass; LLVM attribute step dropped; test
  mechanics corrected; gains measured (§1.5).
- **User decisions (2026-11-24):** fully qualified whitelist names for all whitelisting (A1); the
  `KernelFacts` row compulsory (A2); the MLIR `EcoHashCse` pass replaced by a Mono hash-only CSE (A4),
  which covers typed chains because it merges before they exist.
- **Second review:** §10.

## 3. Step A1: fully qualified names in inliner whitelists and blacklists

### 3.1 The form

An entry is `package:Module.name`, for example `elm/bytes:Bytes.Encode.signedInt8`,
`elm/core:List.map`, `eco/system:SeqDict.get`. A **bare** `Module.name` names a definition of the
program being compiled: its root package (`author/project` for an application, the package's name for
a package, the kernel package for a kernel application). Record accessors never match.

### 3.2 Code

`compiler/src/Compiler/MonoOpt/InlineSimplify.elm`:

1. A type and parser, **in `compiler/src/Compiler/Config.elm`** (string-only, no `Pkg`), because
   `Compiler.Config` imports only `Compiler.Json.Decode` and every MonoOpt module imports
   `Compiler.Config`: putting the parser in a MonoOpt module and importing it from `Config` would
   make a `Compiler` ↔ `Compiler/MonoOpt` folder cycle, which `check-folder-cycles.py` rejects in the
   gate (CMakeLists.txt:1556-1557, 1676-1677). `InlineSimplify` imports it from `Config`:

   ```elm
   {-| An inliner whitelist or blacklist entry: the package as `author/project`, or `Nothing` for
   the program's own modules (a bare name), the module and the definition. -}
   type alias InlineName =
       { package : Maybe String, moduleName : String, name : String }

   {-| Parses `package:Module.name` or `Module.name`; `Nothing` for anything else (no `.`, an empty
   part, a package without exactly one `/`, more than one `:`). The module is everything before the
   last `.`. -}
   parseInlineName : String -> Maybe InlineName
   ```

2. A resolved form for matching, built once per run: `type alias InlineNameSet = Set ( String,
   String, String )` of `( "author/project", "Module", "name" )`, bare entries resolved to the root
   package. `resolveInlineNames : Pkg.Name -> List String -> InlineNameSet` drops unparsable entries
   (the config decoder has already rejected them; the built-in lists are tested).
3. The root package: from the graph, `MonoGraph.main` (`StaticMain specId`; `main : MainInfo` is
   never absent, Mono.elm:3123, 3423-3424) → `registry.reverseMapping` (kept in the finished graph,
   Mono.elm:3066-3075) → `Mono.Global (ModuleName.Canonical pkg _) _` → `Pkg.toChars pkg`. Hand-built
   test graphs have a main too; their bare names resolve to its package (the tests state which).
4. `isWhitelisted : InlineNameSet -> Mono.Global -> Bool` becomes a lookup of
   `( Pkg.toChars pkg, moduleName, name )` for `Mono.Global (ModuleName.Canonical pkg moduleName)
   name`, and `False` for `Mono.Accessor`. The two call sites in `initRewriteCtx` (`whitelisted`,
   `blacklisted`, :2605 and :2613) pass the two resolved sets; `effectiveWhitelist` is computed from
   strings as now (`defaultWhitelist ++ whitelist`, less `blacklist` by string) and then resolved.
   `RewriteCtx.whitelist : InlineWhitelist` (InlineSimplify.elm:1510, set at :2698) changes to
   `InlineNameSet` with it.
5. `defaultWhitelist`: the `Bytes.Encode.*` and `Bytes.Decode.*` entries get `elm/bytes:`; the
   `Mlir.Bytecode.*` entries get `the-sett/elm-mlir:` (a package, not the compiler's code: left bare
   they would stop matching, the A1 check below would fail and the compiler would lose those inlines).
   The `Utils.Bytes.*` entries stay bare: they are the compiler's own modules and match only when the
   compiler itself is compiled. The docstring says so.
6. A **diagnostic for bare names that match a library only**: when `inline.report` is on, after
   resolution, for each bare config entry with no definition in the root package but a definition of
   that `Module.name` in another package of the graph, print once to stderr
   `inline: "<entry>" names no definition of this program; did you mean "<pkg>:<entry>"?`.

`compiler/src/Compiler/Pipeline/Steps.elm` (`inline`, :684-711): the pipeline's blacklist entries
become `elm/core:List.reverse`, `elm/core:List.append`, `elm/core:List.concat`, `elm/core:List.take`,
`elm/core:List.drop`, `elm/core:List.map`.

`compiler/src/Compiler/Config.elm`: the decoder of `inline.whitelist` / `inline.blacklist` (:744-745)
checks each entry with `parseInlineName` (defined in the same module, item 1) and fails with
`inline.whitelist entry "<s>": expected package:Module.name or Module.name`. The hash tokens `wl=` /
`bl=` keep the strings as written.

### 3.3 Tests (A1)

Parsing (qualified, bare, malformed cases) in `compiler/tests/Compiler/ConfigTest.elm` (the parser
is in `Compiler.Config`); matching in `compiler/tests/Compiler/MonoOpt/InlineSimplifyTest.elm` or a
new `InlineSimplifyWhitelistTest.elm` beside it, on hand-built `Mono.Global`s: a qualified entry matches its package
only; a bare entry matches the root package only; an accessor never matches; a blacklisted entry is
not whitelisted. `compiler/tests/Compiler/ConfigTest.elm`: a malformed `inline.whitelist` entry fails
to decode with the message. The list-template E2E tests (`TEST_FILTER=elm`) still see `List.map`
uninlined with `list.mapTemplate` on.

## 4. Step A2: the `KernelFacts` row for `FNV.hash` (compulsory)

### 4.1 Audit (2026-11-24; re-read the lines when writing the row)

- `Eco_Kernel_FNV_hash` (FNVExports.cpp:14-16) returns `eco_hash_value`
  (runtime/src/allocator/ValueHash.cpp:464-468), which runs `Hasher` (:307).
- **No call-time effect and no call-back:** `Hasher` reads the value and mixes numbers; it calls no
  closure and no Elm code.
- **No Eco-heap allocation:** `Allocator::resolve` only follows forwarding words.
- **No C++ allocation in normal runs:** the only `std::vector` (`census::seen`, :224) and
  `std::atexit` (:291) are on the `ECO_HASH_CENSUS=1` diagnostic path (`census::enabled`, :228).
- **Total:** the walk is bounded (depth 16, 256 items) and each String is read once.
- **The result depends only on the argument's value** (the hash's definition).
- **The argument is only read.**

### 4.2 The row

In `compiler/src/Compiler/IR/Kernel/Facts.elm`, in `rows`, next to the `( "Eco", "Bitmap", … )` rows:

```elm
, ( ( "Eco", "FNV", "hash" )
    -- The value hash (design_docs/theory/runtime/value-hash.md): a bounded read-only walk that
    -- allocates nothing and never runs Elm code. Only the ECO_HASH_CENSUS=1 diagnostic path uses a
    -- std::vector; cppAlloc describes normal runs.
  , { auditedPure
        | params = [ PBorrowed ]
        , gcAlloc = GcNone
        , evidence = "system-kernel-cpp/src/eco-system/FNV/FNVExports.cpp:14-16; runtime/src/allocator/ValueHash.cpp:464-468 (eco_hash_value), :307 (Hasher), :224-233 (census only)"
    }
  )
```

### 4.3 What the row changes (each from a true fact; all measured in A6)

| consumer | effect |
|---|---|
| `InlineSimplify.kernelCallCost` | a `FNV.hash` call costs `kernelCostGcLeaf` (4) instead of 6 |
| `PreMono/EtaExpand.elm:1309` | a `CGcLeaf` call counts as cheap for eta-expansion |
| `GenerateMlir/Context.elm:971` | `FNV.hash` called as a function value is gc-leaf: no statepoint around it |
| `GenerateMlir/Ops.elm:683` | the direct kernel call gets `eco.cse_safe` (droppable) |
| `InlineSimplify` with `kernelFactsDce` | an unused `FNV.hash` binding is dropped |
| `MonoOpt/Borrow/KernelSigs.elm` | the argument is borrowed, not consumed (borrow inference is off by default, Config.elm:593: no default effect) |
| `MonoOpt/CsePurity` | the call is hoistable, so general CSE (`ECO_CSE`) may merge it, and A4's hash mode admits it |
| `CafHoist` | a hash of a constant could become a CAF (`cafMemo.hoist` is off by default, Config.elm:591: no default effect) |

### 4.4 Checks (A2)

1. `Compiler.IR.Kernel.FactsValidation`'s table check stays empty (its elm-test).
2. `cmake --build build --target elm-tests` passes; a test that pins inline decisions or kernel-fact
   counts is updated with the reason in its comment.
3. A grep confirms `Hasher::boxed`, `string`, `dict` and `slot` call no allocator entry (`eco_alloc`,
   `allocate`, `new`, `malloc`) outside `namespace census`.
4. The inline report (`ECO_INLINE_REPORT=1`) of the benchmark program: candidate and inlined-call
   counts before and after the row, recorded in §10.

## 5. Step A3: whitelist the wrappers

In `defaultWhitelist`, after A1:

```elm
-- eco/system SeqDict and SeqSet wrappers that hash the key and call the worker that takes the
-- hash: inlined, the FNV.hash call is in the caller, where the hash CSE (Compiler.MonoOpt.Cse)
-- merges it with another hash of the same key (plans/seqdict-hash-once-per-function.md).
-- `update` and `updateIfExists` already hash once.
, "eco/system:SeqDict.get"
, "eco/system:SeqDict.member"
, "eco/system:SeqDict.insert"
, "eco/system:SeqDict.remove"
, "eco/system:SeqSet.member"
, "eco/system:SeqSet.insert"
, "eco/system:SeqSet.remove"
```

Check: build, compile a copy of examples/benchmarks to text MLIR (`eco make src/Bench.elm
--output=<tmp>/bench.mlir --text-mlir`), and count `callee = @SeqDict_get_\|callee =
@SeqDict_insert_\|callee = @SeqDict_member_`: 38 → 2, as in the experiment.

## 6. Step A4: hash-only CSE in `Compiler.MonoOpt.Cse`

### 6.1 Behaviour

A new mode, `cse.hashMerge` (default **on**), merges repeated `FNV.hash` calls of one value in each
function body, using the pass's existing grouping, placement and safety rules, with two additions:

1. **Only hash calls are candidates** in this mode: `MonoCall _ (MonoVarKernel _ "Eco" "FNV" "hash" _)
   [ arg ] _ _`. `minCost` does not apply to them (a hash is always worth one binding).
2. **Aliases are seen through.** While `collect` descends, it keeps a scoped alias map: on
   `MonoLet (Mono.MonoDef n (MonoVarLocal m _)) body _`, `n` maps to the root of `m` (the map applied
   transitively) in `body` only. An occurrence's grouping `shape` is the call with regions zeroed
   **and every aliased local replaced by its root**, and its bound expression (`Group.bound`) is that
   canonical call, so `let mono_cse_<n> = FNV.hash node` is written with the root name. The scope
   rule then checks the canonical call's free locals (the roots) against the names bound below the
   LCA, so a root bound below the LCA blocks the group as today. Two rules keep the canonical name
   meaning the same variable as the alias it replaces (both found by the second review, §10):
   - **At every binder `x`** (a `let` of anything else, a destructuring name, a local tail
     function's name and parameters, a closure's parameters), the map loses `x` as a key **and every
     entry whose root is `x`**. The inliner renames `let` and destructuring names but not closure or
     tail-function parameters (InlineSimplify.elm:56-59), so a root name can be rebound below an
     alias; without the second deletion, `let a = k in (let go k = … hash a … hash k …)` would merge
     `hash a` (the outer `k`) with `hash k` (the parameter).
   - **The map is emptied when `collect` enters a closure body** (the `"c"` step, Cse.elm:544-545). A
     closure body sees only its parameters and its captures, fixed before CSE runs
     (`Closure.computeClosureCaptures`); a root resolved inside it could name a variable it does not
     capture, and a group whose occurrences are all inside one closure would bind it unbound.
3. **Cheap when there is nothing to do.** The pass has run only behind `ECO_CSE` until now; its path
   lists (`path ++ [tag]`, `List.length path`, Cse.elm:531-535) and the whole-graph purity analysis
   (`CsePurity.analyze`, :215) cost compile time. In `HashOnly` mode: (a) a body is skipped unless a
   pre-scan finds two or more hash calls in it; (b) a hash candidate is admitted only when its
   argument, after canonicalisation, is a local variable, and its purity is the kernel row's
   `KernelFacts.hoistableFor ( "Eco", "FNV", "hash" )` (a variable argument is trivially safe), so
   `CsePurity.analyze` is not run in this mode.

With `cse.enabled` on (general CSE), hash calls are candidates as well (the row makes them safe),
with the same alias resolution and without the `minCost` floor; general CSE's other candidates keep
today's rules. So: `hashMerge` on and `enabled` off (the default) merges hashes only; `enabled` on
merges everything it did plus hashes; both off changes nothing.

### 6.2 Code

`compiler/src/Compiler/MonoOpt/Cse.elm`:

1. Config type: `{ minCost : Int, maxPerDef : Int, mode : Mode }` with
   `type Mode = HashOnly | General` (General includes hashes). `run`, `rewriteNode`, `rewriteBody`,
   `formGroups`, `collect`, `collectDecider`, `admit` take it as now take `minCost`.
2. `isHashCall : MonoExpr -> Bool` for the pattern above (one argument).
3. `admit`: in `HashOnly`, accept only `isHashCall expr` whose canonical argument is a
   `MonoVarLocal`, and only when `KernelFacts.hoistableFor ( "Eco", "FNV", "hash" )` (6.1, 3b); in
   `General`, today's test, except that `isHashCall expr` skips the `cost < minCost` check. `run`
   skips `CsePurity.analyze` in `HashOnly` (pass a trivial oracle) and `rewriteBody` returns the body
   unchanged when a pre-scan counts fewer than two hash calls.
4. `collect` and `collectDecider` gain an `aliases : Dict Name Name` argument, extended in the
   `MonoLet` case as in 6.1 for the body step (`"u lb"`) only, never for the bound expression or
   sibling branches. A helper `unbind : Name -> Dict Name Name -> Dict Name Name` removes the name as
   a key and every entry whose value is the name; it is applied at every binder in its scope (the
   `MonoLet` name for both its bound expression and body when it is not an alias, the
   `MonoTailDef` name and parameters, every `destructBinders` name, a `MonoClosure`'s parameters),
   and the `MonoClosure` step passes `Dict.empty` (6.1).
5. `admit` receives `aliases` and computes `shape = canonicalize aliases (CafHoist.zeroRegions expr)`
   and `canonical = canonicalize aliases expr`, where `canonicalize` replaces each `MonoVarLocal n _`
   whose `n` is in the map with `MonoVarLocal root rootTy`, `rootTy` being the root's own type (the
   map stores `( root, rootTy )`, taken from the root `MonoVarLocal` when the alias is recorded).
   `CafHoist.kindTagOf` ignores arguments, so all hash calls share one bucket ("c:kFNV.hash", by
   result type Int) and the canonical shapes decide the groups. `Occ` gains `canonical : MonoExpr`;
   `formGroups` binds `first.canonical` and computes `free` from it. `Cse`'s exposing list
   (Cse.elm:1-4) adds `Mode(..)`.
6. `Stats` gains `hashGroups` and `hashMerged` (counted when the group's call is a hash call);
   `renderStats` prints them.

`compiler/src/Compiler/Config.elm`: `CseConfig` gains `hashMerge : Bool` (default `True`), decoded
from `cse.hashMerge`; the config hash gets the token `hcse=1` when it is on (as `hashIntrinsic` adds
`hash=1`, Config.elm:1294), so cached artifacts built without it are not reused.
`compiler/src/Builder/Eco/Config.elm`: `ECO_HASH_CSE`, read with `applyCseBoolOverride`
(Builder/Eco/Config.elm:702-720) as `applyHashCseOverride`: `1`/`true`/`yes`/`on` on,
`0`/`false`/`no`/`off` off, anything else leaves the setting as it is.

`compiler/src/Compiler/Pipeline/Steps.elm` (`cse`, :873-900):

```elm
( cseGraph, cseStats ) =
    if cseCfg.enabled then
        MonoCse.run { minCost = cseCfg.minCost, maxPerDef = cseCfg.maxPerDef, mode = MonoCse.General } goGraph

    else if cseCfg.hashMerge then
        MonoCse.run { minCost = cseCfg.minCost, maxPerDef = cseCfg.maxPerDef, mode = MonoCse.HashOnly } goGraph

    else
        ( goGraph, MonoCse.emptyStats )
```

and the CSE stats line: Builder/Generate.elm:1706-1708 prints `MonoCse.renderStats` whenever
`cse.enabled` is on. Change the condition to `cseCfg.report && (cseCfg.enabled || cseCfg.hashMerge)`,
so a default build prints nothing and `ECO_CSE_REPORT=1` prints the hash counts in either mode (7.2
relies on it). Today's `ECO_CSE=1` builds then print the line only with `ECO_CSE_REPORT=1`: say so in
docs/options.md.

### 6.3 Tests (A4)

**Unit test** `compiler/tests/Compiler/MonoOpt/CseTest.elm` (new; there is no Cse unit test yet).
Build Mono graphs by hand as `compiler/tests/Compiler/MonoOpt/CafHoistTest.elm:271` and
`CafDedupeTest.elm:256` do (`mkGraph`); `InlineSimplifyTest.elm` is not a template (it compiles
Source modules through `Pipeline.runToMono`). Each case asserts the number of `FNV.hash` calls left
and of `mono_cse_` bindings:

| case | expected |
|---|---|
| `let a = k in let b = k in pair (hash a) (hash b)` | one hash, bound as `hash k` |
| alias chain `let a = k in let b = a in (hash a, hash b)` | one hash |
| get-then-insert: hash in a `let` bound before a `case`, another in a `case` branch | one hash |
| hashes only in two sibling branches of a `case` | two (no unconditional occurrence) |
| `hash a` and `hash c` with different roots | two |
| a hash inside a closure body and one outside | two |
| `a` bound to `k` in one branch and to `j` in another, `hash a` in each | two (scoped aliases) |
| `a` aliased to `k`, then shadowed by `let a = other`, `hash a` before and after | two |
| inlined closure body: `\v -> g (hash a) (hash a)` with `a` aliased to `node` outside, `a` captured | merged inside the closure as `hash a`, never `hash node` |
| root shadowed by a tail-def parameter: `let a = k in let go k = … (hash a) … (hash k)` | two |
| root shadowed by a closure parameter: `let a = k in \k -> (hash a, hash k)` | two |
| a body with one hash call | unchanged, and the pre-scan skips it |
| a hash of a non-variable argument (`hash (f x)`) in `HashOnly` | not a candidate |
| a repeated pure non-hash call, `HashOnly` | not merged |
| the same, `General` | merged as today |

Negative controls (run once, not committed): a global (unscoped) alias map fails the sibling-branch
alias case; dropping the root deletion in `unbind` fails the tail-def and closure-parameter cases;
keeping the map inside closures fails the closure case; canonicalising without the root check fails
the different-roots case.

**E2E test** `test/eco-system/src/SeqDictHashOnceTest.elm` (both backends):

- `probe`-shaped: `case SeqDict.get k d of Just v -> … ; Nothing -> SeqDict.insert k v d`, over
  custom-type tree keys, `( String, Int )` tuple keys with long Strings, record keys, String keys and
  the colliding Strings `c600662`, `c5330492`, `c11005860`;
- `SeqDict.member k d1 && SeqDict.member k d2 && SeqDict.member k d3`, keys present in some dicts;
- `SeqSet.insert` then `SeqSet.member` of one key;
- `-- ENV: ECO_SEQDICT_VALIDATE=1`; CHECK lines with the results.

No "off" twin: `-- ENV:` reaches only the process that runs the compiled program, not the compile
(ElmE2ETestBase.hpp:1478-1486; the compile command sets only `GUIDA_JS_PATH`, :387-393, :534-535), and
the `.mlir` cache is keyed on mtime only (`needsRecompile`, :497-504), so an `ECO_HASH_CSE=0` twin
would compile with the merge on and pass either way. The E2E test therefore checks semantics only
(results, under the validator). The merge itself is shown by the unit test (structure) and by the
stats line on the benchmark program (7.2: `ECO_CSE_REPORT=1` must report the hash group in
`SeqLargeKeys.probe` and in seqdict-multi-lookup). `-- CHECK-MLIR:` is not used: `CHECK-MLIR-NOT` is
global over the module (CheckPatterns.hpp), and the SeqDict internals specialised for the same key
type contain hashes of their own, so no pattern can count the hashes of one function. The test's
header says this.

**Regression suites:** `cmake --build build --target elm-tests`; `build/test/test --filter
eco-system/SeqDict`, `--filter eco-system/SeqSet`, `--filter eco-system/Hash`; the JS E2E filter for
the new tests.

## 7. Steps A5/A6: measure and document

### 7.1 Build note

Front-end changes reach the native `eco` binary only through `cmake --build build --target bootstrap`.
The E2E tests use the build's own compiler; the benchmarks use `build/compiler/build-kernel/bin/eco`,
so run `bootstrap` before each measurement below.

### 7.2 Measurements (A6), each recorded in §10

| point | what |
|---|---|
| base | whole suite (see "Scripts" below) into `local-dev/hashonce-base-bench.json`; inline report counts |
| after A1 | the inline report: candidate and inlined counts must equal the base's (A1 changes no decision) |
| after A2 | whole suite `hashonce-facts-bench.json`; inline report counts (the row's own effect) |
| after A3 | whole suite `hashonce-inline-bench.json`; binary size |
| after A4 | whole suite `hashonce-bench.json`; `ECO_CSE_REPORT=1` hash groups merged in the benchmark program |

Scripts: `bench-full.sh` and `ab.sh` live only in /tmp/seqwork (a session's scratch). Their content
is: wipe `examples/benchmarks/eco-stuff`, run `ECO=<eco wrapper> node run.mjs --skip-elm` (all
workloads) from `examples/benchmarks`, and copy `build/results.json` with a header (date, eco binary
and build time, host) into the named file; `ab.sh` builds the benchmark binary for a tree and copies
it aside, then the two binaries run alternately with `--json --warmup 3 --runs 11 <workload>=<size>`,
five alternations, medians. Recreate them, or add them to `examples/benchmarks/` as part of A6.

Plus: a new workload **seqdict-multi-lookup** (`examples/benchmarks/src/SeqLargeKeys.elm`,
registered in `Bench.elm`, added before the base run): 40,000 type-tree keys (`TypeKeys`) looked up in
three SeqDicts with `member k d1 && member k d2 && member k d3`, then `get` and `insert` on a miss;
checked in closed form like its neighbours. Any workload moving more than 5 % between two points is
re-measured with interleaved runs of the two binaries (`/tmp/seqwork/ab.sh`). Compiler cold
self-build (`--no-cache`, eco-stuff moved aside), N = 3, at base and after A4 (cost check).

### 7.3 Docs (A5)

- `compiler/src/Compiler/Config.elm`: the `InlineConfig` docstring (qualified names), the
  `CseConfig` docstring (`hashMerge`).
- `docs/options.md`: the `inline.whitelist` / `inline.blacklist` row (qualified form; it also cites a
  stale `MonoInlineSimplify.elm:990`), a `cse.hashMerge` row, an `ECO_HASH_CSE` row.
- `Compiler.MonoOpt.Cse` module docstring: the two modes, alias resolution.
- `design_docs/invariants.csv` CGEN_095: hashes of one value are merged per function in Mono
  (`cse.hashMerge`), and the SeqDict/SeqSet wrappers are inlined natively.
- `design_docs/invariants.csv` **CSE_001** (:668), which says the pass is "DEFAULT-OFF, ECO_CSE=1"
  and binds "the ORIGINAL first-occurrence subtree verbatim": amend for the default-on hash mode, the
  canonical (alias-resolved) bound expression, and the alias rules of 6.1 (cleared in closures, root
  deletion at binders). Its NaN clause does not apply to hash calls (an Int result).
- `design_docs/theory/runtime/value-hash.md`: one paragraph on the merge.
- `system-kernel-cpp/src/SeqDict.elm` module comment: callers get one hash per key per function.

Exit: A1-A4 tests green, the measurements of 7.2 recorded, docs updated, and the full gate before the
commit (the user runs it, or asks for it).

## 8. Expected result

- Every native SeqDict/SeqSet `get`, `member`, `insert`, `remove` call becomes inline code plus one
  worker call.
- A function that uses one key in several such operations hashes it once, whatever the key's type
  (tuple and record keys included). In the current benchmark program that is one function:
  seqdict-intern −5 %; seqdict-multi-lookup shows the case the change is for.
- `FNV.hash` has a true `KernelFacts` row with the effects of §4.3.
- Inliner whitelists and blacklists name functions exactly, for every list present and future.
- No change on JS, no change to any hash value, no heap or runtime change.

## 9. Risks

- **A wrong merge** (two different values given one hash) is a silent miss or a broken trie. The
  alias map is the new part; scoping and shadowing are covered by the unit cases and negative
  controls, semantics by the E2E test under the validator.
- **The row's wider effects** (§4.3) change inlining prices; measured on their own (7.2, after A2).
- **Code growth** at every inlined wrapper call (+7.6 KB on the benchmark program).
- **Bare names in user configs** change meaning (program only); none in the repository; the
  `inline.report` diagnostic points at the qualified form.

## 10. Progress log

- **2026-11-24 Plan reviewed and lowered** (first review, §2): experiment and measurements of §1.
- **2026-11-24 Plan revised** (user decisions, §2): fully qualified whitelist names; compulsory
  `KernelFacts` row; Mono hash-only CSE with alias resolution instead of the MLIR pass.
- **2026-11-24 Second adversarial review** (independent reader, against the code; spot-checked) and
  corrections applied:
  1. Aliases followed into a closure body could name an uncaptured variable → map emptied at closures.
  2. A root rebound by a tail-def or closure parameter (not renamed by the inliner) could merge two
     different values → `unbind` also removes entries whose root is the binder; closure parameters
     are binders.
  3. An `ECO_HASH_CSE=0` E2E twin tests nothing (`-- ENV:` reaches only the run, `.mlir` cache keyed
     on mtime) → dropped; structure shown by the unit test and the stats line (CHECK-MLIR-NOT is
     global, so the E2E test checks semantics only).
  4. `Mlir.Bytecode.*` is the package `the-sett/elm-mlir`, not the compiler's code → qualified.
  5. A parser in a MonoOpt module imported by `Config` would make a folder cycle → parser in
     `Compiler.Config`.
  6. CSE_001 must be amended (default-on mode, canonical binding).
  7. The stats line printed whenever CSE was enabled → now only under `cse.report`.
  8. The unit-test template is `CafHoistTest`/`CafDedupeTest` (`mkGraph`), not `InlineSimplifyTest`.
  9. Compile time of a default-on pass → pre-scan and no whole-graph purity analysis in `HashOnly`.
  10. `MonoGraph.main` is never absent → that branch dropped.
  11. Minor: `RewriteCtx.whitelist` type; root type in canonicalisation; `ECO_HASH_CSE` values follow
      `applyCseBoolOverride`; `borrow` and `cafMemo.hoist` are off by default (no default effect of
      the row there); the measurement scripts were only in /tmp.

- **2026-11-24 Implemented (A1-A5).** Baseline `local-dev/pre-hash-inline-bench.json` (108
  workloads, all ok, with the new seqdict-multi-lookup at 40,000 keys: 334 ms native) and base
  compiler self-build (cold, 3 runs: 1:09-1:11 wall, 7.6-7.8 GB peak RSS) taken before any change.
  - A1: `parseInlineName` / `InlineName` in `Compiler.Config`; `InlineSimplify` resolves entries to
    `( author/project, Module, name )` (`resolveInlineNames`, `isWhitelisted`, root package from
    `main`); built-in entries qualified (`elm/bytes:`, `the-sett/elm-mlir:`, `Utils.Bytes.*` bare);
    the pipeline blacklist is `elm/core:List.*`; `unmatchedBareNames` warns under the inline report.
    **Deviation:** a malformed config entry is dropped with a warning by `Config.clamp` (the
    existing convention for bad values), not a decode failure: `Config.decoder` is polymorphic in
    its error type and cannot carry a message.
  - A2: the `FNV.hash` row; FactsTest's pinned audited sets (borrow shim, gc-leaf stampable, table
    size 77 → 78) updated for it, as those tests require.
  - A3: the seven `eco/system:` wrappers in `defaultWhitelist`.
  - A4: `Cse.Mode` (`General` / `HashOnly`), scoped alias resolution (`Aliases`, `unbind`,
    `bodyAliases`, map emptied in closures), canonical binding, `HashOnly` pre-scan and no purity
    analysis, `hashGroups` / `hashMerged`; `cse.hashMerge` (default on, token `hcse=1`),
    `ECO_HASH_CSE`; the `mono-cse:` line now prints only under `cse.report`.
  - A5: CSE_001 and CGEN_095 (also: hash definition v2 → v3, stale), docs/options.md, value-hash.md,
    the SeqDict module docs.
  - Tests: elm-tests 918 + 22,136 pass (CseTest 19, InlineSimplifyWhitelistTest 7, ConfigTest inline
    names); negative controls each caught (non-alias let keeps aliases → 1 failure; unbind keeps root
    entries → tail-def case fails; closures keep the map → 2 failures; no alias resolution → 5
    failures); folder-cycle check 0/0; native E2E eco-system SeqDict 12/12 (with
    SeqDictHashOnceTest), SeqSet 1/1, Hash 4/4; JS 15 pass + 2 skipped; bootstrap (4b, 8c) green.
  - Benchmark program, new compiler: `mono-cse: … hashGroups=2 hashMerged=5` (`probe`: 2 hashes → 1;
    seqdict-multi-lookup: 5 → 1). Inlines 2,536 → 2,627: exactly the wrappers (SeqDict.insert 20,
    get 14, member 10, SeqSet.insert 1, SeqDict.remove 1) and the `FNV.hash` wrapper inside them
    (18 → 63); every other callee unchanged, `List.map` 134 and the chunk functions 0 as at base
    (the qualified pipeline blacklist matches), elm/bytes counts equal. So the row changed no other
    inlining decision in this program.

- **2026-11-24 Benchmarks (A6, trimmed by the user to one run).** `local-dev/post-hash-inline-bench.json`
  (warmup 1, runs 5; the baseline had warmup 3, runs 11), all 108 ok, 7 minutes. Native:
  seqdict-multi-lookup 324 → 254 ms (−22 %), seqdict-intern 334 → 315 (−6 %), seqdict-update
  153 → 134 (−12 %, not a merge site: likely noise or the inlined wrappers around it); the other
  SeqDict/SeqSet workloads within ±6 % except seqdict-collide 10 → 16 ms (1 ms resolution, not
  re-checked); geometric mean of the non-Seq workloads +0.9 %, with ±7-14 % moves both ways on
  workloads that never hash (fib −12 %, set-float-pairs +14 %): noise of a 5-run suite. JS
  unchanged by design (+1.7 % overall, noise). The variant runs (merge off, wrappers blacklisted)
  and the compiler self-builds after the change were dropped (user); the base self-build is
  recorded above.

## 11. Relation to plans/hash-reuse-explicit-vs-cached.md

Independent. With that plan's `Hashed` keys a program already hashes once, so nothing is left to
merge on those calls; with its String cache a repeated hash is a cache read, so merging saves less.
To keep that plan's base fixed, do this plan either before its base is recorded or after its choice
is made, not between.

## 12. Later: review the compiler-specific whitelist entries

Not part of this plan; to look into after it is implemented (user, 2026-11-24). `defaultWhitelist`
holds entries that tune one program, not general rules:

- `Mlir.Bytecode.VarInt.encodeVarInt`, `encodeSignedVarInt`, `Mlir.Bytecode.Section.encodeSection`:
  functions of the package `the-sett/elm-mlir`, whitelisted when that code was still inside the
  compiler (plans/bytes-fusion-broader-recognition.md); `encodeVarInt` is no longer small. A1 only
  qualifies them (`the-sett/elm-mlir:…`).
- `Utils.Bytes.Encode.*` / `Utils.Bytes.Decode.*`: the compiler's own modules (bare names after A1).

Measure the compiler's cold self-build with and without them; then either delete them or move them
into a `compiler/eco-config.json` (`inline.whitelist`, qualified), so that the built-in list keeps
only general rules (elm/bytes, eco/system).

