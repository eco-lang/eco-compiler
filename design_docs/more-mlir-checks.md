Below are **MLIR-module-only** invariant-test plans for runtime categories **B (SSA type inconsistency), D (record update wrong), and E (segfaults from boxing/unboxing mistakes)**. Each plan:
1) names the invariants it enforces (existing + proposed new ones where needed),  
2) gives pseudocode,  
3) gives a detailed Elm implementation blueprint operating on `MlirModule` / `MlirOp` ASTs (not on execution).

All plans assume tests can obtain a `MlirModule` via `Compiler.Generate.MLIR.Backend.generateMlirModule`  and that the MLIR AST types are as defined in `Mlir.Mlir` .
1) names the invariants it enforces (existing + proposed new ones where needed),  
2) gives pseudocode,  
3) gives a detailed Elm implementation blueprint operating on `MlirModule` / `MlirOp` ASTs (not on execution).

All plans assume tests can obtain a `MlirModule` via `Compiler.Generate.MLIR.Backend.generateMlirModule`  and that the MLIR AST types are as defined in `Mlir.Mlir` .
---
# Plan B1 — Global SSA Type Consistency Check (catches B directly)
### Invariants enforced
- **New proposed invariant: CGEN_0B1 “SSA value has a single MLIR type across module”**  
  This directly targets the runtime error: “use of value '%X' expects different type than prior uses: 'i64' vs '!eco.value'”.
- Reinforces the intent behind several existing invariants that assume typed SSA is coherent:
  - CGEN_006 let-bindings preserve representation 
  - CGEN_007 argument boxing limited to eco.value ↔ primitive 
  - CGEN_008 `_operand_types` matches actual SSA operand types
### Pseudocode
```
INPUT: MlirModule

ssaType : Dict SSAName MlirType = {}

walk all ops in module (including inside func regions):
  // 1) record result SSA types
  for each (resultName, resultTy) in op.results:
     if resultName in ssaType and ssaType[resultName] != resultTy:
        error "SSA retyped"
     else:
        ssaType[resultName] = resultTy

  // 2) validate operands are consistent with previously known SSA types
  for each operandName in op.operands:
     if operandName startsWith "%" and operandName in ssaType:
        // ok, we can type-check operand uses later against expected types
        continue
     else:
        // block args, globals, or values not yet seen -> ignore here

// Optional strict mode: also record block arg types into ssaType and then check all uses.

OUTPUT: pass if no retyping detected
```
### Detailed Elm implementation plan
## 1) Create a test module
Add: `compiler/tests/Invariant/SsaTypeConsistency.elm`
## 2) Traverse all nested operations
Use the region/block structure from `Mlir.Mlir`: `MlirOp.regions : List MlirRegion`, and a region has `entry : MlirBlock` with `body` and `terminator` .
Implement a conservative traversal (entry block only; extend to multi-block if needed later):
```elm
collectOpsInBlock : Mlir.MlirBlock -> List Mlir.MlirOp
collectOpsInBlock blk =
    blk.body ++ [ blk.terminator ]

collectOpsInRegion : Mlir.MlirRegion -> List Mlir.MlirOp
collectOpsInRegion (Mlir.MlirRegion r) =
    collectOpsInBlock r.entry
    -- if you start using r.blocks, fold those too

collectOpsInOp : Mlir.MlirOp -> List Mlir.MlirOp
collectOpsInOp op =
    op :: List.concatMap collectOpsInRegion op.regions

collectAllOps : Mlir.MlirModule -> List Mlir.MlirOp
collectAllOps m =
    List.concatMap collectOpsInOp m.body
```
## 3) Build SSA type environment from `op.results`
`MlirOp.results : List ( String, MlirType )` .
```elm
type alias SsaEnv =
    Dict.Dict String Mlir.MlirType

recordResultTypes : Mlir.MlirOp -> SsaEnv -> Result String SsaEnv
recordResultTypes op env0 =
    List.foldl
        (\(name, ty) acc ->
            acc
              |> Result.andThen
                    (\env ->
                        case Dict.get name env of
                            Nothing ->
                                Ok (Dict.insert name ty env)

                            Just oldTy ->
                                if oldTy == ty then
                                    Ok env
                                else
                                    Err ("SSA retyped: " ++ name)
                    )
        )
        (Ok env0)
        op.results
```
## 4) Run the check
```elm
checkNoSsaRetyping : Mlir.MlirModule -> Result String ()
checkNoSsaRetyping m =
    let
        ops = collectAllOps m
    in
    List.foldl
        (\op acc ->
            acc |> Result.andThen (\env -> recordResultTypes op env)
        )
        (Ok Dict.empty)
        ops
      |> Result.map (\_ -> ())
```
## 5) Hook into elm-test
Write an `Expect` wrapper:
```elm
expectOk : Result String () -> Expect.Expectation
expectOk res =
    case res of
        Ok _ -> Expect.pass
        Err msg -> Expect.fail msg
```

