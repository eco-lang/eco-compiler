# tvar Roots Design — Code Resolution Report

This report resolves the design in `notes/tvar-hl-design.md` against the actual codebase,
identifying every file, function, and type that will need to change.

---

## Section 1: Normalize `Meta.tvar` to solver roots in PostSolve

### 1.1 Current state of `Meta.tvar`

The `tvar` field already exists in both IRs.

**TypedCanonical** — `/work/compiler/src/Compiler/AST/TypedCanonical.elm:56-62`
```elm
type Expr_
    = TypedExpr
        { expr : Can.Expr_
        , tipe : Can.Type Name
        , tvar : Maybe IO.Variable
        }
```

**TypedOptimized** — `/work/compiler/src/Compiler/AST/TypedOptimized.elm:106-112`
```elm
type alias Meta id =
    { tipe : Can.Type id
    , tvar : Maybe IO.Variable
    }
```

### 1.2 How `tvar` is currently populated

The `tvar` values come from the `nodeVars` array produced by constraint generation. Each expression ID maps to the solver variable created for it during constraint generation. This is **not** root-normalized; it is the raw solver variable.

**Constraint generation records each variable** — `/work/compiler/src/Compiler/Type/Constrain/Typed/NodeIds.elm:44-61`
```elm
type alias NodeVarMap =
    Array (Maybe IO.Variable)

recordNodeVar : Int -> IO.Variable -> NodeIdState -> NodeIdState
recordNodeVar id var state =
    if id >= 0 then
        { state | mapping = arraySetGrowing id (Just var) state.mapping }
    else
        state
```

**Solver returns nodeVars unchanged** — `/work/compiler/src/Compiler/Type/Solve.elm:90-146`
```elm
runWithIds :
    Constraint
    -> Array (Maybe Variable)
    ->
        IO
            (Result
                (NE.Nonempty Error.Error)
                { annotations : Data.Map.Dict String Name.Name (Can.Annotation Name)
                , annotationVars : Data.Map.Dict String Name.Name Variable
                , nodeTypes : Array (Maybe (Can.Type Name))
                , nodeVars : Array (Maybe Variable)
                , solverState :
                    { descriptors : Array Descriptor
                    , pointInfo : Array IO.PointInfo
                    , weights : Array Int
                    }
                }
            )
```

Key: `nodeVars` is passed through unchanged — the raw solver variables, NOT their roots.

**TypedCanonical.Build populates tvar from nodeVars** — `/work/compiler/src/Compiler/TypedCanonical/Build.elm:108-128`
```elm
toTypedExpr : ExprTypes -> ExprVars -> Can.Expr -> TCan.Expr
toTypedExpr exprTypes exprVars (A.At region info) =
    let
        tipe =
            case Array.get info.id exprTypes |> Maybe.andThen identity of
                Just t -> t
                Nothing ->
                    if info.id < 0 then
                        crash "TypedCanonical.Build.toTypedExpr: placeholder ID"
                    else
                        crash ("Missing type for expr id " ++ String.fromInt info.id)

        tvar =
            Array.get info.id exprVars |> Maybe.andThen identity
    in
    A.At region (TCan.TypedExpr { expr = info.node, tipe = tipe, tvar = tvar })
```

### 1.3 The union-find root-finding function

**`UF.repr`** — `/work/compiler/src/Compiler/Type/UnionFind.elm:57-81`
```elm
repr : IO.Point -> IO IO.Point
repr ((IO.Pt ref) as point) =
    IORef.readIORefPointInfo (IORef ref)
        |> IO.andThen
            (\pInfo ->
                case pInfo of
                    IO.Info _ _ ->
                        IO.pure point

                    IO.Link ((IO.Pt ref1) as point1) ->
                        repr point1
                            |> IO.andThen
                                (\point2 ->
                                    if point2 /= point1 then
                                        IORef.readIORefPointInfo (IORef ref1)
                                            |> IO.andThen
                                                (\pInfo1 ->
                                                    IORef.writeIORefPointInfo (IORef ref) pInfo1
                                                        |> IO.map (\_ -> point2)
                                                )
                                    else
                                        IO.pure point2
                                )
            )
```

### 1.4 Solver state types

**`IO.Variable`** — `/work/compiler/src/System/TypeCheck/IO.elm:463-470`
```elm
type alias Variable =
    Point

type Point
    = Pt Int
```

