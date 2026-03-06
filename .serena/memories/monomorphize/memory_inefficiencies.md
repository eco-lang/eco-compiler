# Monomorphization Pass - Memory Inefficiency Analysis

## CRITICAL ISSUES FOUND

### 1. WORKLIST PREPENDING (HIGH IMPACT - O(n) per item)
**File:** Monomorphize.elm, Specialize.elm

**Issue:** Worklist items are prepended with `::` operator repeatedly:
```elm
worklist = SpecializeGlobal monoGlobal monoType Nothing :: state.worklist
```
This happens in:
- Line 731: specializeExpr VarGlobal case
- Line 763: specializeExpr VarEnum case
- Line 782: specializeExpr VarBox case
- Line 801: specializeExpr VarCycle case
- Line 870: specializeExpr Call case
- Line 1208: specializeExpr Accessor case
- Line 1420: resolveProcessedArg PendingAccessor case
- Line 1452: resolveProcessedArg PendingAccessor case

**Impact:** Each prepend traverses the entire worklist to create a new cons cell. In a large program with thousands of specializations, this is **O(n²)** where n = total specializations.

**Fix:** Use an accumulator-based approach or append to end (would require different data structure).

---

### 2. REPEATED SUBSTITUTION APPLICATION (HIGH IMPACT)
**File:** TypeSubst.elm, Specialize.elm

**Issue:** `applySubst` is called multiple times on the same types in different contexts:

Example in specializeExpr (lines 646-663):
```elm
TOpt.Int _ value canType ->
    let
        monoType = Mono.forceCNumberToInt (TypeSubst.applySubst subst canType)
    in
    -- monoType applied here to create literal

TOpt.Float _ value canType ->
    let
        monoType = Mono.forceCNumberToInt (TypeSubst.applySubst subst canType)
```

And in TypeSubst.applySubst itself (line 336):
```elm
Dict.map (\_ (Can.FieldType _ t) -> applySubst subst t) fields
```
This walks the entire fields dict even if only a few are polymorphic.

**Impact:** Deep recursive substitution over complex record types (dict map + recursive descent). Not memoized.

**Fix:** Cache substitution results or use a more efficient traversal.

---

### 3. DICT.FOLDL BUILDING REVERSED LISTS (MEDIUM IMPACT)
**Files:** Specialize.elm

**Issue:** Dict.foldl operations build lists in reverse, then rely on reversal or ordering assumptions:

Lines 2031-2042 (specializeRecordFields):
```elm
Dict.foldl compare
    (\name expr ( acc, st ) ->
        let ( monoExpr, newSt ) = specializeExpr expr subst st
        in ( ( name, monoExpr ) :: acc, newSt )
    )
    ( [], state )
    fields
```
Result is reversed list: `(name, monoExpr) :: acc` builds in reverse order.

Similar in:
- Line 2045-2059: specializeTrackedRecordFields  
- Line 2062-2076: specializeUpdates
- Line 1989-2007: specializeEdges (using List.foldr but prepending)

**Impact:** Creates intermediate reversed lists. While small, it's unnecessary list construction.

**Fix:** Use List.foldr instead of foldl and cons, or explicitly reverse at end.

---

### 4. DICT VALUES COLLECTION (MEDIUM IMPACT)
**File:** Specialize.elm, line 1067

**Issue:**
```elm
instancesList = Dict.values compare topEntry.instances
```
Collects all instances from a dict into a list, then iterates via foldl (line 1072):
```elm
List.foldl (\info (defsAcc, stAcc) -> ...) ([],state) instancesList
```

**Impact:** For programs with many specialized let-bindings, creates intermediate list of all instances even if only processing one or two.

**Fix:** Use Dict.foldl directly instead of Dict.values + List.foldl.

---

### 5. VARTYPE STATE ACCUMULATION (MEDIUM IMPACT)
**File:** Monomorphize.elm, State.elm, Specialize.elm

**Issue:** `varTypes` Dict accumulates through entire specialization but is CLEARED on entering new scopes:

In Monomorphize.elm (lines 205-211):
```elm
state2 = { state1
    | inProgress = EverySet.insert identity specId state1.inProgress
    , currentGlobal = Just global
    , varTypes = Dict.empty  -- CLEARED HERE
}
```

But in specializeExpr recursion, varTypes grows:
- Line 218 (specialized params added)
- Line 1059 (def types added)
- Line 1095, 1121, 1135, 1154 (various contexts)

**Impact:** When processing deep call chains, varTypes can grow large but is discarded when entering new functions. Wasted allocation/deallocation cycles.

**Fix:** Use a stack-based approach or cleaner scoping mechanism.

---

### 6. STATE RECORD UPDATES (MEDIUM IMPACT)
**Files:** Monomorphize.elm, Specialize.elm

**Issue:** State is updated via record syntax repeatedly:
```elm
{ state1
    | registry = newRegistry
    , worklist = SpecializeGlobal ... :: state.worklist
    , currentGlobal = Just global
}
```

This creates a new record copy on EACH worklist item (thousands in large programs).

**Impact:** Elm's record updates are O(1) field copies but still allocate. With O(n) state updates per specialization, totals O(n²) allocations.