Then in test:
```elm
test "MLIR SSA values are never retyped" <|
  \_ ->
     mlirModule
       |> checkNoSsaRetyping
       |> expectOk
```

This catches the category B failures even if `_operand_types` is “self-consistent” (because the issue is often one SSA name being used across two different typed contexts).
---
# Plan B2/E1 — `_operand_types` Attribute Must Match SSA Operand Types (CGEN_008)

This catches a large class of B + E bugs at the *exact operation site*, and it also enforces the invariant already documented.
### Invariants enforced
- **CGEN_008** `_operand_types` exactly match SSA operand types 
- Also supports CGEN_007 (boxing only changes eco.value vs primitive)
### Pseudocode
```
INPUT: MlirModule

ssaTypeEnv := build from:
  - func.func entry block args
  - op.results across all ops

for each op in module:
  if op has attribute "_operand_types":
     expectedTypes := parse attr list [TypeAttr ...]
     actualTypes := map each operand SSA name -> ssaTypeEnv[name] (if known)
     assert lengths equal
     assert expectedTypes == actualTypes (same order)

OUTPUT: pass/fail with diagnostic
```
### Detailed Elm implementation plan
## 1) Build SSA env including function args
In `Ops.mkRegion`, function args are stored as `MlirBlock.args : List (String, MlirType)` .
Augment SSA env with these:
```elm
recordBlockArgs : Mlir.MlirBlock -> SsaEnv -> SsaEnv
recordBlockArgs blk env =
    List.foldl (\(n,t) e -> Dict.insert n t e) env blk.args

recordFuncArgs : Mlir.MlirOp -> SsaEnv -> SsaEnv
recordFuncArgs op env =
    case op.name of
        "func.func" ->
            case op.regions of
                [ Mlir.MlirRegion r ] ->
                    recordBlockArgs r.entry env
                _ ->
                    env
        _ ->
            env
```

Then do a two-pass build:
1) seed with all func args  
2) fold results

Then do a two-pass build:
1) seed with all func args  
2) fold results
## 2) Parse `_operand_types`
Your ops build `_operand_types` as `ArrayAttr Nothing [ TypeAttr ... ]`  .
```elm
getOperandTypesAttr : Mlir.MlirOp -> Maybe (List Mlir.MlirType)
getOperandTypesAttr op =
    case Dict.get "_operand_types" op.attrs of
        Just (Mlir.ArrayAttr _ elems) ->
            Just <|
              List.filterMap
                (\a -> case a of
                    Mlir.TypeAttr t -> Just t
                    _ -> Nothing
                )
                elems
        _ ->
            Nothing
```
## 3) Compare to SSA-derived operand types
```elm
lookupOperandTypes : SsaEnv -> List String -> Result String (List MlirType)
lookupOperandTypes env operands =
    operands
      |> List.map
           (\name ->
              case Dict.get name env of
                 Just ty -> Ok ty
                 Nothing -> Err ("Unknown SSA operand: " ++ name)
           )
      |> sequenceResult
```

