# Phantom-Typed Integer IDs for All Compiler Identifiers

## Goal

Replace all string-based identifier representations (`Name` / `String`) in the compiler's IR with phantom-typed integer IDs (`type Id a = Id Int`). This eliminates:
- String-based type variable renaming (`__def_`, `__callee` prefixes)
- Costly string comparisons in Dict/Set operations on hot paths
- Repeated string allocations across IR nodes

The user-visible `Name` strings are retained in side tables (intern tables, `FreeVars`, `GlobalTable`) for diagnostics and serialization.

## Current State

- **All identifiers are `Name` (= `String`)** throughout Canonical, Optimized, TypedOptimized, Monomorphized IRs.
- **No `Id.elm` or `Intern.elm` modules exist.**
- **Type variable renaming** uses string manipulation: `buildPreRenameMap` produces `a__def_Module_func_0` names, `buildRenameMap` produces `a__callee42_0` names, `applyReverseRenaming` maps them back. All in `TypeSubst.elm` and `Specialize.elm`.
- **`Substitution`** = `Dict Name Mono.MonoType`, **`VarEnv`** = list of such dicts.
- **`SchemeInfo`** carries `preRenameMap : DataMap.Dict String Name Name`, `renamedVarNames`, `renamedFuncType`, `renamedArgTypes`, `renamedResultType`.
- **Record fields** keyed by `String` in `Data.Map.Dict String (A.Located Name)`.
- **Globals** are `Global IO.Canonical Name`, graphs keyed by comparable `List String`.
- **`RecordStructure`** = `Dict String Name.Name IO.Variable`.
- **`TypeTableAccum.ctorShapes`** keyed by `String`.
- **`Tracker`** in Dups.elm = `Dict Name (OneOrMore (Info value))`.
- **`Cycle`** = `EverySet String Name`.
- **261 files** use `Dict String`, **70 files** use `EverySet String`.

---

## Design Decisions

### D1. GlobalInfo is not `comparable` — how to key the global intern table?

**Decision: Key by an existing comparable *derived key* (`GlobalKey = List String`), not by `GlobalInfo` itself.**

- Keep `GlobalInfo = { home : IO.Canonical, name : Name }` as the *value* stored in the intern table's forward array.
- Use the existing `toComparableGlobal : Global -> List String` encoding as the *key* in the reverse dict:
  ```elm
  type alias GlobalKey = List String  -- from TOpt.toComparableGlobal / Opt.toComparableGlobal

  type alias GlobalInternTable =
      { next : Int
      , forward : Array GlobalInfo      -- index -> GlobalInfo
      , reverse : Dict GlobalKey Int    -- GlobalKey -> index
      }
  ```
- To intern: `internGlobal : GlobalKey -> GlobalInfo -> GlobalInternTable -> ( GlobalId, GlobalInternTable )`
- This avoids needing `GlobalInfo` to be `comparable`; only `GlobalKey` (`List String`) is required, which already is and is already used as a key in `GlobalGraph`.

### D2. Cross-module ID stability

**Decision: IDs are per-compilation *ephemeral*; they are NOT stable across compilations or stored in `.elmi`.**

- `.elmi` format stays unchanged (module names + `Name` strings).
- When loading `.elmi` for dependencies, we immediately **intern** names into the current run's ID tables.
- On the next build, the same module's names may receive different integer IDs, and that's fine.
- All ID tables (`GlobalId`, `FieldId`, `TypeNameId`, etc.) are rebuilt each compilation.
- Determinism is preserved as long as interning is deterministic (driven by sorted order or stable module traversal order).

### D3. `Data.Map.Dict String` in record updates

**Decision: Replace `Dict String ...` for record fields with `IdDict FieldPh ...` (`Dict Int ...`); accept Int-based ordering.**

- Canonical record types and record expressions switch to `FieldId` keys.
- The constraint generator builds `Dict Int (IO.Variable, Type, Constraint)` instead of `Dict String ...`.
- The unifier's `RecordStructure` becomes `RecordStructure (Dict Int IO.Variable) IO.Variable` with `FieldId`-aware helpers.
- `Dict Int` ordering is deterministic. The field interner assigns `FieldId`s deterministically: the first time a field name is seen in the build, it gets the next available `Int`; all later uses reuse that `FieldId`.
- Code needing the textual field name goes through `FieldNameTable : Array Name` to map `FieldId -> Name`.

