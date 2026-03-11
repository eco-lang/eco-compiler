# Eco Compiler Monomorphization - Quick Reference

## ABSOLUTE FILE PATHS

- Specialize.elm: `/work/compiler/src/Compiler/Monomorphize/Specialize.elm`
- TypeSubst.elm: `/work/compiler/src/Compiler/Monomorphize/TypeSubst.elm`
- Monomorphize.elm: `/work/compiler/src/Compiler/Monomorphize/Monomorphize.elm`
- Monomorphized.elm: `/work/compiler/src/Compiler/AST/Monomorphized.elm`
- Tests: `/work/compiler/tests/TestLogic/Monomorphize/`

---

## MAIN ENTRY POINTS

### monomorphizeFromEntry (Monomorphize.elm:73)
```
mainGlobal, mainType, globalTypeEnv, nodes → Result String MonoGraph
```
Master function handling:
- Specialization to fixpoint
- Value-used set computation
- Key-type-aware erasure (dead specs & phantom vars)
- Registry patching (MONO_017)
- Graph pruning

### specializeExpr (Specialize.elm:659)
```
TOpt.Expr → Substitution → MonoState → (Mono.MonoExpr, MonoState)
```
Main expression specialization dispatcher:
- ~850 lines covering 28 expression types
- Critical for Record, Update, List, Lambda, Let, Call, Accessor

---

## CRITICAL FUNCTIONS BY PURPOSE

### Type Specialization
- **applySubst** (TypeSubst:388) - Apply substitution to canonical type
- **unifyFuncCall** (TypeSubst:45) - Two-phase unification for calls
- **unifyExtend/unifyHelp** (TypeSubst:76/83) - Core unification engine
- **resolveMonoVars** (TypeSubst:241) - Resolve MVars through subst

### Expression Specialization
- **specializeExpr** (Specialize:659) - Main dispatcher [28 cases]
- **specializeLambda** (Specialize:178) - Lambda specialization with captures
- **processCallArgs** (Specialize:1572) - Deferred arg processing
- **resolveProcessedArgs/Arg** (Specialize:1820/1684) - Resolve deferred args

### Local Multi-Target
- **getOrCreateLocalInstance** (Specialize:~400) - Create instance for multi-target local
- **isLocalMultiTarget** (Specialize:~300) - Check if local needs multi-specialization

### Closure Support
- **Closure.computeClosureCaptures** (Closure.elm) - Walk body, find free vars

### Erasure & Dead Code
- **patchNodeTypesToErased** (Monomorphize:578) - Erase all MVars (dead specs)
- **patchNodeTypesCEcoToErased** (Monomorphize:606) - Erase CEcoValue only
- **eraseTypeVarsToErased** (Monomorphized:321) - Helper
- **eraseCEcoVarsToErased** (Monomorphized:470) - Helper
- **containsCEcoMVar** (Monomorphized:431) - Test for CEcoValue MVar

### Function Specialization
- **specializeFunc** (Specialize:522) - Single function in cycle
- **specializeFuncDefInCycle** (Specialize:571) - Specialize function body

### Substitution Building
- **buildRenameMap** (TypeSubst:312) - Create fresh var names
- **renameCanTypeVars** (TypeSubst:332) - Apply rename map to type
- **collectCanTypeVars** (TypeSubst:273) - Collect all TVar names

---

## CORE CONCEPTS

### Specialization Key
```elm
type SpecKey = SpecKey Global MonoType (Maybe LambdaId)
```
Identifies unique monomorphic instances:
- `Global canonical name` - function being called
- `MonoType` - concrete type at this call site
- `LambdaId` - closure set (optional)

### Substitution
```elm
type alias Substitution = Dict String Mono.MonoType
```
Maps type variable names to concrete mono types.

### Four Key Invariants
1. **MONO_017**: SpecId reverse mapping matches actual node types
2. **MONO_020**: No CEcoValue MVar in reachable user-defined local functions (pre-erasure)
3. **MONO_021**: No CEcoValue MVar in user-defined function types (post-erasure)
4. **MONO_024**: Fully monomorphic specs have no CEcoValue in ANY position

---

## SPECIALIZATION FLOW DIAGRAM