**`IO.PointInfo`** — `/work/compiler/src/System/TypeCheck/IO.elm:360-368`
```elm
type PointInfo
    = Info Int Int
    | Link Point
```

**`IO.State`** — `/work/compiler/src/System/TypeCheck/IO.elm:133-138`
```elm
type alias State =
    { ioRefsWeight : Array Int
    , ioRefsPointInfo : Array PointInfo
    , ioRefsDescriptor : Array Descriptor
    , ioRefsMVector : Array (Array (Maybe (List Variable)))
    }
```

### 1.5 What needs to change for Section 1

The design calls for normalizing `tvar` to UF roots **in PostSolve**, while the solver state is still available.

**PostSolve entry point** — `/work/compiler/src/Compiler/Type/PostSolve.elm:51-72`
```elm
postSolve :
    Data.Map.Dict String Name (Can.Annotation Name)
    -> Can.Module
    -> NodeTypes
    ->
        { nodeTypes : NodeTypes
        , kernelEnv : KernelTypes.KernelTypeEnv
        }
postSolve annotations (Can.Module canData) nodeTypes0 =
    let
        kernel0 =
            seedKernelAliases annotations canData.decls

        ( nodeTypes1, kernel1 ) =
            postSolveDecls annotations canData.decls nodeTypes0 kernel0
    in
    { nodeTypes = nodeTypes1
    , kernelEnv = kernel1
    }
```

PostSolve currently does NOT receive `nodeVars` or solver state. It only operates on `NodeTypes` (materialized `Can.Type` values). To normalize tvars to roots, PostSolve (or a sibling pass) needs access to:
- The `nodeVars : Array (Maybe IO.Variable)` array
- The solver state (specifically `pointInfo` for following UF links)

**The pipeline call site** — `/work/compiler/src/Compiler/Compile.elm:265-284`
```elm
Ok { annotations, annotationVars, nodeTypes, nodeVars } ->
    let
        postSolveResult =
            PostSolve.postSolve annotations canonical nodeTypes

        fixedNodeTypes =
            postSolveResult.nodeTypes

        kernelEnv =
            postSolveResult.kernelEnv
    in
    Ok
        { annotations = everyDictToDict annotations
        , typedCanonical = TCanBuild.fromCanonical canonical fixedNodeTypes nodeVars
        , nodeTypes = fixedNodeTypes
        , kernelEnv = kernelEnv
        , nodeVars = nodeVars
        , annotationVars = annotationVars
        }
```

Note: `nodeVars` is passed directly to `TCanBuild.fromCanonical` without root-normalization. The solver state (`solverState`) is available in the `Ok` branch of `runWithIds` but is not currently destructured or passed through in `typeCheckTyped`.

**Key change locations:**
1. `Compile.elm:265` — destructure `solverState` from the solver result
2. `Compile.elm:269` or new pass — root-normalize `nodeVars` using `solverState.pointInfo`
3. `Compile.elm:279` — pass root-normalized `nodeVars` to `TCanBuild.fromCanonical`

### 1.6 Type materialization (for context — shows where `Can.TVar` names come from)

**`variableToCanType`** — `/work/compiler/src/Compiler/Type/Type.elm:501-565`
```elm
variableToCanType : Variable -> State.StateT NameState (Can.Type Name)
variableToCanType variable =
    liftIO (UF.get variable)
        |> State.andThen
            (\(Descriptor descProps) ->
                case descProps.content of
                    Structure term ->
                        termToCanType term

                    FlexVar maybeName ->
                        case maybeName of
                            Just name ->
                                State.pure (Can.TVar name)
                            Nothing ->
                                getFreshVarName
                                    |> State.andThen
                                        (\name ->
                                            liftIO
                                                (UF.modify variable
                                                    (\(Descriptor props) ->
                                                        IO.makeDescriptor (FlexVar (Just name)) props.rank props.mark props.copy
                                                    )
                                                )
                                                |> State.map (\_ -> Can.TVar name)
                                        )

                    FlexSuper super maybeName ->
                        case maybeName of
                            Just name ->
                                State.pure (Can.TVar name)
                            Nothing ->
                                getFreshSuperName super
                                    |> State.andThen
                                        (\name ->
                                            liftIO
                                                (UF.modify variable
                                                    (\(Descriptor props) ->
                                                        IO.makeDescriptor (FlexSuper super (Just name)) props.rank props.mark props.copy
                                                    )
                                                )
                                                |> State.map (\_ -> Can.TVar name)
                                        )

                    RigidVar name ->
                        State.pure (Can.TVar name)

                    RigidSuper _ name ->
                        State.pure (Can.TVar name)

                    Alias home name args realVariable ->
                        State.traverseList (State.traverseTuple variableToCanType) args
                            |> State.andThen
                                (\canArgs ->
                                    variableToCanType realVariable
                                        |> State.map
                                            (\canType ->
                                                Can.TAlias home name canArgs (Can.Filled canType)
                                            )
                                )

                    Error ->
                        crash "cannot handle Error types in variableToCanType"
            )
```