### D4. `IO.Variable` vs `TVarId`

**Decision: `IO.Variable` stays the sole identity for the unifier; `TVarId` is post-inference only.**

- Unification core remains written around `IO.Variable` (union-find) and `IO.Descriptor`. No changes there.
- `TVarId` is used in:
  - Canonical `TVar` / type schemes
  - Substitutions (`Dict Int Can.Type` instead of `Dict String`)
  - Monomorphization's `SchemeInfo`, `Substitution`, `VarEnv`
- Boundary: when building constraints, each syntactic type variable (`TVarId`) is mapped to `IO.Variable`s internally in the solver. When extracting finished types from the solver, we reconstruct Canonical types with `TVarId`s via an interning step and never expose `IO.Variable` outside.
- We may maintain an internal map `Dict IO.Variable TVarId` only where needed for PostSolve, but we do NOT change `IO.Variable`'s definition.

### D5. `IdSupply` scope

**Decision: Per-compilation, per-ID-class supplies.**

Two families:

1. **Cross-module IDs** (`FieldId`, `TypeNameId`, `UnionId`, `CtorId`, `GlobalId`):
   - One `IdSupply` per phantom type for the whole compilation.
   - Lives in a top-level compilation context:
     ```elm
     type alias AllIdSupplies =
         { field    : IdSupply FieldPh
         , typeName : IdSupply TypeNamePh
         , union    : IdSupply UnionPh
         , ctor     : IdSupply CtorPh
         , global   : IdSupply GlobalPh
         }
     ```
   - Loading `.elmi` for dependencies also interns into these supplies, so `"fieldX"` used in a dependency gets the same `FieldId` as `"fieldX"` in the root package.

2. **Module-local IDs** (`LocalVarId`, `TVarId`):
   - Per-compilation supplies but scoped to module/function optimization contexts.
   - `LocalVarId` supply threaded through Canonical -> Optimized -> TypedOptimized -> Mono passes for each module.

### D6. Shader `EverySet String Name`

**Decision: Leave as strings; do not introduce IDs for shader attribute/uniform names.**

- These are part of the GLSL ABI — must be emitted as exact strings.
- No renaming or alpha-conversion applies; they are externally fixed names.
- Sets are tiny (dozens at most) and not on hot paths.
- Conversion to `Id` would add complexity without benefit.

---

## Implementation Plan

### Phase 1: Core Infrastructure (no IR changes)

**Step 1.1: Create `Compiler.Data.Id`**
- New file: `compiler/src/Compiler/Data/Id.elm`
- Define `type Id a = Id Int`, `toInt`, `IdSupply`/`initialSupply`/`fresh`
- Define `IdSet a` (wrapping `Set Int`): `emptySet`, `setInsert`, `setMember`, `setToList`, `setFromList`, `setSize`, `setUnion`, `setDiff`
- Define `IdDict a v` (wrapping `Dict Int v`): `emptyDict`, `dictInsert`, `dictGet`, `dictRemove`, `dictMember`, `dictFoldl`, `dictMap`, `dictKeys`, `dictValues`, `dictToList`, `dictFromList`, `dictSize`, `dictUnion`, `dictIntersectWith`, `dictDiff`
- **Test**: Unit tests for Id, IdSet, IdDict operations

**Step 1.2: Create `Compiler.Data.Intern`**
- New file: `compiler/src/Compiler/Data/Intern.elm`
- Define `InternTable a comparable` with `Array` (index->value) + `Dict` (value->index)
- Operations: `empty`, `intern`, `lookup`, `size`, `toList`
- Constraint: `intern` requires `comparable` values for the reverse lookup key
- Note: For cases where the value is not `comparable` (e.g., `GlobalInfo`), accept a separate comparable key parameter — see `internWithKey` variant or the `GlobalInternTable` pattern from D1
- **Test**: Unit tests for interning, deduplication, round-trip lookup