Where `sequenceResult` is the usual `List (Result e a) -> Result e (List a)`.
## 4) Check all ops
```elm
checkOperandTypesAttrMatches : MlirModule -> Result String ()
checkOperandTypesAttrMatches m =
  let
     ops = collectAllOps m
     env = buildSsaEnv m
  in
  ops
    |> List.foldl
         (\op acc ->
            acc |> Result.andThen (\_ ->
               case getOperandTypesAttr op of
                 Nothing -> Ok ()
                 Just expected ->
                   lookupOperandTypes env op.operands
                     |> Result.andThen (\actual ->
                        if expected == actual then Ok ()
                        else Err ("_operand_types mismatch in " ++ op.name)
                     )
            )
         )
         (Ok ())
```

This will flush out many boxing/unboxing inconsistencies and also catches “attribute lies” bugs that make later passes unsafe.
---
# Plan D1 — Record Update Dataflow Shape Check (catches D earlier)

Your D symptom: `{ original | x = 10 }` yields a record where `x` became the *original record* rather than `10`.
We can catch a big subset of these bugs by verifying a structural/dataflow property in MLIR: **record update should construct a record where each field operand is either (a) the new value for updated fields, or (b) a projection from the original record**.
### Invariants enforced
- **New proposed invariant: CGEN_0D1 “Record update operands come from projections or explicit update values”**
- Related existing invariants that this complements:
  - CGEN_005 projection types and attributes consistent 
  - CGEN_008 `_operand_types` matches SSA operands 
- Cross-phase intent exists: record access/update should match layout metadata (MONO_007) , but this plan stays MLIR-only.
### Pseudocode
```
INPUT: MlirModule

For each func.func:
  find patterns of:
     %r2 = eco.construct.record( ... operands ... ) attrs { field_count = N, ... }

  For each such record construction:
     Heuristically identify the "source record" %r0 used in projections:
         collect all eco.project.record ops in same function:
             eco.project.record %r0 -> %p_i

     For each construct operands list:
         FOR each operand v:
             if v == %r0:
                FAIL  // storing whole record into a field is almost always wrong
             else if v is one of the projection results %p_i:
                OK (copied field)
             else:
                OK (must be updated field value or computed)

Additionally:
  require at least one operand in the construct is NOT a projection result (otherwise it's just copy, not update)
  (optional) require at least one operand IS a projection result (otherwise it's not an update, it's a fresh record)
```

This is intentionally heuristic, but it’s aimed precisely at your observed wrong-structure outcome.
### Detailed Elm implementation plan
## 1) Find `eco.project.record` and `eco.construct.record`
Projections are built by `Ops.ecoProjectRecord` . Construction by `Ops.ecoConstructRecord` .
Detect ops by `op.name`:
- `"eco.project.record"`
- `"eco.construct.record"`
Detect ops by `op.name`:
- `"eco.project.record"`
- `"eco.construct.record"`
## 2) Work within each function
Get `func.func` ops from `module.body`. For each function, collect ops from its entry block.
```elm
opsInFunc : MlirOp -> List MlirOp
opsInFunc funcOp =
    case funcOp.regions of
        [ MlirRegion r ] -> collectOpsInBlock r.entry
        _ -> []
```
## 3) Collect projection map
For each projection op:
- operand[0] is the record SSA name being projected from (see builder: operand is recordVar) 
- result is op.results[0].0
For each projection op:
- operand[0] is the record SSA name being projected from (see builder: operand is recordVar) 
- result is op.results[0].0
```elm
type alias ProjInfo =
  { source : String
  , result : String
  }

getRecordProj : MlirOp -> Maybe ProjInfo
getRecordProj op =
  if op.name /= "eco.project.record" then Nothing else
  case (op.operands, op.results) of
    ( [src], [ (res, _) ] ) -> Just { source = src, result = res }
    _ -> Nothing
```