**Fix:** Use a mutable-style accumulator or batch state updates.

---

### 7. REPEATED CLOSURE CAPTURE ANALYSIS (MEDIUM IMPACT)
**File:** Closure.elm (called from Specialize.elm line 235)

**Issue:** `computeClosureCaptures` walks the entire expression tree + recursively calls `collectVarTypes`:

```elm
computeClosureCaptures params body =
    let
        boundInitial = List.foldl (\(name,_) acc -> EverySet.insert...) ...
        freeNames = findFreeLocals boundInitial body |> dedupeNames
        varTypeMap = collectVarTypes body  -- ENTIRE TREE WALK
```

Then builds captures via List.map:
```elm
List.map captureFor freeNames
```

For each closure (lambda), this tree-walks the body. In nested closures, quadratic.

**Impact:** Large nested closures cause multiple full AST walks.

**Fix:** Cache free variable info in annotations during earlier passes.

---

### 8. INEFFICIENT PATTERN MATCHING IN SPECIAL CASES (MEDIUM IMPACT)
**File:** Specialize.elm

**Issue:** `procesCallArgs` (line 1316) uses List.foldr and does case analysis on EVERY arg:

```elm
processCallArgs args subst state =
    List.foldr
        (\arg (accArgs, accTypes, st) ->
            case arg of
                TOpt.Accessor region fieldName canType -> ...
                TOpt.VarKernel region home name canType -> ...
                _ -> (specializeExpr arg subst st)
        ) (...) args
```

Even non-special arguments go through case analysis. In calls with many args, this is O(n) unnecessary pattern matching.

**Fix:** Separate special args into a first pass, then process rest directly.

---

### 9. TYVAR LOOKUP IN UNIFY WITHOUT MEMOIZATION (LOW-MEDIUM IMPACT)
**File:** TypeSubst.elm, lines 68-181

**Issue:** `unifyHelp` recursively walks two type trees (Can.Type + Mono.MonoType) but doesn't cache intermediate unifications.

For a deeply nested type like:
```
Option (Option (Option Int))
```
Unifying with concrete type re-traverses the nesting at each level.

**Impact:** Medium - most types aren't deeply nested, but complex generic code can see this.

**Fix:** Use a memo table during unification.

---

### 10. DICT.FILTER THEN ITERATION (LOW-MEDIUM IMPACT)
**File:** TypeSubst.elm, line 143-145

**Issue:**
```elm
remainingFields = Dict.filter
    (\fieldName _ -> Dict.get identity fieldName fields == Nothing)
    monoFields
```

Filters dict, creates new dict, then used once. For large records with extension variables.

**Impact:** Low - record unification only happens for polymorphic record types.

**Fix:** Use more efficient set difference approach.

---

### 11. DUPLICATE TYPE CONVERSIONS (LOW IMPACT)
**File:** Specialize.elm

**Issue:** Same type is converted multiple times:
- Line 187: `TypeSubst.applySubst subst canType` on function type
- Line 208: Same type vars re-applied via List.map on params
- Line 249: `Mono.forceCNumberToInt` wraps applySubst, done twice in lambda case

**Impact:** Low - type conversion is relatively fast, but unnecessary.

**Fix:** Apply once, reuse result.

---

### 12. ANALYSIS.COLLECTALLCUSTOMTYPES FULL TRAVERSAL (LOW IMPACT)
**File:** Monomorphize.elm, line 387

**Issue:**
```elm
customTypes = Analysis.collectAllCustomTypes nodes
```
Walks ALL nodes in the graph after specialization even if only a subset is reachable. Uses EverySet dedup.

**Impact:** Low - happens once at end, but creates large intermediate EverySet.

**Fix:** Only collect types from reachable nodes.

---

## SUMMARY OF INEFFICIENCIES BY CATEGORY

### **HIGHEST PRIORITY (O(n²) or worse)**
1. **Worklist prepending** - Prepending every item causes O(n) traversal per item
2. **State record updates** - Creates new record millions of times
3. **Dict.values + List.foldl** - Unnecessary intermediate list

### **MEDIUM PRIORITY (hot path, noticeable slowdown)**
1. **VarTypes accumulation/clearing** - Wasted scoping
2. **Repeated substitution** - No memoization on common types
3. **Closure capture analysis** - Multiple tree walks per lambda
4. **Pattern matching every arg** - Unnecessary case analysis

### **LOW PRIORITY (minor, infrequent)**
1. **Reversed lists in foldl** - Small cost, easy fix
2. **Dict filtering** - Rare case
3. **Duplicate type conversions** - Minor redundancy
4. **Full graph traversal** - One-time cost

## RECOMMENDATIONS FOR FIXES

1. **Change worklist to append**: Use a DList or separate append/prepend pointers
2. **Reduce state updates**: Batch updates or use explicit accumulator passing
3. **Replace Dict.values + List.foldl**: Use Dict.foldl directly
4. **Add memoization**: Cache substitution results at type vars (prob not worth complexity)
5. **Fix closure analysis**: Do in earlier pass if possible
6. **Clean up scoping**: Use explicit scope stack instead of clearing varTypes