Note: this function already follows the UF link (via `UF.get`) when materializing types, so `Can.Type` names are already from the representative descriptor. But the **variable identity** in `tvar` is NOT normalized — a non-root variable may have the same name as its root but a different `IO.Pt` index.

---

## Section 2: Audit of LocalOpt — does it create/rename type variables?

### 2.1 Files in the LocalOpt typed pipeline

```
compiler/src/Compiler/LocalOpt/Typed/
├── Module.elm              — entry point, builds LocalGraph
├── Expression.elm          — expression optimization
├── Case.elm                — case optimization
├── Port.elm                — port encoder/decoder synthesis
├── NormalizeLambdaBoundaries.elm — lambda boundary normalization
├── Names.elm               — name/dependency tracking monad
└── DecisionTree.elm        — decision tree compilation
```

### 2.2 Expression optimization: tvar threading is correct

**`Expression.elm:325-340`** — every expression carries tvar through:
```elm
optimizeExpr : KernelTypeEnv -> Annotations -> ExprTypes -> ExprVars
           -> IO.Canonical -> Cycle -> A.Region
           -> Can.Type Name -> Maybe IO.Variable -> Can.Expr_
           -> Names.Tracker (TOpt.Expr Name)
optimizeExpr kernelEnv annotations exprTypes exprVars home cycle region tipe tvar expr =
    case expr of
        Can.VarLocal name ->
            ...
            Names.pure (TOpt.TrackedVarLocal region name { tipe = localType, tvar = tvar })
        Can.Call func args ->
            ...
            Names.map (\optArgs -> TOpt.Call region optFunc optArgs { tipe = tipe, tvar = tvar })
```

All expression constructors receive both `tipe` and `tvar` from the TypedCanonical source and pass them into `Meta`. No renaming or fresh creation of type variables occurs here. **No issues found.**

### 2.3 Module.elm: tvar for function definitions

**`Module.elm:467-531`** — `addDefNode` computes `nodeTvar` for function definitions:
```elm
bodyTvar : Maybe IO.Variable
bodyTvar =
    case A.toValue body of
        TCan.TypedExpr info ->
            info.tvar

nodeTvar : Maybe IO.Variable
nodeTvar =
    case args of
        [] ->
            bodyTvar
        _ ->
            case Data.Map.get identity name annotationVars of
                Just var ->
                    Just var
                Nothing ->
                    bodyTvar
```

For functions with arguments, `nodeTvar` comes from `annotationVars` — the solver's env mapping definition names to their solver variables. These are **not root-normalized** either. After the design change, `annotationVars` values would also need root-normalization (or the `AllSchemeRoots` mechanism replaces this usage).

### 2.4 Module.elm: `wrapDestruct` — correct

**`Module.elm:536-538`**
```elm
wrapDestruct : Can.Type Name -> TOpt.Destructor Name -> TOpt.Expr Name -> TOpt.Expr Name
wrapDestruct bodyType destructor expr =
    TOpt.Destruct destructor expr { tipe = bodyType, tvar = TOpt.tvarOf expr }
```

Preserves tvar from inner expression. **No issues.**

### 2.5 Expression.elm: `makeDestructorMeta` — correct

**`Expression.elm:1323-1327`**
```elm
makeDestructorMeta : ExprTypes -> ExprVars -> Int -> Can.Type Name -> TOpt.Meta Name
makeDestructorMeta _ exprVars patId tipe =
    { tipe = tipe, tvar = lookupPatternVar exprVars patId }
```

Looks up pattern solver variable from `exprVars` array. **No issues.**

### 2.6 NormalizeLambdaBoundaries: variable renaming