Group by `source`:
```elm
projResultsBySource : List MlirOp -> Dict String (Set String)
```
## 4) Check each `eco.construct.record`
Construction operands are `op.operands`. Field count is an attr `"field_count"` (see builder) .
```elm
getFieldCount : MlirOp -> Maybe Int
getFieldCount op =
  case Dict.get "field_count" op.attrs of
     Just (Mlir.IntAttr _ n) -> Just n
     _ -> Nothing
```

Now the actual D check:
- pick the “best” source record `%r0` as the one that has the most projection results used among the construct operands
- fail if `%r0` itself appears as a construct operand

Now the actual D check:
- pick the “best” source record `%r0` as the one that has the most projection results used among the construct operands
- fail if `%r0` itself appears as a construct operand
```elm
checkNoWholeRecordStoredAsField : MlirOp -> List MlirOp -> Result String ()
checkNoWholeRecordStoredAsField constructOp funcOps =
  let
     projs = funcOps |> List.filterMap getRecordProj
     bySource = buildDict source -> Set(projResult)

     bestSource =
       Dict.keys bySource
         |> List.maximumBy (\src -> countIntersection constructOp.operands (bySource[src]))
  in
  case bestSource of
     Nothing -> Ok ()  -- no projections; probably not an update
     Just src ->
        if List.member src constructOp.operands then
            Err ("Record construction stores whole record " ++ src ++ " into a field")
        else
            Ok ()
```
## 5) Make a dedicated fixture program
You should add a very small Elm test program that forces record update codegen, e.g.:
- `let r = { x = 1, y = 2 } in { r | x = 10 }`

Then run this MLIR check on the resulting module. If the bug is present, it should fail *before* runtime.
- `let r = { x = 1, y = 2 } in { r | x = 10 }`

Then run this MLIR check on the resulting module. If the bug is present, it should fail *before* runtime.
---
# Plan E1 — No “Project After Unbox” / No “Primitive Used Where eco.value Required” (segfault prevention)

The code explicitly warns about the dangerous sequence “project -> eco.unbox -> project” and explains that it must be avoided because `eco.unbox` produces primitives but further projections expect `!eco.value` . This kind of mistake often becomes a segfault when the runtime treats an integer as a heap pointer.
### Invariants enforced
- **CGEN_005**: `eco.project` matches container and field types; operand must be `!eco.value` 
- **CGEN_001**: boxing only between primitives and eco.value 
- **New proposed invariant: CGEN_0E1 “Values of primitive MLIR type never flow into `eco.project.*` container operands”**
### Pseudocode
```
INPUT: MlirModule

Build SSA type env (args + results).

For each op in module:
  if op.name in { eco.project.record, eco.project.custom, eco.project.tuple2, eco.project.tuple3,
                  eco.project.list_head, eco.project.list_tail }:
      container = op.operands[0]
      containerTy = ssaTypeEnv[container]
      assert containerTy == eco.value

Additionally, for each eco.unbox:
  assert operand type is eco.value
  assert result type is primitive (i1/i16/i32/i64/f64)
  // (optional) forbid eco.unbox result being used as container operand anywhere
```
### Detailed Elm implementation plan
## 1) Identify eco.value type
In the AST, eco.value is `NamedStruct "eco.value"` .
So:
```elm
isEcoValue : MlirType -> Bool
isEcoValue ty =
  case ty of
    Mlir.NamedStruct "eco.value" -> True
    _ -> False
```
## 2) List “projection ops” to check
From `Ops`:
- `"eco.project.record"` 
- `"eco.project.custom"` 
- `"eco.project.tuple2"`, `"eco.project.tuple3"` 
- plus list head/tail projections referenced in pattern/path codegen  (even if you don’t have the builder snippet in the excerpt, they’re part of the codegen paths).
From `Ops`:
- `"eco.project.record"` 
- `"eco.project.custom"` 
- `"eco.project.tuple2"`, `"eco.project.tuple3"` 
- plus list head/tail projections referenced in pattern/path codegen  (even if you don’t have the builder snippet in the excerpt, they’re part of the codegen paths).
## 3) Implement the check
```elm
isProjectionOpName : String -> Bool
isProjectionOpName name =
  List.member name
    [ "eco.project.record"
    , "eco.project.custom"
    , "eco.project.tuple2"
    , "eco.project.tuple3"
    , "eco.project.list_head"
    , "eco.project.list_tail"
    ]

checkProjectionContainerTypes : MlirModule -> Result String ()
checkProjectionContainerTypes m =
  let
    env = buildSsaEnv m
    ops = collectAllOps m
  in
  ops
   |> List.foldl
        (\op acc ->
           acc |> Result.andThen (\_ ->
             if not (isProjectionOpName op.name) then Ok () else
             case op.operands of
               [container] ->
                 case Dict.get container env of
                   Nothing ->
                     Err ("Unknown container SSA: " ++ container)

                   Just ty ->
                     if isEcoValue ty then Ok ()
                     else Err ("Projection container is not eco.value: " ++ container)
               _ ->
                 Err ("Malformed projection op operands: " ++ op.name)
           )
        )
        (Ok ())
```