```
monomorphizeFromEntry
  ├─ initState (from nodes + globalTypeEnv)
  ├─ processWorklist (specialization fixpoint)
  │  └─ specializeNode (WorkItem)
  │     ├─ SpecializeGlobal
  │     │  └─ specializeFunc (for cycles)
  │     │     └─ specializeFuncDefInCycle
  │     │        └─ specializeExpr
  │     │           ├─ TOpt.Record/Update/List
  │     │           │  └─ specializeExpr per field/element
  │     │           ├─ TOpt.Lambda
  │     │           │  └─ specializeLambda
  │     │           ├─ TOpt.Let
  │     │           │  └─ specializeExpr (body)
  │     │           ├─ TOpt.Call
  │     │           │  ├─ processCallArgs (deferred)
  │     │           │  ├─ unifyFuncCall (arg unification)
  │     │           │  └─ resolveProcessedArgs
  │     │           │     └─ resolveProcessedArg (virtual globals)
  │     │           └─ ... [other 15 cases]
  │     └─ register worklist items
  │        └─ SpecializeGlobal (enqueue)
  ├─ compute value-used set (specs referenced via MonoVarGlobal)
  ├─ key-type-aware erasure
  │  ├─ dead specs: patchNodeTypesToErased (ALL MVars → MErased)
  │  ├─ polymorphic-key specs: patchNodeTypesCEcoToErased (CEcoValue → MErased)
  │  └─ monomorphic-key specs: unchanged
  ├─ patch registry reverseMapping + rebuild mapping
  └─ prune unreachable specs
```

---

## FIELD-LEVEL SUBSTITUTION REFINEMENT

When specializing records/updates/calls, **refined substitutions** propagate concrete types to nested expressions:

```elm
Record:
  ├─ Get monoFieldTypes from MRecord type
  └─ For each field:
     ├─ Look up field mono type
     ├─ Unify fieldExpr canonical with that mono type
     └─ Specialize with refined subst

Update:
  ├─ Get canonical record type (NOT result type)
  ├─ For each update:
     ├─ Look up field in canonical record
     ├─ Unify updateExpr canonical with field mono type
     └─ Specialize with refined subst

Call:
  ├─ Unify function type with call args
  └─ Extract param types from unified function
     └─ Specialize deferred args with their param types
```

**Example:** `{ f = \x -> x + 1 }` with type `{ f : Int -> Int }`
- Field mono type: `MFunction [MInt] MInt`
- Refine subst by unifying lambda canonical type with that
- Lambda body specializes with param constraint: `x : MInt`

---

## DEFERRED PROCESSING STRATEGY

### processCallArgs identifies deferred items:
1. **Accessor** - Needs record layout from parameter type
2. **NumberBoxed kernel** - Needs post-unification type for numeric selection
3. **LocalFunArg** - Needs to check multi-target and get instance

### Deferral reasons:
- **Accessors**: Can't determine field offset without parameter record layout
  - `Call map .x records` - don't know .x type until we know map's parameter type
- **Kernels**: Numeric kernels like `+` need final monomorphized type
  - Can use `eco.int.add` intrinsic if `Int -> Int -> Int`, else boxed ABI
- **Locals**: Multi-target locals need instance lookup based on parameter type
  - `Call f arg` where f is multi-target and bound to `\x -> ...`

### Resolution in resolveProcessedArgs:
1. Get corresponding parameter type
2. Call resolveProcessedArg with that param type
3. For Accessors: extract field type from parameter record, register virtual global
4. For Kernels: re-derive ABI type with call-site subst
5. For Locals: refine subst if param is MFunction, get/create instance

---

## ERASURE LOGIC

### Key-Type-Aware Gating:
```elm
For each spec:
  let isValueUsed = BitSet.member specId valueUsedWithMain
  let keyHasCEcoMVar = Mono.containsCEcoMVar keyType
  if isValueUsed then
    if keyHasCEcoMVar then
      patchNodeTypesCEcoToErased  -- Phantom vars only
    else
      leave unchanged  -- Fully constrained
  else
    patchNodeTypesToErased  -- Dead spec
```

### Why this approach:
1. **Dead specs** (not value-used): Safe to erase all MVars (unreachable code)
2. **Polymorphic-key specs**: CEcoValue MVars are phantoms (never constrained)
   - MErased marks them explicitly
   - Backend will crash if MErased reaches operational position
3. **Monomorphic-key specs**: No CEcoValue should remain (MONO_021/MONO_024)
   - If it does, that's a specialization bug

### Erasure functions:
- **eraseTypeVarsToErased**: Replace all MVars with MErased
- **eraseCEcoVarsToErased**: Replace only MVar with CEcoValue
- **containsCEcoMVar**: Test for CEcoValue MVar (gates erasure decisions)
- **containsAnyMVar**: Test for any MVar (gates fully-monomorphic test)

---

## COMMON BUGS & PATTERNS

### Bug Pattern 1: Lost Constraints
**Symptom:** MONO_021 violation (CEcoValue in user function)
**Cause:** Didn't unify/enrich subst with discovered constraint
**Fix:** Use `unifyExtend` when actual type differs from canonical

