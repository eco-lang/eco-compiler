# Eliminate Unnecessary Data.Map.Dict Usages

## Problem

`Data.Map.Dict comparable k v` is a triple-type-variable Dict wrapper used throughout the compiler. It wraps `Dict.Dict comparable (k, v)` and accepts a `(k -> comparable)` comparator. When `k` is already comparable (String, Int, etc.), the comparator is `identity` — making Data.Map redundant. These usages store a redundant key copy in every entry and add unnecessary API friction (passing `identity` everywhere).

## Analysis Summary

### Comparator patterns in use

| Comparator | Key type | # Files | Genuinely needs Data.Map? |
|---|---|---|---|
| `identity` | `Name` (=String) | ~75 | NO |
| `identity` | `Int` | ~8 | NO |
| `identity` | `List String` | ~3 | NO |
| `ModuleName.toComparableCanonical` | `IO.Canonical` | ~9 | YES |
| `Opt.toComparableGlobal` / `TOpt.toComparableGlobal` | `Global` | ~5 | YES |
| `A.toValue` | `A.Located Name` | ~4 | YES |
| `Tuple.mapSecond V.toComparable` | `(Pkg.Name, V.Version)` | ~1 | YES |
| pass-through `toComparable` param | polymorphic | ~12 | YES (generic utilities) |

### AST types with identity-keyed Dicts (WILL CHANGE)

**Canonical.elm** (mixed — some fields keep Data.Map):
- `FreeVars = Dict String Name ()` → `Dict.Dict Name ()`
- `TRecord (Dict String Name FieldType) (Maybe Name)` → `Dict.Dict Name FieldType`
- `ModuleData.unions/aliases/binops: Dict String Name X` → `Dict.Dict Name X`
- `Export (Dict String Name (A.Located Export))` → `Dict.Dict Name (A.Located Export)`
- `Ports (Dict String Name Port)` → `Dict.Dict Name Port`
- KEEP Data.Map: `Record (Dict String (A.Located Name) Expr)`, `Update` — key is `A.Located Name`

**TypedOptimized.elm** (mixed):
- `Annotations = Dict String Name Can.Annotation` → `Dict.Dict Name Can.Annotation`
- `LocalGraphData.fields: Dict String Name Int` → `Dict.Dict Name Int`
- KEEP Data.Map: `GlobalGraph`/`LocalGraph` nodes (key=Global), `Update`/`TrackedRecord` (key=A.Located Name)

**Monomorphized.elm** (all identity):
- `MRecord (Dict String Name MonoType)` → `Dict.Dict Name MonoType`
- `MonoGraph.nodes: Dict Int Int MonoNode` → `Dict.Dict Int MonoNode`
- `MonoGraph.ctorShapes: Dict (List String) (List String) (List CtorShape)` → `Dict.Dict (List String) (List CtorShape)`
- `MonoGraph.callEdges: Dict Int Int (List Int)` → `Dict.Dict Int (List Int)`

**Interface.elm** (all identity):
- `InterfaceData.values/unions/aliases/binops: Dict String Name X` → `Dict.Dict Name X`
- `Private: Dict String Name.Name Can.Union, Dict String Name.Name Can.Alias` → `Dict.Dict Name.Name X`

**Other type-defining modules**: Optimized.elm, TypeEnv.elm, Format modules, etc.

### Files that ONLY use identity comparator → fully switch to `import Dict`

~70+ source files and ~25+ test files. These currently do `import Data.Map as Dict exposing (Dict)` and pass `identity` to all comparator-taking functions.

### Files with mixed comparator usage → need both imports

~12 files that use both `identity` and a custom comparator. These will need:
```elm
import Dict
import Data.Map
```

## Implementation Plan

### Phase 1: Change AST type definitions

Change identity-keyed Dict fields in AST modules to use stdlib `Dict.Dict`. Files with mixed usage will import both `Dict` and `Data.Map`.

Files: `Canonical.elm`, `TypedOptimized.elm`, `Monomorphized.elm`, `Optimized.elm`, `Interface.elm`, `TypeEnv.elm`

### Phase 2: Update pure-identity consumer files

For files that ONLY use identity comparator:
1. Change `import Data.Map as Dict exposing (Dict)` → `import Dict exposing (Dict)`
2. Remove `identity` first arg from: `Dict.get`, `Dict.insert`, `Dict.remove`, `Dict.update`, `Dict.singleton`, `Dict.fromList`, `Dict.member`
3. Remove comparator first arg from: `Dict.toList`, `Dict.foldl`, `Dict.foldr`, `Dict.keys`, `Dict.values`
4. Update type annotations: drop the redundant comparable type parameter

### Phase 3: Update mixed-usage consumer files

For files using both identity and custom comparators:
1. Add `import Dict` alongside existing `import Data.Map`
2. Change identity-comparator calls to use `Dict.get`, `Dict.insert`, etc. (no comparator)
3. Keep Data.Map calls for non-identity comparators using qualified `Data.Map.get toComparable ...`
4. Update type annotations to match changed AST types

### Phase 4: Update Data.Map and Data.Set modules

After all consumers are migrated, review Data.Map.elm to see if any API functions are now unused and can be removed. Data.Set.elm wraps Data.Map and should remain since EverySet is used with non-comparable keys (Global).

### Phase 5: Update serialization (encoders/decoders)

Files like `Utils/Bytes/Encode.elm`, `Utils/Bytes/Decode.elm`, `Json/Encode.elm`, `Json/Decode.elm` contain polymorphic encoding/decoding utilities that accept `toComparable`. Some call sites pass `identity` and should switch to stdlib Dict-based versions.

## Scope boundaries

- Do NOT change `Data.Set.EverySet` usage (separate concern, EverySet is used with genuinely non-comparable keys)
- Do NOT change generic utility functions that accept `toComparable` as a parameter (they must remain polymorphic)
- Do NOT change files using `ModuleName.toComparableCanonical`, `toComparableGlobal`, `A.toValue`, etc.
- DO change all `identity`-comparator call sites
- DO change type definitions where k=comparable