This is a very strong segfault-preventer: it bans interpreting primitives as heap pointers at the projection boundary.
---
# Plan E2 — Boxing/Unboxing Edge Sanity (“unbox produces primitive; primitive must not be treated as boxed later”)

Even if you do Plan E1, it’s helpful to add a specific check around `eco.unbox` sites. This also correlates with the “boxing only between primitives and eco.value” invariant intent.
### Invariants enforced
- **CGEN_001** boxing only between primitives and eco.value 
- **New proposed invariant: CGEN_0E2 “eco.unbox result types are primitive; eco.unbox operand is eco.value”**
- Reinforces the calling convention behavior in lambda generation where parameters are boxed and selectively unboxed .
### Pseudocode
```
For each op named eco.unbox:
  operand must be eco.value
  result must be primitive (i1,i16,i32,i64,f64), not eco.value
```
### Detailed Elm implementation plan
```elm
isPrimitiveTy : MlirType -> Bool
isPrimitiveTy ty =
  case ty of
    I1 -> True
    I16 -> True
    I32 -> True
    I64 -> True
    F64 -> True
    _ -> False

checkEcoUnboxWellTyped : MlirModule -> Result String ()
checkEcoUnboxWellTyped m =
  let
    env = buildSsaEnv m
    ops = collectAllOps m
  in
  ops
   |> List.foldl
        (\op acc ->
          acc |> Result.andThen (\_ ->
            if op.name /= "eco.unbox" then Ok () else
            case (op.operands, op.results) of
              ( [v], [(_, outTy)] ) ->
                 case Dict.get v env of
                   Nothing -> Err ("eco.unbox operand unknown: " ++ v)
                   Just inTy ->
                     if not (isEcoValue inTy) then
                       Err "eco.unbox operand not eco.value"
                     else if not (isPrimitiveTy outTy) then
                       Err "eco.unbox result not primitive"
                     else
                       Ok ()
              _ ->
                Err "Malformed eco.unbox"
          )
        )
        (Ok ())
```
---
## How these map to the runtime categories you asked for

- **B (SSA type inconsistency):** Plan B1 catches the *global* SSA retyping pattern; Plan B2 catches local operand attribute mismatches that often accompany it.
- **D (record update wrong):** Plan D1 catches the specific “field gets whole record” shape (the failure you observed) without requiring executing code.
- **E (segfaults due to boxing/unboxing mistakes):** Plan E1 prevents primitives being used as heap containers in projections; Plan E2 validates every `eco.unbox` is type-correct and consistent with the boxed calling convention and the comments about avoiding project→unbox→project hazards .
If you paste a representative MLIR snippet for the failing `RecordUpdateTest` and one of the segfaulting tests, I can tighten D1/E1 further to match *exactly* your emitted op sequences (e.g., checking `eco.construct.record`’s operand list against the specific `eco.project.record` results rather than a heuristic).