**`NormalizeLambdaBoundaries.elm:108-120`** — fresh variable names (NOT type variables):
```elm
freshName : Name.Name -> RenameCtx -> ( Name.Name, RenameCtx )
freshName base ctx =
    let
        suffix =
            String.fromInt ctx.nextId
        newName =
            base ++ "_hl_" ++ suffix
    in
    ( newName, { ctx | nextId = ctx.nextId + 1 } )
```

This renames **local variable names** (like `x` → `x_hl_0`), NOT type variables. The `Meta` records on expressions are preserved through the renaming. **No issues.**

### 2.7 NormalizeLambdaBoundaries: case Meta update — correct

**`NormalizeLambdaBoundaries.elm:757-767`**
```elm
            Just ( canonicalParams, renamedJumps, arityPeeled ) ->
                case peelLambdaTypes arityPeeled caseMeta.tipe of
                    Just newCaseTipe ->
                        Just
                            ( outerParams ++ canonicalParams
                            , TOpt.Case label scrut deciderWithJumps renamedJumps { caseMeta | tipe = newCaseTipe }
                            )
```

The record update `{ caseMeta | tipe = newCaseTipe }` preserves `caseMeta.tvar` — standard Elm record update syntax only modifies the listed field. **No issues.**

### 2.8 NormalizeLambdaBoundaries: `rebuildLets` — correct

**`NormalizeLambdaBoundaries.elm:562-567`**
```elm
rebuildLets : List (TOpt.Def Name) -> TOpt.Expr Name -> TOpt.Expr Name
rebuildLets defs innerBody =
    List.foldr
        (\def body -> TOpt.Let def body (TOpt.metaOf body))
        innerBody
        defs
```

Uses `TOpt.metaOf body` which returns the full `Meta` including `tvar`. **No issues.**

### 2.9 Port.elm: synthetic TVar creation

**`Port.elm:166`**
```elm
Names.registerGlobal A.zero ModuleName.maybe "destruct" (Can.TVar "destruct") Nothing
```

**`Port.elm:629`**
```elm
Names.registerGlobal A.zero ModuleName.jsonEncode name (Can.TVar name) Nothing
```

**`Port.elm:634`**
```elm
Names.registerGlobal A.zero ModuleName.jsonDecode name (Can.TVar name) Nothing
```

**`Port.elm:643, 648`**
```elm
TOpt.VarKernel A.zero "Elm" Name.json "encodeBytes" { tipe = Can.TVar "encodeBytes", tvar = Nothing }
TOpt.VarKernel A.zero "Elm" Name.json "decodeBytes" { tipe = Can.TVar "decodeBytes", tvar = Nothing }
```

These create synthetic `Can.TVar` nodes with `tvar = Nothing`. These are port-related placeholders for monomorphic encoder/decoder functions. They do not participate in the solver's type variable universe and carry `tvar = Nothing`, which correctly marks them as non-solver-derived. **Compatible with the design — they will hit Case B (`tvar = Nothing`) in AssignMVarIds.**

### 2.10 Names.elm: `generate` — variable names, not type variables

**`Names.elm:144-149`**
```elm
generate : Tracker Name
generate =
    Tracker <|
        \uid deps fields locals ->
            tResult (uid + 1) deps fields locals (Name.fromVarIndex uid)
```

Generates fresh local variable names (`_v0`, `_v1`). Not type variables. **No issues.**

### 2.11 Audit conclusion

**No LocalOpt pass creates, renames, or scrambles type variables in `Can.Type` or `Meta.tvar`.** The passes are safe to pass through tvar roots unmodified. The only synthetic `Can.TVar` nodes are in Port.elm, and they all carry `tvar = Nothing`, which is the correct signal for non-solver-derived type variables.

---

## Section 3: Preserve root identity through TypedOptimized

### 3.1 Current serialization — tvar is dropped for expressions

**`TypedOptimized.elm:536-543`** — expression-level Meta encoding:
```elm
metaEncoder : Meta Name -> Bytes.Encode.Encoder
metaEncoder meta =
    Can.typeEncoder meta.tipe

metaDecoder : Bytes.Decode.Decoder (Meta Name)
metaDecoder =
    Bytes.Decode.map (\t -> { tipe = t, tvar = Nothing }) Can.typeDecoder
```

