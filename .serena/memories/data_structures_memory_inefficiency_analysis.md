# Data Structures Memory Inefficiency Analysis

## Critical Findings

### 1. DATA/MAP.ELM - SEVERE O(N LOG N) INEFFICIENCIES IN KEYS/VALUES/TOLIST

**Location:** `/work/compiler/src/Data/Map.elm` lines 347-376

**Problems:**

1. **keys()** (line 347-351):
   - Retrieves all values from internal Dict: O(n)
   - **THEN sorts them**: `List.sortWith` at line 350 - O(n log n)
   - Maps to extract keys at line 351 - O(n)
   - **Total: O(n log n)** for every call

2. **values()** (line 361-365):
   - Same pattern: extract values O(n), **sort O(n log n)**, map O(n)
   - **Total: O(n log n)** for every call

3. **toList()** (line 372-375):
   - Extracts all values and **sorts by keys**: `List.sortWith` at line 375
   - **Total: O(n log n)** every time a sorted list is needed

**Impact:** These operations are called during:
- Type environment reconciliation in Solve.elm (lines 302, 360, 405)
- Error rendering in Error.elm (lines 770, 789, 804)
- PostSolve processing (lines 875, 1009, 1299, 1302)
- Field type processing in Constrain/Expression modules

**Root Cause:** The underlying Elm Dict maintains insertion order, but this wrapper doesn't. Every query for ordered data triggers a full sort.

**Inefficiency Pattern:**
```
keys : (k -> k -> Order) -> Dict c k v -> List k
keys keyComparison (D dict) =
    Dict.values dict
        |> List.sortWith (\( k1, _ ) ( k2, _ ) -> keyComparison k1 k2)  -- EXPENSIVE
        |> List.map Tuple.first
```

---

### 2. COMPILER/DATA/NONEMPTYLIST.ELM - O(N) SNOC OPERATION

**Location:** `/work/compiler/src/Compiler/Data/NonEmptyList.elm` lines 54-56

**UPDATED 2026-03-25**: Function is named `snoc` (not `cons`). Comment explicitly says "O(n)".

**Problem:**
```elm
snoc : a -> Nonempty a -> Nonempty a
snoc a (Nonempty b bs) =
    Nonempty b (bs ++ [ a ])  -- O(n) list concatenation!
```

**Why it's bad:**
- `bs ++ [ a ]` is O(n) because it must traverse all of bs to append the single element
- Currently builds O(n²) complexity if snoc is called repeatedly

**Impact:** Used in constraint collection and may be called during error accumulation.

---

### 3. DATA/VECTOR/MUTABLE.ELM - REPEATED O(N) GROWS

**Location:** `/work/compiler/src/Data/Vector/Mutable.elm` lines 36-44

**Problem:**
```elm
grow : IORef (Array (Maybe (List Variable))) -> Int -> IO (IORef (Array (Maybe (List Variable))))
grow ioRef length_ =
    ...
        (\value ->
            IORef.writeIORefMVector ioRef
                (Array.append value (Array.repeat length_ Nothing))  -- O(n) append!
        )
```

**Why it's bad:**
- Array.append is O(n) where n is the array length
- If a mutable vector is grown multiple times, each growth copies the entire array
- AmortizedO(n) per growth, but total O(n²) if grown k times with size n

**Additional Issue in Vector.elm (line 70):**
```elm
IO.map (\newX -> Array.push (Just newX) acc)  -- O(n) push in accumulator
```

**Impact:** Used in type solver's variable pool management during generalization (Solve.elm line 338).

---

### 4. DATA/IOREF.ELM - REPEATED ARRAY COPIES ON EVERY MUTATION

**Location:** `/work/compiler/src/Data/IORef.elm` lines 60, 67, 74, 81, 140, 147, 154, 161

**Problem:**
All IORef operations use `Array.set` which **reconstructs the entire array**:

```elm
newIORefWeight : Int -> IO (IORef Int)
newIORefWeight value =
    \s -> ( { s | ioRefsWeight = Array.push value s.ioRefsWeight }, IORef (Array.length s.ioRefsWeight) )
    -- Array.push is O(n) copy

writeIORefWeight : IORef Int -> Int -> IO ()
writeIORefWeight (IORef ref) value =
    \s -> ( { s | ioRefsWeight = Array.set ref value s.ioRefsWeight }, () )
    -- Array.set is O(n) copy
```

**Why it's bad:**
- Each `Array.set` is O(n) because Elm arrays are persistent structures
- Type solver creates thousands of IORef entries during type variable allocation
- **Compounding effect:** solver makes millions of mutations

**Impact:** CRITICAL - This is in the hot path of type checking:
- UnionFind operations (Solve.elm lines 48-54, 350)
- Every type variable creation and modification
- Pool management during generalization

---

### 5. COMPILER/TYPE/SOLVE.ELM - REPEATED DICT.TOLIST AND DICT.FROMLIST

**Location:** Multiple points in Solve.elm

**Problems:**