### Bug Pattern 2: Incomplete Field Types
**Symptom:** Accessor can't find field, crashes with "Field not found"
**Cause:** Parameter type not fully resolved when accessor specialized
**Fix:** Use deferral (processCallArgs/resolveProcessedArgs) to delay until unified

### Bug Pattern 3: Wrong Staging
**Symptom:** GOPT_001 violation (param count ≠ stage arity)
**Cause:** Flattened function type in Monomorphize (should stay curried)
**Fix:** Preserve `TLambda` structure from applySubst, let GlobalOpt flatten

### Bug Pattern 4: Shared vs Monomorphic
**Symptom:** Function body has unresolved TVars despite monomorphic key
**Cause:** Used sharedSubst instead of augmented/refined subst in body
**Fix:** For each param, unify canonical type with actual param type

### Bug Pattern 5: Scope Leakage
**Symptom:** Lambda captures wrong variable or type
**Cause:** VarEnv not properly pushed/popped around lambda body
**Fix:** Push before specializing params, pop after specializing body

---

## SUBSTITUTION APPLICATION CHECKLIST

When applying substitution to any type:

- [ ] Use `Mono.forceCNumberToInt` to handle CNumber defaults
- [ ] For TRecord, merge base fields (from extension) with explicit fields
- [ ] For TLambda, preserve curried structure (single-arg MFunction)
- [ ] For TAlias, handle both Filled and Holey cases
- [ ] Check for CEcoValue after applySubst (gate inference decisions)
- [ ] If CEcoValue remains, infer concrete type from expression or error

---

## TESTING INVARIANTS

### MONO_021 Test (NoCEcoValueInUserFunctions.elm:80)
```elm
checkNoCEcoValueInUserFunctions : MonoGraph -> List Violation
```
- Walks all specs
- For each user function node, collects CEcoValue vars
- Reports context + violated positions
- Exempts kernel nodes (MonoExtern, MonoManagerLeaf)

### MONO_024 Test (FullyMonomorphicNoCEcoValue.elm:68)
```elm
checkFullyMonomorphicNoCEcoValue : MonoGraph -> List Violation
```
- Iterates registry reverse mapping
- For fully-monomorphic specs only
- Checks ALL expression tree MonoTypes
- Reports position + CEcoValue vars
- Stricter than MONO_021 (all positions, not just functions)

---

## PERFORMANCE NOTES

From memory monomorphize/memory_inefficiencies:

**High Impact (O(n²)):**
- Worklist prepending with `::` operator
- State record updates (millions per large program)

**Medium Impact (hot path):**
- Repeated substitution without memoization
- VarTypes accumulation/clearing across scopes
- Dict.values + List.foldl (extra intermediate list)
- Closure capture analysis (multiple tree walks)

**Low Impact:**
- Reversed lists in foldl (small cost)
- Dict filtering in unification (rare case)

See memory for detailed analysis and fix suggestions.

---

## REFERENCES

### Invariants (from CLAUDE.md)
- REP_ABI_001: Only Int, Float, Char pass by value; Bool passes as !eco.value
- GOPT_001: Closure params match stage arity; GlobalOpt canonicalizes
- MONO_017: SpecId reverse mapping matches actual node types
- MONO_020: No CEcoValue MVar in reachable user-defined local functions (pre-erasure)
- MONO_021: No CEcoValue MVar in user-defined function types (post-erasure)
- MONO_024: Fully monomorphic specs have no CEcoValue in ANY position

### Related Passes
- **GlobalOpt** (MonoGlobalOptimize.elm): Flattens closures, optimizes calls, stages functions
- **Closure.elm**: Computes closure captures and ABI
- **KernelAbi.elm**: Derives kernel function types (boxed vs numeric)
- **Registry.elm**: Manages SpecId allocation

---

## QUICK LOOKUP

| Concept | Definition | Location |
|---------|-----------|----------|
| MonoType | Monomorphic type (Int, Float, List a, a -> b, etc.) | Monomorphized.elm |
| MVar | Type variable (with constraint: CNumber or CEcoValue) | Monomorphized.elm |
| Substitution | Dict mapping TVar names to MonoTypes | TypeSubst.elm |
| SpecKey | (Global, MonoType, LambdaId?) uniquely identifying specialization | Monomorphized.elm |
| Closure | Anonymous lambda with captures, params, body | Monomorphized.elm |
| Accessor | Virtual global for record field access | Specialize.elm |
| ProcessedArg | Deferred argument (Resolved, Pending, LocalFun) | Specialize.elm |
| LocalMulti | Stack tracking multi-target local function instances | State.elm, Specialize.elm |
| VarEnv | Stack mapping local variable names to types | State.elm |
| MErased | Erased type for dead specs / phantom vars | Monomorphized.elm |