**The `tvar` field is NOT serialized for expression-level Meta.** On decode, it is always `Nothing`.

**`TypedOptimized.elm:1196-1213`** — TailDef's `maybeTvar` IS serialized:
```elm
TailDef region name args expr tipe maybeTvar ->
    Bytes.Encode.sequence
        [ Bytes.Encode.unsignedInt8 1
        , A.regionEncoder region
        , BE.string name
        , BE.list typedLocatedNameEncoder args
        , exprEncoder expr
        , Can.typeEncoder tipe
        , case maybeTvar of
            Nothing ->
                Bytes.Encode.unsignedInt8 0
            Just (IO.Pt n) ->
                Bytes.Encode.sequence
                    [ Bytes.Encode.unsignedInt8 1
                    , Bytes.Encode.signedInt32 Bytes.BE n
                    ]
        ]
```

**Key change locations for Section 3:**
1. `TypedOptimized.elm:536-543` — `metaEncoder`/`metaDecoder` must serialize `tvar` (the root `IO.Variable`)
2. The design calls for `AllSchemeRoots` to be serialized alongside the IR — needs a new field in the serialized artifact.

### 3.2 Per-module metadata carrier

**`TypedModuleArtifact`** — `/work/compiler/src/Compiler/AST/TypedModuleArtifact.elm`
```elm
type alias TypedModuleArtifact =
    { typedGraph : TOpt.LocalGraph Name
    , typeEnv : TypeEnv.ModuleTypeEnv
    }

typedModuleArtifactEncoder : TypedModuleArtifact -> Bytes.Encode.Encoder
typedModuleArtifactEncoder artifact =
    Bytes.Encode.sequence
        [ TOpt.localGraphEncoder artifact.typedGraph
        , TypeEnv.moduleTypeEnvEncoder artifact.typeEnv
        ]
```

`AllSchemeRoots` would be added as a new field here.

### 3.3 LocalGraph already carries annotations

**`TypedOptimized.elm:77-84`**
```elm
type LocalGraph id
    = LocalGraph
        { main : Maybe Main
        , nodes : DMap.Dict (List String) Global (Node id)
        , fields : Dict Name Int
        , annotations : Annotations id
        }
```

Where `Annotations id = Dict Name (Can.Annotation id)`.

---

## Section 4: AssignMVarIds — current name-based identity

### 4.1 Entry point

**`AssignMVarIds.elm:71-88`**
```elm
assignIds : TOpt.GlobalGraph Name -> ( TOpt.GlobalGraph TypeIds.MVarId, GlobalMVarState )
assignIds (TOpt.GlobalGraph nodes fields annotations) =
    let
        state0 =
            { nextId = TypeIds.firstMVarId
            , constraints = Dict.empty
            }

        dummyCompare _ _ =
            EQ

        ( newAnnotations, state1 ) =
            rewriteAnnotations annotations state0

        ( newNodes, state2 ) =
            rewriteNodes dummyCompare nodes state1
    in
    ( TOpt.GlobalGraph newNodes fields newAnnotations, state2 )
```

### 4.2 Global state

**`AssignMVarIds.elm:25-28`**
```elm
type alias GlobalMVarState =
    { nextId : TypeIds.MVarId
    , constraints : Dict Int Mono.Constraint
    }
```

### 4.3 Per-scope name-based environment

**`AssignMVarIds.elm:34-35`**
```elm
type alias SchemeEnv =
    Dict Name TypeIds.MVarId
```

**`AssignMVarIds.elm:141-161`** — lazy allocation by name:
```elm
ensureMVarId : Name -> Ctx -> ( TypeIds.MVarId, Ctx )
ensureMVarId name ctx =
    case Dict.get name ctx.env of
        Just mvarId ->
            ( mvarId, ctx )
        Nothing ->
            let
                constraint =
                    constraintFromName name
                ( mvarId, newState ) =
                    freshMVarId constraint ctx.state
            in
            ( mvarId
            , { env = Dict.insert name mvarId ctx.env
              , state = newState
              }
            )
```

**This is the function that will be replaced by root-based lookup.** Currently it uses `Dict Name` (string name); the design replaces this with `Dict IO.Variable MVarId` (`RootEnv`).

### 4.4 Constraint derivation from name

**`AssignMVarIds.elm:130-139`**
```elm
constraintFromName : Name -> Mono.Constraint
constraintFromName name =
    if Name.isNumberType name then
        Mono.CNumber
    else
        Mono.CEcoValue
```