**Step 1.3: Create `AllIdSupplies` compilation context**
- Define the top-level supply holder per D5
- Wire into the compilation driver so it's available to all phases

**Checkpoint**: Both modules compile, have tests, and are not yet imported anywhere.

---

### Phase 2: Type Variables (`TVarId`)

**Step 2.1: Define `TVarId` in Canonical**
- In `Compiler/AST/Canonical.elm`: add `type TVarPh = TVarPh`, `type alias TVarId = Id.Id TVarPh`
- Change `Type`: `TVar Name` -> `TVar TVarId`
- Change `FreeVars`: `Dict Name ()` -> `Dict TVarId Name` (maps ID to display name)
- Change `Annotation`: `Forall FreeVars Type` (unchanged shape, new FreeVars type)
- Update `typeEncoder`/`typeDecoder` to encode `TVarId` as `Int`
- Update `freeVarsEncoder`/`freeVarsDecoder` to encode `(TVarId, Name)` pairs

**Step 2.2: Update type inference to produce `TVarId`**
- Thread `IdSupply` through `Compiler/Type/PostSolve.elm`
- Where PostSolve fabricates `Can.TVar "a"` / `"ext"` for accessors, allocate fresh `TVarId`s instead
- Store display names in `FreeVars`
- Per D4: `IO.Variable` stays unchanged in the unifier; `TVarId` is assigned only when extracting solved types
- Update `Compiler/Type/Unify.elm` only if it directly creates `Can.TVar` (it shouldn't need to per D4)

**Step 2.3: Update all consumers of `Can.Type` for `TVar`**
- Grep for `Can.TVar` and `TVar` pattern matches across the codebase
- Update each site to work with `TVarId` instead of `Name`
- Key files: `Compiler/Type/Constrain/*.elm`, `Compiler/Type/Solve.elm`, any error reporters that display type var names (look up in `FreeVars`)

**Step 2.4: Convert monomorphizer to `TVarId`**
- `State.elm`: `Substitution` -> `Dict TVarId Mono.MonoType`, `VarEnv` -> `VarEnv (List (Dict TVarId Mono.MonoType))`
- `SchemeInfo`: remove `renamedFuncType`, `renamedArgTypes`, `renamedResultType`, `renamedVarNames`, `preRenameMap`; keep `varNames : List TVarId`, `constraints : Dict TVarId Mono.Constraint`
- `TypeSubst.elm`: delete `buildPreRenameMap`, `renameCanTypeVarsInternal`, `applyReverseRenaming`; `collectCanTypeVars` -> `collectTVarIds`; `buildSchemeInfo` simplified (no renaming step)
- `Specialize.elm`: simplify `unifyCallSiteWithRenaming` — no `buildRenameMap`, no `__callee`/`__def_` renaming, no `renameEpoch`. TVarIds are already unique, so callee/caller scopes don't conflict.
- Remove `renameEpoch` from `SpecContext`

**Checkpoint**: All type variable operations use `TVarId`. String-based renaming is fully removed. Compiler builds and passes `elm-test-rs`.

---

### Phase 3: Local Variables (`LocalVarId`)

**Step 3.1: Define `LocalVarId` in Canonical**
- In `Compiler/AST/Canonical.elm`: add `type LocalVarPh = LocalVarPh`, `type alias LocalVarId = Id.Id LocalVarPh`
- Change `Expr_`: `VarLocal Name` -> `VarLocal LocalVarId`
- Change `Pattern_`: `PVar Name` -> `PVar LocalVarId`, `PAlias Pattern Name` -> `PAlias Pattern LocalVarId`
- Change `Def`: `Def (A.Located Name)` -> `Def (A.Located LocalVarId)`, same for `TypedDef`
- Add a name table (`Dict LocalVarId Name` or `InternTable LocalVarPh Name`) to module data for diagnostics
- Per D5: `LocalVarId` supply is per-compilation but threaded through module compilation contexts

**Step 3.2: Update canonicalization**
- `Compiler/Canonicalize/Expression.elm`: thread `IdSupply` + `Dict Name LocalVarId` env
- `bindLocal` allocates fresh `LocalVarId`, stores `Name -> LocalVarId` mapping
- `VarLocal` lookup resolves `Name` -> `LocalVarId` from env
- `FreeLocals` changes from `Dict Name Uses` to `Dict LocalVarId Uses`
- Update pattern canonicalization similarly

**Step 3.3: Propagate to Optimized IR**
- `Compiler/AST/Optimized.elm`: `VarLocal Name` -> `VarLocal LocalVarId`, `Root Name` -> `Root LocalVarId`, `Field Name Path` -> keep as `Name` for now (fields are Phase 4)
- Update `Def`, `TailDef`, `Function`, `TrackedFunction`, `TailCall`, `Case`, `Destruct`
- Update all optimization passes in `Compiler/LocalOpt/` and `Compiler/GlobalOpt/`

**Step 3.4: Propagate to TypedOptimized IR**
- `Compiler/AST/TypedOptimized.elm`: mirror Optimized changes with `LocalVarId`
- Update `TOpt.Expr`, `TOpt.Def`, `TOpt.Path`

**Step 3.5: Propagate to Monomorphized IR**
- `Compiler/AST/Monomorphized.elm`: `MonoVarLocal Name MonoType` -> `MonoVarLocal LocalVarId MonoType`
- Update `MonoDef`, `MonoPath`, closure captures
- `MonoInlineSimplify.elm`: `countUsages`, `inlineVar`, `substitute` all switch from `Name` to `LocalVarId`

**Checkpoint**: All local variable references use `LocalVarId`. Compiler builds and passes tests.

---

### Phase 4: Record Fields (`FieldId`)

**Step 4.1: Define `FieldId` in Canonical**
- In `Compiler/AST/Canonical.elm`: add `type FieldPh = FieldPh`, `type alias FieldId = Id.Id FieldPh`
- Add `FieldTable` (= `InternTable FieldPh Name`) to module data
- Per D5: `FieldId` supply is per-compilation (cross-module), so `FieldTable` lives in `AllIdSupplies` context
- Change `TRecord`: `Dict.Dict Name FieldType` -> `Dict.Dict FieldId FieldType` (per D3: `Dict Int` ordering is deterministic)
- Change record extension: `Maybe Name` -> `Maybe TVarId` (if not already done in Phase 2)
- Change `Accessor`, `Access`, `Update`, `Record` expr variants

**Step 4.2: Update canonicalization for fields**
- When canonicalizing `.field`, `{ field = ... }`, record updates: intern field name -> `FieldId` via `FieldTable`
- Thread `FieldTable` through canonicalization
- Per D3: deterministic interning order — first occurrence of a field name gets the next available `Int`

**Step 4.3: Update HM unifier**
- `Compiler/Type/Unify.elm`: `RecordStructure` from `Dict String Name.Name IO.Variable` to `RecordStructure (Dict Int IO.Variable) IO.Variable` with `FieldId`-aware helpers (per D3)
- Update `unifyRecord`, `gatherFields`, field equality checks
- `mapIntersectionWith`, `Dict.diff` etc. now operate on `Dict Int` — same API, faster comparison

**Step 4.4: Propagate to Optimized, TypedOptimized**
- `Optimized.elm`: `Accessor Name` -> `Accessor FieldId`, `Access Expr Name` -> `Access Expr FieldId`
- Per D3: `Data.Map.Dict String (A.Located Name) Expr` for record updates/tracked records -> `IdDict FieldPh Expr` (accept Int-based ordering)
- `Path`: `Field Name Path` -> `Field FieldId Path`
- Mirror in TypedOptimized

**Step 4.5: Propagate to Monomorphized and TypeTable**
- `MRecord (Dict Name MonoType)` -> `MRecord (Dict FieldId MonoType)`
- `MonoPath.Field Name` -> `MonoPath.Field FieldId`
- `TypeTable.elm`: field handling uses `FieldId`; string name lookup via `FieldTable` (forward array) for MLIR emission
- `CtorShape`: if it has field names, update those too

**Checkpoint**: All record field references use `FieldId`. Tests pass.

---

### Phase 5: Globals (`GlobalId`)

**Step 5.1: Create `Compiler.AST.GlobalTable`**
- New file with `GlobalInfo = { home : IO.Canonical, name : Name }` and `GlobalInternTable` per D1:
  ```elm
  type alias GlobalInternTable =
      { next : Int
      , forward : Array GlobalInfo      -- index -> GlobalInfo
      , reverse : Dict GlobalKey Int    -- GlobalKey -> index
      }
  ```
- `GlobalKey = List String` (reuses existing `toComparableGlobal`)
- Operations: `empty`, `internGlobal`, `lookup`
- Per D5: lives in `AllIdSupplies` compilation context

**Step 5.2: Define `GlobalId` in Optimized**
- `type GlobalPh = GlobalPh`, `type alias GlobalId = Id.Id GlobalPh`
- `Global` changes from `Global IO.Canonical Name` to `Global GlobalId`
- `GlobalGraph` keyed by `GlobalId` instead of comparable `List String`
- Per D2: when loading `.elmi`, immediately intern globals into the compilation's `GlobalInternTable`

**Step 5.3: Propagate to TypedOptimized**
- `TOpt.Global` -> uses `GlobalId`
- All typed optimization passes update accordingly

**Step 5.4: Propagate to Monomorphized**
- `Mono.Global` -> `Global GlobalId | Accessor FieldId`
- `SpecKey` uses `GlobalId`
- `SchemeInfoCache` keyed by `GlobalId` instead of `List String`
- State registries and call graph maps use `GlobalId`

**Checkpoint**: All global references use `GlobalId`. Tests pass.

---

### Phase 6: Type Names, Unions, Constructors (`TypeNameId`, `UnionId`, `CtorId`)

**Step 6.1: Define IDs in Canonical**
- `type TypeNamePh = TypeNamePh`, `type alias TypeNameId = Id.Id TypeNamePh`
- `type UnionPh = UnionPh`, `type alias UnionId = Id.Id UnionPh`
- `type CtorPh = CtorPh`, `type alias CtorId = Id.Id CtorPh`
- Add intern tables for each to `AllIdSupplies` compilation context (per D5: cross-module)

**Step 6.2: Update Canonical types**
- `TType IO.Canonical Name (List Type)` -> `TType IO.Canonical TypeNameId (List Type)`
- `TAlias IO.Canonical Name ...` -> `TAlias IO.Canonical TypeNameId ...`
- `UnionData`, `CtorData`, `Pattern_ PCtor` updated with `TypeNameId`/`CtorId`

**Step 6.3: Update canonicalization**
- Type/constructor name resolution interns names -> IDs via compilation-level intern tables
- Pattern matching on constructors uses `CtorId`

**Step 6.4: Propagate to Mono and TypeTable**
- `MCustom IO.Canonical Name (List MonoType)` -> `MCustom IO.Canonical TypeNameId (List MonoType)`
- `TypeTableAccum.ctorShapes`: `Dict String (List Mono.CtorShape)` -> `Dict TypeNameId (List Mono.CtorShape)`
- `CtorShape.name` -> `CtorShape.ctorId : CtorId` (with name lookup via intern table)

**Step 6.5: Update exhaustiveness/decision trees**
- Pattern matching decision trees use `CtorId` for branch discrimination

**Checkpoint**: All type/union/constructor references use integer IDs. Tests pass.

---

### Phase 7: Cross-Phase Sets and Duplicate Tracking

**Step 7.1: Cycle sets**
- `Compiler/LocalOpt/Erased/Expression.elm`: `Cycle` from `EverySet String Name` to `IdSet GlobalPh`

**Step 7.2: Duplicate tracker**
- `Compiler/Canonicalize/Environment/Dups.elm`: `Tracker value` from `Dict Name (OneOrMore (Info value))` to parametric `Tracker id value = IdDict id (OneOrMore (Info value))`
- Instantiate per use site: `Tracker LocalVarPh value`, `Tracker FieldPh value`, `Tracker TypeNamePh value`

**Step 7.3: Localizer / exposing sets**
- `Compiler/Reporting/Render/Type/Localizer.elm`: `Exposing` from `EverySet String Name` to `IdSet GlobalPh` (or `IdSet TypeNamePh` depending on what's exposed)

**Step 7.4: Any remaining `EverySet String Name` usages**
- Grep for `EverySet String` and convert remaining instances
- Per D6: **exclude** shader-related `EverySet String Name` (GLSL attribute/uniform names stay as strings)

**Checkpoint**: All cross-phase sets use `IdSet`. Full test suite passes.

---

### Phase 8: Cleanup and Verification

**Step 8.1: Remove dead code**
- Delete `buildPreRenameMap`, `renameCanTypeVarsInternal`, `applyReverseRenaming`, `buildRenameMap`
- Delete `__def_`/`__callee` string manipulation
- Remove `renameEpoch` from `SpecContext`
- Remove unused `SchemeInfo` fields

**Step 8.2: Encoding/decoding audit**
- Per D2: `.elmi` format stays unchanged (name strings); IDs are not serialized
- Verify intern tables are rebuilt correctly on load
- Verify round-trip: serialize with names -> load -> intern -> correct IDs

**Step 8.3: Error message audit**
- Verify all user-facing error messages still show human-readable names by looking up IDs in intern tables / `FreeVars` / `GlobalTable`
- Per D4: error paths near the unifier still use `IO.Variable` directly; only post-inference paths need `TVarId -> Name` lookup

**Step 8.4: Performance verification**
- Run `cmake --build build --target full` for E2E
- Run `cd compiler && npx elm-test-rs --project build-xhr --fuzz 1` for front-end
- Compare compile times on a representative project before/after

---

## Remaining Open Issues

1. **Migration size**: 261 files use `Dict String` and 70 use `EverySet String`. Not all are identifier-related (some are genuine string-keyed data like module name lookups). Need to carefully distinguish identifier-keyed uses from genuinely string-keyed uses during each phase.

2. **`Data.Map.Dict` vs `Dict`**: The codebase uses both `Data.Map.Dict String k v` (a custom ordered dict with explicit comparison) and `Dict k v` (Elm's built-in). When switching to `Int`-keyed, both become `Dict Int v`. Need to audit which `Data.Map.Dict` uses are for ordering guarantees vs. just custom comparison.

3. **Binary compatibility**: This change will break all cached compilation artifacts. Need a version bump or cache invalidation strategy.

4. **`Mono.toComparableMonoType`**: This function converts `MonoType` to a `String` for use as a Dict key (e.g., in `TypeTableAccum.ctorShapes`). With `FieldId`/`TypeNameId` inside `MonoType`, the comparable string changes. Should this be replaced entirely with a structural hash, or is string serialization still acceptable with integer IDs embedded?

## Standing Assumptions

5. **Elm's `Dict` and `Set` on `Int` are efficient**: We assume `Dict Int v` and `Set Int` have good constant factors in Elm's runtime. (They should — Elm's Dict is an AVL tree and Int comparison is fast.)

6. **No phantom type parameter is used at runtime**: `type Id a = Id Int` — the `a` is purely compile-time. Elm's runtime representation is just `{ $: 'Id', a: <int> }`, which is fine.

7. **Error messages can always look up names**: We assume every code path that produces a user-facing error message has access to the relevant intern table or name-mapping dict. This needs verification for each error reporter.

8. **`LocalVarId` scope**: We assume `LocalVarId`s are unique within a module compilation (not globally unique across all modules). This is sufficient because locals don't cross module boundaries.

9. **Phase ordering is flexible within phases**: The sub-steps within each phase can be reordered as convenient, but the phases themselves should be done in order (1 before 2, 2 before 3, etc.) since later phases depend on earlier infrastructure.

10. **TypedOptimized mirrors Optimized**: We assume that every structural change to `Optimized.elm` types has a corresponding change in `TypedOptimized.elm`, and the typed optimization passes mirror the untyped ones.