1. **Dict.toList calls with sort** (lines 316, 405, 814):
```elm
IO.foldM occurs state2 (Dict.toList compare locals)
```
- `Dict.toList compare` is O(n log n) because of sorting (in Data.Map)
- Called during type variable validation
- May be called multiple times for same dictionary

2. **Dict.fromList in tight loops** (lines 806, 985):
```elm
typeToVar rank pools (Dict.fromList identity argVars) aliasType
```
- O(n log n) to construct Dict from list
- Happens during type substitution for each alias

3. **IO.traverseMap** (lines 71, 110, 114, 302, 360):
```elm
IO.traverseMap identity compare Type.toAnnotation env
```
- Traverses entire type environment Dict with sort operations

**Pattern:** Repeated conversions between Dict and List cause repeated sorting:
- toList = O(n log n)
- fromList = O(n log n)
- Total = O(n log n) for round-trip

**Impact:** These happen in critical type inference paths
- Environment building (lines 308, 393)
- Occurs checking (lines 316, 405)

---

### 6. UNION-FIND PATH COMPRESSION - APPEARS CORRECT

**Location:** `/work/compiler/src/Compiler/Type/UnionFind.elm` lines 57-81

**Finding:** UnionFind implementation **does have path compression**:
```elm
repr point1
    |> IO.andThen (\point2 ->
        if point2 /= point1 then
            IORef.readIORefPointInfo (IORef ref1)
                |> IO.andThen (\pInfo1 ->
                    IORef.writeIORefPointInfo (IORef ref) pInfo1  -- Path compression
                )
```

**However:** The compression works by reading and rewriting PointInfo, which involves Array.set (O(n)) in the backing IORef system. So while the algorithm is correct, the implementation is slow.

---

### 7. COMPILER/GRAPH.ELM - KOSARAJU'S ALGORITHM

**Location:** `/work/compiler/src/Compiler/Graph.elm`

**Finding:** Implementation is reasonably efficient:
- Uses Array for adjacency lists (O(1) indexing)
- Binary search for key-to-ID mapping (O(log n))
- DFS traversals are O(n+m)

**No major inefficiencies found here** - this is acceptable.

---

### 8. COMPILER/TYPE/POSTSOLVE.ELM - REPEATED DICT.TOLIST

**Location:** Lines 875, 1009, 1299-1302

**Problems:**
```elm
Dict.toList A.compareLocated fields  -- O(n log n)
```

Called repeatedly during:
- List field processing (line 875)
- Tuple processing (line 1009)
- Record type reconstruction (lines 1299-1302)

May process the same field dictionaries multiple times without caching.

---

## PERSISTENT DATA STRUCTURE OVERHEAD

**Problem:** The custom Data.Map wrapper uses Elm's standard Dict internally, which is a persistent red-black tree. 

**Cost model:**
- Insert: O(log n)
- Get: O(log n)
- But worst case, entire trees are reconstructed during rotation

**Secondary issue:** The wrapper stores *both* the comparable key *and* the original key:
```elm
type Dict c k v = D (Dict.Dict c ( k, v ))
```

This doubles memory usage compared to a single-key dict. When `k = String` and `c = String`, we store the string twice!

---

## SUMMARY TABLE

| Issue | Location | Complexity | Call Frequency | Total Impact |
|-------|----------|-----------|-----------------|--------------|
| Map.keys/values sorting | Data/Map.elm | O(n log n) | High (env queries) | CRITICAL |
| Map.toList sorting | Data/Map.elm | O(n log n) | Medium (field dicts) | HIGH |
| NonEmptyList.cons | Data/NonEmptyList | O(n) | Low-Medium | MEDIUM |
| Vector grow | Data/Vector/Mutable | O(n) per growth | Low | LOW-MEDIUM |
| Array.push/set | Data/IORef | O(n) per op | VERY HIGH | CRITICAL |
| Dict.toList + sort | Solve.elm | O(n log n) | High | CRITICAL |
| Dict.fromList | Solve.elm | O(n log n) | Medium | HIGH |
| Dict.union | Type modules | O(n) per union | High | HIGH |

---

## KEY HOTSPOTS TO OPTIMIZE

### Highest Priority:
1. **IORef Array mutations** - Every type variable update is O(n)
2. **Map.keys/values/toList** - Every use of sorted order requires full sort
3. **Dict.toList in type solver** - Happens repeatedly in tight loops

### Medium Priority:
4. **Dict.union operations** - Linear merges in field type processing
5. **NonEmptyList.cons** - Quadratic if used in loops (less likely)
6. **Vector grow** - Quadratic growth pattern

### Lower Priority:
7. **PostSolve Dict operations** - Fewer iterations than type solver
8. **Graph module** - Already efficient

---

## ROOT CAUSE ANALYSIS

The fundamental issue is **persistent data structure overhead in the type checker's hot path**:

1. Every type variable creation/mutation recreates the backing array in IORef
2. Every environment lookup/merge recreates Dict structures
3. Every sorted access to Maps triggers O(n log n) operations
4. No caching of sorted views or computed results

The design prioritizes **correctness and immutability** over performance. For a production type checker handling large modules, this becomes a bottleneck.