**`Name.elm:195-212`** — name prefixes:
```elm
prefixNumber = "number"
prefixComparable = "comparable"
prefixAppendable = "appendable"
prefixCompappend = "compappend"
```

Note: only `number` triggers `CNumber`; all others get `CEcoValue`. The design says to keep this name-based constraint derivation as-is.

### 4.5 Per-node fresh SchemeEnv

**`AssignMVarIds.elm:224-243`** — each top-level node gets a fresh empty SchemeEnv:
```elm
rewriteNodes cmp nodes state =
    DMap.foldl cmp
        (\global node ( acc, st ) ->
            let
                ctx =
                    { env = Dict.empty, state = st }
                ( newNode, ctx1 ) =
                    rewriteNode ctx node
            in
            ( DMap.insert TOpt.toComparableGlobal global newNode acc, ctx1.state )
        )
        ( DMap.empty, state )
        nodes
```

**`AssignMVarIds.elm:47-59`** — per-binding fresh env:
```elm
withFreshBinding : Ctx -> (Ctx -> ( a, Ctx )) -> ( a, Ctx )
withFreshBinding outerCtx work =
    let
        bindingCtx =
            { env = Dict.empty, state = outerCtx.state }
        ( result, bindingCtx1 ) =
            work bindingCtx
    in
    ( result, { env = outerCtx.env, state = bindingCtx1.state } )
```

**Under the design:** The per-node and per-binding fresh scoping will be replaced by a single per-module `RootEnv` that maps `IO.Variable` → `MVarId`. The `withFreshBinding` pattern becomes unnecessary because root identity is global within a module.

### 4.6 Annotation rewriting

**`AssignMVarIds.elm:187-215`**
```elm
rewriteAnnotation :
    Can.Annotation Name
    -> GlobalMVarState
    -> ( Can.Annotation TypeIds.MVarId, GlobalMVarState )
rewriteAnnotation (Can.Forall freeVars tipe) state =
    let
        ( env, state1 ) =
            Dict.foldl
                (\name _ ( envAcc, st ) ->
                    let
                        constraint =
                            constraintFromName name
                        ( mvarId, st1 ) =
                            freshMVarId constraint st
                    in
                    ( Dict.insert name mvarId envAcc, st1 )
                )
                ( Dict.empty, state )
                freeVars

        ctx =
            { env = env, state = state1 }

        ( newType, ctx1 ) =
            rewriteCanType ctx tipe
    in
    ( Can.Forall freeVars newType, ctx1.state )
```

**Under the design:** This will use `AllSchemeRoots` to look up the rooted `IO.Variable` for each binder name, then feed those roots through `RootEnv` (instead of building a fresh `SchemeEnv` per annotation).

### 4.7 Type traversal

**`AssignMVarIds.elm:906-914`** — the core type walker:
```elm
rewriteCanType : Ctx -> Can.Type Name -> ( Can.Type TypeIds.MVarId, Ctx )
rewriteCanType ctx canType =
    case canType of
        Can.TVar name ->
            let
                ( mvarId, ctx1 ) =
                    ensureMVarId name ctx
            in
            ( Can.TVar mvarId, ctx1 )
```

**Under the design:** The expression walker will use `Meta.tvar` (the rooted `IO.Variable`) to look up/allocate `MVarId` via `RootEnv`, instead of `ensureMVarId` by name. The type walker for annotations will use `AllSchemeRoots` to get roots for binder names.

### 4.8 MVarId type

**`TypeIds.elm:18-22`**
```elm
type alias MVarId =
    Id MVarPh
```

### 4.9 Mono.Constraint type

**`Monomorphized.elm:215-242`**
```elm
type Constraint
    = CEcoValue
    | CNumber
```

### 4.10 MVarEnv in subsequent phases

**`State.elm:85-97`**
```elm
type alias MVarEnv =
    { nextId : MVarId
    , constraints : Dict Int Mono.Constraint
    }

initMVarEnv : MVarId -> Dict Int Mono.Constraint -> MVarEnv
initMVarEnv nextId constraints =
    { nextId = nextId
    , constraints = constraints
    }
```

The `GlobalMVarState` from AssignMVarIds flows directly into `MVarEnv` for monomorphization.

---

## Section 5: Scheme variables — `annotationVars` and `AllSchemeRoots`

### 5.1 How annotationVars is currently produced

**Solver** — `Solve.elm:90-146` returns `annotationVars : Data.Map.Dict String Name.Name Variable` which is the solver's `env` — mapping each top-level definition name to its solver variable.

### 5.2 How annotationVars currently threads through

**`Compile.elm:265-284`** — `typeCheckTyped` returns `annotationVars` alongside other results.

**`Compile.elm:165`** — passed to `typedOptimizeFromTyped`:
```elm
typedOptimizeFromTyped modul annotations nodeTypes nodeVars kernelEnv annotationVars typedCanonical
```

**`Compile.elm:320-321`**
```elm
typedOptimizeFromTyped : Src.Module -> Dict.Dict Name.Name (Can.Annotation Name) -> TCan.ExprTypes -> TCan.ExprVars -> KernelTypes.KernelTypeEnv -> EveryDict.Dict String Name.Name TypeCheck.Variable -> TCan.Module -> Result E.Error (TOpt.LocalGraph Name)
typedOptimizeFromTyped modul annotations nodeTypes nodeVars kernelEnv annotationVars tcanModule =
    case Tuple.second (ReportingResult.run (TypedOptimize.optimizeTyped annotations nodeTypes nodeVars kernelEnv annotationVars tcanModule)) of
```

**`Module.elm:91-92`**
```elm
optimizeTyped : Annotations -> ExprTypes -> ExprVars -> KernelTypes.KernelTypeEnv -> Data.Map.Dict String Name.Name IO.Variable -> TCan.Module -> MResult i (List W.Warning) (TOpt.LocalGraph Name)
optimizeTyped annotations exprTypes exprVars kernelEnv annotationVars (TCan.Module tData) =
```

**`Module.elm:477-490`** — used in `addDefNode` to get function-level tvar:
```elm
nodeTvar : Maybe IO.Variable
nodeTvar =
    case args of
        [] ->
            bodyTvar
        _ ->
            case Data.Map.get identity name annotationVars of
                Just var ->
                    Just var
                Nothing ->
                    bodyTvar
```

### 5.3 What `AllSchemeRoots` replaces

`annotationVars` maps `DefName → IO.Variable` (one variable per definition). The design's `AllSchemeRoots` maps `DefName → (BinderName → IO.Variable)` — one root variable per forall binder per definition.

To compute this, you need:
1. The `Can.Annotation` for each definition (has `Forall freeVars tipe`)
2. The mapping from each binder name to the solver variable that was created for it during annotation instantiation

### 5.4 Where binder names map to solver variables

**Annotation instantiation in solver** — `Solve.elm:899-928`:
```elm
srcTypeToVariable : Int -> Pools -> Dict Name.Name () -> Can.Type Name -> IO Variable
srcTypeToVariable rank pools freeVars srcType =
    let
        nameToContent name =
            if Name.isNumberType name then
                IO.FlexSuper IO.Number (Just name)
            else if Name.isComparableType name then
                IO.FlexSuper IO.Comparable (Just name)
            else if Name.isAppendableType name then
                IO.FlexSuper IO.Appendable (Just name)
            else if Name.isCompappendType name then
                IO.FlexSuper IO.CompAppend (Just name)
            else
                IO.FlexVar (Just name)

        makeVar name _ =
            UF.fresh (IO.makeDescriptor (nameToContent name) rank Type.noMark Nothing)
    in
    IO.traverseMapWithKey identity compare makeVar (Data.Map.fromList identity (Dict.toList freeVars))
        |> IO.andThen
            (\flexVars ->
                MVector.modify pools (\a -> Data.Map.values compare flexVars ++ a) rank
                    |> IO.andThen (\_ -> srcTypeToVar rank pools flexVars srcType)
            )
```

The `flexVars : Data.Map.Dict String Name.Name Variable` is exactly the binder-name-to-solver-variable mapping. Currently this mapping is local to the solver and not returned. To build `AllSchemeRoots`, this mapping (after root-normalization) needs to be surfaced.

### 5.5 SolverSnapshot (for context)

**`SolverSnapshot.elm:47-63`**
```elm
type alias SolverSnapshot =
    { state : SolverState
    , nodeVars : Array (Maybe TypeVar)
    , annotationVars : DMap.Dict String Name.Name TypeVar
    }
```

The SolverSnapshot currently captures `annotationVars` (def name → solver var) but NOT the per-binder mapping.

---

## Section 6: Port handling

### 6.1 Port nodes in Module.elm

**`Module.elm:269-310`**
```elm
addPort : IO.Canonical -> Annotations -> Name.Name -> Can.Port -> TOpt.LocalGraph Name -> TOpt.LocalGraph Name
addPort home annotations name port_ graph =
    case port_ of
        Can.Incoming { payload } ->
            let
                portType =
                    case Dict.get name annotations of
                        Just (Can.Forall _ t) -> t
                        Nothing -> Utils.Crash.crash "Module.addPort: Incoming no annotation"

                ( deps, fields, decoder ) =
                    Names.run (Port.toDecoder payload)

                node =
                    TOpt.PortIncoming decoder deps { tipe = portType, tvar = Nothing }
            in
            addToGraph (TOpt.Global home name) node fields graph

        Can.Outgoing { payload } ->
            let
                portType =
                    case Dict.get name annotations of
                        Just (Can.Forall _ t) -> t
                        Nothing -> Utils.Crash.crash "Module.addPort: Outgoing no annotation"

                ( deps, fields, encoder ) =
                    Names.run (Port.toEncoder payload)

                node =
                    TOpt.PortOutgoing encoder deps { tipe = portType, tvar = Nothing }
            in
            addToGraph (TOpt.Global home name) node fields graph
```

Port nodes always have `tvar = Nothing`. The design says to allocate fresh sequential MVarIds for port type variables without trying to reconstruct solver roots, and accept that ports may remain broken. **No changes needed here beyond what AssignMVarIds already does for `tvar = Nothing` (Case B).**

---

## Summary of all code locations that need changes

### Must change

| File | Lines | What |
|------|-------|------|
| `Compile.elm` | 265-284 | Destructure `solverState` from solver result; root-normalize `nodeVars`; compute `AllSchemeRoots` |
| `Solve.elm` | 899-928 | Surface the `flexVars` (binder→solver-var) mapping for `AllSchemeRoots` computation |
| `TypedOptimized.elm` | 536-543 | `metaEncoder`/`metaDecoder` — serialize `tvar` (`Maybe IO.Variable`) |
| `TypedModuleArtifact.elm` | entire | Add `AllSchemeRoots` field; update encoder/decoder |
| `AssignMVarIds.elm` | 25-59 | Replace `SchemeEnv : Dict Name MVarId` with `RootEnv : Dict IO.Variable MVarId` |
| `AssignMVarIds.elm` | 71-88 | `assignIds` — accept `AllSchemeRoots`; initialize per-module `RootEnv` |
| `AssignMVarIds.elm` | 141-161 | `ensureMVarId` — change from name-based to root-based lookup |
| `AssignMVarIds.elm` | 187-215 | `rewriteAnnotation` — use `AllSchemeRoots` to get roots for binders |
| `AssignMVarIds.elm` | 224-243 | `rewriteNodes` — use shared per-module `RootEnv` instead of per-node fresh env |
| `AssignMVarIds.elm` | 906-914 | `rewriteCanType` — use `Meta.tvar` for identity when available |

### May need minor wiring changes

| File | Lines | What |
|------|-------|------|
| `PostSolve.elm` | 51-72 | If root-normalization is done as a PostSolve sub-pass, needs to accept solver state |
| `TypedCanonical/Build.elm` | 108-128 | `toTypedExpr` — receives root-normalized `nodeVars` (no code change if normalization happens upstream) |
| `Module.elm` | 477-490 | `addDefNode` — `annotationVars` values should be root-normalized |
| `SolverSnapshot.elm` | 47-63 | May need to carry per-binder mappings if `AllSchemeRoots` is computed from snapshot |

### No changes needed (audit passed)

| File | Why |
|------|-----|
| `Expression.elm` | Correctly threads `tvar` through all expression constructions |
| `NormalizeLambdaBoundaries.elm` | Renames local variable names only; preserves Meta including tvar |
| `Port.elm` | Creates synthetic `Can.TVar` with `tvar = Nothing` — correctly marked as non-solver |
| `Names.elm` | Generates fresh variable names, not type variables |
| `Case.elm` | No type variable creation or modification |
| `DecisionTree.elm` | No type variable creation or modification |
