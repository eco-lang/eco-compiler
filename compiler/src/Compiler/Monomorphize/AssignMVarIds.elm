module Compiler.Monomorphize.AssignMVarIds exposing (assignIds, assignIdsToType, GlobalMVarState)

{-| Assign globally unique MVarIds to all type variables in a TypedOptimized GlobalGraph.

This pass runs once at the start of monomorphization, converting
`GlobalGraph Name` to `GlobalGraph MVarId`. After this pass, all type
variables carry sequential Int-based IDs instead of string names, and
constraint information is recorded in a side table.

@docs GlobalMVarState, assignIds, assignIdsToType

-}

import Compiler.AST.Canonical as Can
import Compiler.AST.Monomorphized as Mono
import Compiler.AST.TypeIds as TypeIds
import Compiler.AST.TypedOptimized as TOpt
import Compiler.Data.Id as Id
import Compiler.Data.Name as Name exposing (Name)
import Compiler.Reporting.Annotation as A
import Compiler.Type.SolverRoots as SolverRoots
import Data.Map as DMap
import Dict exposing (Dict)
import Set
import System.TypeCheck.IO as IO


{-| Global state threaded through the entire ID assignment pass.
-}
type alias GlobalMVarState =
    { nextId : TypeIds.MVarId
    , numberVars : Set.Set Int
    , rootEnv : Dict Int TypeIds.MVarId
    }


{-| Per-scheme mapping from type variable names to their assigned MVarIds.
Reset for each top-level definition; grows lazily as new names are encountered.
-}
type alias SchemeEnv =
    Dict Name TypeIds.MVarId


{-| Combined context threaded through the rewrite.
-}
type alias Ctx =
    { env : SchemeEnv
    , state : GlobalMVarState
    , schemeRootsForDef : SolverRoots.SchemeRootsForDef
    }



{-| Run a function with a fresh binding-local SchemeEnv, then discard the
binding-local env and restore the outer env, keeping only the evolved global state.
-}
withFreshBinding : Ctx -> (Ctx -> ( a, Ctx )) -> ( a, Ctx )
withFreshBinding outerCtx work =
    let
        bindingCtx =
            { env = Dict.empty, state = outerCtx.state, schemeRootsForDef = outerCtx.schemeRootsForDef }

        ( result, bindingCtx1 ) =
            work bindingCtx
    in
    ( result, { env = outerCtx.env, state = bindingCtx1.state, schemeRootsForDef = outerCtx.schemeRootsForDef } )



-- ============================================================================
-- ENTRY POINT
-- ============================================================================


{-| Assign globally unique MVarIds to all type variables in a GlobalGraph.
Returns the rewritten graph and the final allocator state (for initializing MVarEnv).
-}
assignIds : TOpt.GlobalGraph Name -> ( TOpt.GlobalGraph TypeIds.MVarId, GlobalMVarState )
assignIds (TOpt.GlobalGraph nodes fields annotations allSchemeRoots) =
    let
        state0 =
            { nextId = TypeIds.firstMVarId
            , numberVars = Set.empty
            , rootEnv = Dict.empty
            }

        dummyCompare _ _ =
            EQ

        ( newAnnotations, state1 ) =
            rewriteAnnotationsByGlobal allSchemeRoots annotations state0

        ( newNodes, state2 ) =
            rewriteNodes dummyCompare allSchemeRoots nodes state1
    in
    ( TOpt.GlobalGraph newNodes fields newAnnotations allSchemeRoots, state2 )



{-| Assign MVarIds to a single canonical type. Useful for testing.
Returns the rewritten type and the final state.
-}
assignIdsToType : Can.Type Name -> ( Can.Type TypeIds.MVarId, GlobalMVarState )
assignIdsToType canType =
    let
        ctx =
            { env = Dict.empty
            , state = { nextId = TypeIds.firstMVarId, numberVars = Set.empty, rootEnv = Dict.empty }
            , schemeRootsForDef = Dict.empty
            }

        ( newType, ctx1 ) =
            rewriteCanType ctx canType
    in
    ( newType, ctx1.state )



-- ============================================================================
-- ID ALLOCATION
-- ============================================================================


{-| Allocate a fresh MVarId with the given constraint.
-}
freshMVarId : Mono.Constraint -> GlobalMVarState -> ( TypeIds.MVarId, GlobalMVarState )
freshMVarId constraint state =
    let
        currentId =
            state.nextId

        newNumberVars =
            case constraint of
                Mono.CNumber ->
                    Set.insert (Id.toComparable currentId) state.numberVars

                Mono.CEcoValue ->
                    state.numberVars
    in
    ( currentId
    , { nextId = Id.succ currentId
      , numberVars = newNumberVars
      , rootEnv = state.rootEnv
      }
    )


{-| Determine constraint from type variable name prefix.
-}
constraintFromName : Name -> Mono.Constraint
constraintFromName name =
    if Name.isNumberType name then
        Mono.CNumber

    else
        Mono.CEcoValue


{-| Look up or allocate an MVarId for a type variable name.
-}
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
              , schemeRootsForDef = ctx.schemeRootsForDef
              }
            )


{-| Look up or allocate an MVarId for a solver-root-backed type variable.
Two different type variable names backed by the same solver root get the same MVarId.
-}
ensureMVarIdForRoot : IO.Variable -> Name -> Ctx -> ( TypeIds.MVarId, Ctx )
ensureMVarIdForRoot root name ctx =
    let
        rootIdx =
            case root of
                IO.Pt idx ->
                    idx
    in
    case Dict.get rootIdx ctx.state.rootEnv of
        Just mvarId ->
            ( mvarId, ctx )

        Nothing ->
            let
                ( mvarId, newState ) =
                    freshMVarId (constraintFromName name) ctx.state

                rootEnv1 =
                    Dict.insert rootIdx mvarId newState.rootEnv
            in
            ( mvarId
            , { env = ctx.env
              , state = { newState | rootEnv = rootEnv1 }
              , schemeRootsForDef = ctx.schemeRootsForDef
              }
            )



-- ============================================================================
-- ANNOTATIONS
-- ============================================================================


rewriteAnnotations :
    SolverRoots.AllSchemeRoots
    -> Dict Name (Can.Annotation Name)
    -> GlobalMVarState
    -> ( Dict Name (Can.Annotation TypeIds.MVarId), GlobalMVarState )
rewriteAnnotations allSchemeRoots annotations state =
    Dict.foldl
        (\name ann ( acc, st ) ->
            let
                schemeRootsForDef =
                    Dict.get name allSchemeRoots
                        |> Maybe.withDefault Dict.empty

                ( newAnn, st1 ) =
                    rewriteAnnotation schemeRootsForDef ann st
            in
            ( Dict.insert name newAnn acc, st1 )
        )
        ( Dict.empty, state )
        annotations


{-| Rewrite annotations keyed by Global (for GlobalGraph).
-}
rewriteAnnotationsByGlobal :
    TOpt.SchemeRootsByGlobal
    -> TOpt.AnnotationsByGlobal Name
    -> GlobalMVarState
    -> ( TOpt.AnnotationsByGlobal TypeIds.MVarId, GlobalMVarState )
rewriteAnnotationsByGlobal allSchemeRoots annotations state =
    let
        dummyCompare _ _ =
            EQ
    in
    DMap.foldl dummyCompare
        (\global ann ( acc, st ) ->
            let
                schemeRootsForDef =
                    DMap.get TOpt.toComparableGlobal global allSchemeRoots
                        |> Maybe.withDefault Dict.empty

                ( newAnn, st1 ) =
                    rewriteAnnotation schemeRootsForDef ann st
            in
            ( DMap.insert TOpt.toComparableGlobal global newAnn acc, st1 )
        )
        ( DMap.empty, state )
        annotations


rewriteAnnotation :
    SolverRoots.SchemeRootsForDef
    -> Can.Annotation Name
    -> GlobalMVarState
    -> ( Can.Annotation TypeIds.MVarId, GlobalMVarState )
rewriteAnnotation schemeRootsForDef (Can.Forall freeVars tipe) state =
    let
        -- Build SchemeEnv from FreeVars, using root-backed allocation when available
        ( env, state1 ) =
            Dict.foldl
                (\name _ ( envAcc, st ) ->
                    case Dict.get name schemeRootsForDef of
                        Just root ->
                            let
                                rootIdx =
                                    case root of
                                        IO.Pt idx ->
                                            idx
                            in
                            case Dict.get rootIdx st.rootEnv of
                                Just mvarId ->
                                    ( Dict.insert name mvarId envAcc, st )

                                Nothing ->
                                    let
                                        ( mvarId, st1 ) =
                                            freshMVarId (constraintFromName name) st

                                        rootEnv1 =
                                            Dict.insert rootIdx mvarId st1.rootEnv
                                    in
                                    ( Dict.insert name mvarId envAcc, { st1 | rootEnv = rootEnv1 } )

                        Nothing ->
                            let
                                ( mvarId, st1 ) =
                                    freshMVarId (constraintFromName name) st
                            in
                            ( Dict.insert name mvarId envAcc, st1 )
                )
                ( Dict.empty, state )
                freeVars

        ctx =
            { env = env, state = state1, schemeRootsForDef = schemeRootsForDef }

        ( newType, ctx1 ) =
            rewriteCanType ctx tipe
    in
    ( Can.Forall freeVars newType, ctx1.state )



-- ============================================================================
-- NODES
-- ============================================================================


rewriteNodes :
    (TOpt.Global -> TOpt.Global -> Order)
    -> TOpt.SchemeRootsByGlobal
    -> DMap.Dict String TOpt.Global (TOpt.Node Name)
    -> GlobalMVarState
    -> ( DMap.Dict String TOpt.Global (TOpt.Node TypeIds.MVarId), GlobalMVarState )
rewriteNodes cmp allSchemeRoots nodes state =
    DMap.foldl cmp
        (\global node ( acc, st ) ->
            let
                -- Look up scheme roots for this definition by Global key
                schemeRootsForDef =
                    DMap.get TOpt.toComparableGlobal global allSchemeRoots
                        |> Maybe.withDefault Dict.empty

                -- Fresh SchemeEnv per node, with solver roots
                ctx =
                    { env = Dict.empty, state = st, schemeRootsForDef = schemeRootsForDef }

                ( newNode, ctx1 ) =
                    rewriteNode ctx node
            in
            ( DMap.insert TOpt.toComparableGlobal global newNode acc, ctx1.state )
        )
        ( DMap.empty, state )
        nodes



rewriteNode : Ctx -> TOpt.Node Name -> ( TOpt.Node TypeIds.MVarId, Ctx )
rewriteNode ctx node =
    case node of
        TOpt.Define expr deps meta ->
            let
                ( newMeta, ctx1 ) =
                    rewriteMeta ctx meta

                ( newExpr, ctx2 ) =
                    rewriteExpr ctx1 expr
            in
            ( TOpt.Define newExpr deps newMeta, ctx2 )

        TOpt.TrackedDefine region expr deps meta ->
            let
                ( newMeta, ctx1 ) =
                    rewriteMeta ctx meta

                ( newExpr, ctx2 ) =
                    rewriteExpr ctx1 expr
            in
            ( TOpt.TrackedDefine region newExpr deps newMeta, ctx2 )

        TOpt.Ctor index arity canType ->
            let
                ( newType, ctx1 ) =
                    rewriteCanType ctx canType
            in
            ( TOpt.Ctor index arity newType, ctx1 )

        TOpt.Enum index canType ->
            let
                ( newType, ctx1 ) =
                    rewriteCanType ctx canType
            in
            ( TOpt.Enum index newType, ctx1 )

        TOpt.Box canType ->
            let
                ( newType, ctx1 ) =
                    rewriteCanType ctx canType
            in
            ( TOpt.Box newType, ctx1 )

        TOpt.Link global ->
            ( TOpt.Link global, ctx )

        TOpt.Cycle names valueDefs funcDefs deps ->
            let
                ( newValueDefs, ctx1 ) =
                    rewriteValueDefs ctx valueDefs

                ( newFuncDefs, ctx2 ) =
                    rewriteDefs ctx1 funcDefs
            in
            ( TOpt.Cycle names newValueDefs newFuncDefs deps, ctx2 )

        TOpt.Manager effectsType ->
            ( TOpt.Manager effectsType, ctx )

        TOpt.Kernel chunks deps ->
            ( TOpt.Kernel chunks deps, ctx )

        TOpt.PortIncoming expr deps meta ->
            let
                ( newMeta, ctx1 ) =
                    rewriteMeta ctx meta

                ( newExpr, ctx2 ) =
                    rewriteExpr ctx1 expr
            in
            ( TOpt.PortIncoming newExpr deps newMeta, ctx2 )

        TOpt.PortOutgoing expr deps meta ->
            let
                ( newMeta, ctx1 ) =
                    rewriteMeta ctx meta

                ( newExpr, ctx2 ) =
                    rewriteExpr ctx1 expr
            in
            ( TOpt.PortOutgoing newExpr deps newMeta, ctx2 )



-- ============================================================================
-- META
-- ============================================================================


rewriteMeta : Ctx -> TOpt.Meta Name -> ( TOpt.Meta TypeIds.MVarId, Ctx )
rewriteMeta ctx meta =
    let
        ( newType, ctx1 ) =
            rewriteCanType ctx meta.tipe
    in
    ( { tipe = newType, tvar = meta.tvar }, ctx1 )



-- ============================================================================
-- EXPRESSIONS
-- ============================================================================


rewriteExpr : Ctx -> TOpt.Expr Name -> ( TOpt.Expr TypeIds.MVarId, Ctx )
rewriteExpr ctx expr =
    case expr of
        TOpt.Bool region val meta ->
            let
                ( newMeta, ctx1 ) =
                    rewriteMeta ctx meta
            in
            ( TOpt.Bool region val newMeta, ctx1 )

        TOpt.Chr region val meta ->
            let
                ( newMeta, ctx1 ) =
                    rewriteMeta ctx meta
            in
            ( TOpt.Chr region val newMeta, ctx1 )

        TOpt.Str region val meta ->
            let
                ( newMeta, ctx1 ) =
                    rewriteMeta ctx meta
            in
            ( TOpt.Str region val newMeta, ctx1 )

        TOpt.Int region val meta ->
            let
                ( newMeta, ctx1 ) =
                    rewriteMeta ctx meta
            in
            ( TOpt.Int region val newMeta, ctx1 )

        TOpt.Float region val meta ->
            let
                ( newMeta, ctx1 ) =
                    rewriteMeta ctx meta
            in
            ( TOpt.Float region val newMeta, ctx1 )

        TOpt.VarLocal name meta ->
            let
                ( newMeta, ctx1 ) =
                    rewriteMeta ctx meta
            in
            ( TOpt.VarLocal name newMeta, ctx1 )

        TOpt.TrackedVarLocal region name meta ->
            let
                ( newMeta, ctx1 ) =
                    rewriteMeta ctx meta
            in
            ( TOpt.TrackedVarLocal region name newMeta, ctx1 )

        TOpt.VarGlobal region global meta ->
            let
                ( newMeta, ctx1 ) =
                    rewriteMeta ctx meta
            in
            ( TOpt.VarGlobal region global newMeta, ctx1 )

        TOpt.VarEnum region global index meta ->
            let
                ( newMeta, ctx1 ) =
                    rewriteMeta ctx meta
            in
            ( TOpt.VarEnum region global index newMeta, ctx1 )

        TOpt.VarBox region global meta ->
            let
                ( newMeta, ctx1 ) =
                    rewriteMeta ctx meta
            in
            ( TOpt.VarBox region global newMeta, ctx1 )

        TOpt.VarCycle region canonical name meta ->
            let
                ( newMeta, ctx1 ) =
                    rewriteMeta ctx meta
            in
            ( TOpt.VarCycle region canonical name newMeta, ctx1 )

        TOpt.VarDebug region name canonical maybeName meta ->
            let
                ( newMeta, ctx1 ) =
                    rewriteMeta ctx meta
            in
            ( TOpt.VarDebug region name canonical maybeName newMeta, ctx1 )

        TOpt.VarKernel region home name1 name2 meta ->
            let
                ( newMeta, ctx1 ) =
                    rewriteMeta ctx meta
            in
            ( TOpt.VarKernel region home name1 name2 newMeta, ctx1 )

        TOpt.List region items meta ->
            let
                ( newMeta, ctx1 ) =
                    rewriteMeta ctx meta

                ( newItems, ctx2 ) =
                    rewriteExprList ctx1 items
            in
            ( TOpt.List region newItems newMeta, ctx2 )

        TOpt.Function args body meta ->
            let
                ( newMeta, ctx1 ) =
                    rewriteMeta ctx meta

                ( newArgs, ctx2 ) =
                    rewriteTypedArgs ctx1 args

                ( newBody, ctx3 ) =
                    rewriteExpr ctx2 body
            in
            ( TOpt.Function newArgs newBody newMeta, ctx3 )

        TOpt.TrackedFunction args body meta ->
            let
                ( newMeta, ctx1 ) =
                    rewriteMeta ctx meta

                ( newArgs, ctx2 ) =
                    rewriteTrackedArgs ctx1 args

                ( newBody, ctx3 ) =
                    rewriteExpr ctx2 body
            in
            ( TOpt.TrackedFunction newArgs newBody newMeta, ctx3 )

        TOpt.Call region func args meta ->
            let
                ( newMeta, ctx1 ) =
                    rewriteMeta ctx meta

                ( newFunc, ctx2 ) =
                    rewriteExpr ctx1 func

                ( newArgs, ctx3 ) =
                    rewriteExprList ctx2 args
            in
            ( TOpt.Call region newFunc newArgs newMeta, ctx3 )

        TOpt.TailCall name args meta ->
            let
                ( newMeta, ctx1 ) =
                    rewriteMeta ctx meta

                ( newArgs, ctx2 ) =
                    rewriteNamedExprList ctx1 args
            in
            ( TOpt.TailCall name newArgs newMeta, ctx2 )

        TOpt.If branches final meta ->
            let
                ( newMeta, ctx1 ) =
                    rewriteMeta ctx meta

                ( newBranches, ctx2 ) =
                    rewriteBranches ctx1 branches

                ( newFinal, ctx3 ) =
                    rewriteExpr ctx2 final
            in
            ( TOpt.If newBranches newFinal newMeta, ctx3 )

        TOpt.Let def body meta ->
            let
                ( newMeta, ctx1 ) =
                    rewriteMeta ctx meta

                ( newDef, ctx2 ) =
                    rewriteDef ctx1 def

                ( newBody, ctx3 ) =
                    rewriteExpr ctx2 body
            in
            ( TOpt.Let newDef newBody newMeta, ctx3 )

        TOpt.Destruct destructor body meta ->
            let
                ( newMeta, ctx1 ) =
                    rewriteMeta ctx meta

                ( newDestructor, ctx2 ) =
                    rewriteDestructor ctx1 destructor

                ( newBody, ctx3 ) =
                    rewriteExpr ctx2 body
            in
            ( TOpt.Destruct newDestructor newBody newMeta, ctx3 )

        TOpt.Case scrutName scrutVarName decider jumps meta ->
            let
                ( newMeta, ctx1 ) =
                    rewriteMeta ctx meta

                ( newDecider, ctx2 ) =
                    rewriteDecider ctx1 decider

                ( newJumps, ctx3 ) =
                    rewriteJumps ctx2 jumps
            in
            ( TOpt.Case scrutName scrutVarName newDecider newJumps newMeta, ctx3 )

        TOpt.Accessor region name meta ->
            let
                ( newMeta, ctx1 ) =
                    rewriteMeta ctx meta
            in
            ( TOpt.Accessor region name newMeta, ctx1 )

        TOpt.Access subExpr region name meta ->
            let
                ( newMeta, ctx1 ) =
                    rewriteMeta ctx meta

                ( newSubExpr, ctx2 ) =
                    rewriteExpr ctx1 subExpr
            in
            ( TOpt.Access newSubExpr region name newMeta, ctx2 )

        TOpt.Update region subExpr updates meta ->
            let
                ( newMeta, ctx1 ) =
                    rewriteMeta ctx meta

                ( newSubExpr, ctx2 ) =
                    rewriteExpr ctx1 subExpr

                ( newUpdates, ctx3 ) =
                    rewriteDataMapExprs ctx2 updates
            in
            ( TOpt.Update region newSubExpr newUpdates newMeta, ctx3 )

        TOpt.Record fields meta ->
            let
                ( newMeta, ctx1 ) =
                    rewriteMeta ctx meta

                ( newFields, ctx2 ) =
                    rewriteDictExprs ctx1 fields
            in
            ( TOpt.Record newFields newMeta, ctx2 )

        TOpt.TrackedRecord region fields meta ->
            let
                ( newMeta, ctx1 ) =
                    rewriteMeta ctx meta

                ( newFields, ctx2 ) =
                    rewriteDataMapExprs ctx1 fields
            in
            ( TOpt.TrackedRecord region newFields newMeta, ctx2 )

        TOpt.Unit meta ->
            let
                ( newMeta, ctx1 ) =
                    rewriteMeta ctx meta
            in
            ( TOpt.Unit newMeta, ctx1 )

        TOpt.Tuple region a b rest meta ->
            let
                ( newMeta, ctx1 ) =
                    rewriteMeta ctx meta

                ( newA, ctx2 ) =
                    rewriteExpr ctx1 a

                ( newB, ctx3 ) =
                    rewriteExpr ctx2 b

                ( newRest, ctx4 ) =
                    rewriteExprList ctx3 rest
            in
            ( TOpt.Tuple region newA newB newRest newMeta, ctx4 )

        TOpt.Shader src attributes uniforms meta ->
            let
                ( newMeta, ctx1 ) =
                    rewriteMeta ctx meta
            in
            ( TOpt.Shader src attributes uniforms newMeta, ctx1 )



-- ============================================================================
-- HELPERS: Lists and collections
-- ============================================================================


rewriteExprList : Ctx -> List (TOpt.Expr Name) -> ( List (TOpt.Expr TypeIds.MVarId), Ctx )
rewriteExprList ctx exprs =
    List.foldl
        (\e ( acc, c ) ->
            let
                ( newE, c1 ) =
                    rewriteExpr c e
            in
            ( newE :: acc, c1 )
        )
        ( [], ctx )
        exprs
        |> Tuple.mapFirst List.reverse


rewriteNamedExprList : Ctx -> List ( Name, TOpt.Expr Name ) -> ( List ( Name, TOpt.Expr TypeIds.MVarId ), Ctx )
rewriteNamedExprList ctx pairs =
    List.foldl
        (\( name, e ) ( acc, c ) ->
            let
                ( newE, c1 ) =
                    rewriteExpr c e
            in
            ( ( name, newE ) :: acc, c1 )
        )
        ( [], ctx )
        pairs
        |> Tuple.mapFirst List.reverse


rewriteBranches : Ctx -> List ( TOpt.Expr Name, TOpt.Expr Name ) -> ( List ( TOpt.Expr TypeIds.MVarId, TOpt.Expr TypeIds.MVarId ), Ctx )
rewriteBranches ctx branches =
    List.foldl
        (\( cond, body ) ( acc, c ) ->
            let
                ( newCond, c1 ) =
                    rewriteExpr c cond

                ( newBody, c2 ) =
                    rewriteExpr c1 body
            in
            ( ( newCond, newBody ) :: acc, c2 )
        )
        ( [], ctx )
        branches
        |> Tuple.mapFirst List.reverse


rewriteTypedArgs : Ctx -> List ( Name, Can.Type Name ) -> ( List ( Name, Can.Type TypeIds.MVarId ), Ctx )
rewriteTypedArgs ctx args =
    List.foldl
        (\( name, tipe ) ( acc, c ) ->
            let
                ( newType, c1 ) =
                    rewriteCanType c tipe
            in
            ( ( name, newType ) :: acc, c1 )
        )
        ( [], ctx )
        args
        |> Tuple.mapFirst List.reverse


rewriteTrackedArgs : Ctx -> List ( A.Located Name, Can.Type Name ) -> ( List ( A.Located Name, Can.Type TypeIds.MVarId ), Ctx )
rewriteTrackedArgs ctx args =
    List.foldl
        (\( locName, tipe ) ( acc, c ) ->
            let
                ( newType, c1 ) =
                    rewriteCanType c tipe
            in
            ( ( locName, newType ) :: acc, c1 )
        )
        ( [], ctx )
        args
        |> Tuple.mapFirst List.reverse


rewriteDictExprs : Ctx -> Dict Name (TOpt.Expr Name) -> ( Dict Name (TOpt.Expr TypeIds.MVarId), Ctx )
rewriteDictExprs ctx dict =
    Dict.foldl
        (\key e ( acc, c ) ->
            let
                ( newE, c1 ) =
                    rewriteExpr c e
            in
            ( Dict.insert key newE acc, c1 )
        )
        ( Dict.empty, ctx )
        dict


rewriteDataMapExprs : Ctx -> DMap.Dict String (A.Located Name) (TOpt.Expr Name) -> ( DMap.Dict String (A.Located Name) (TOpt.Expr TypeIds.MVarId), Ctx )
rewriteDataMapExprs ctx dmap =
    let
        dummyCompare _ _ =
            EQ

        toComparable (A.At _ name) =
            name
    in
    DMap.foldl dummyCompare
        (\key e ( acc, c ) ->
            let
                ( newE, c1 ) =
                    rewriteExpr c e
            in
            ( DMap.insert toComparable key newE acc, c1 )
        )
        ( DMap.empty, ctx )
        dmap


rewriteValueDefs : Ctx -> List ( Name, TOpt.Expr Name ) -> ( List ( Name, TOpt.Expr TypeIds.MVarId ), Ctx )
rewriteValueDefs ctx defs =
    List.foldl
        (\( name, expr ) ( acc, outerCtx ) ->
            let
                ( newExpr, outerCtx1 ) =
                    withFreshBinding outerCtx (\bindingCtx -> rewriteExpr bindingCtx expr)
            in
            ( ( name, newExpr ) :: acc, outerCtx1 )
        )
        ( [], ctx )
        defs
        |> Tuple.mapFirst List.reverse


rewriteDefs : Ctx -> List (TOpt.Def Name) -> ( List (TOpt.Def TypeIds.MVarId), Ctx )
rewriteDefs ctx defs =
    List.foldl
        (\d ( acc, c ) ->
            let
                ( newD, c1 ) =
                    rewriteDef c d
            in
            ( newD :: acc, c1 )
        )
        ( [], ctx )
        defs
        |> Tuple.mapFirst List.reverse


rewriteDef : Ctx -> TOpt.Def Name -> ( TOpt.Def TypeIds.MVarId, Ctx )
rewriteDef outerCtx def =
    case def of
        TOpt.Def region name body canType ->
            withFreshBinding outerCtx
                (\bindingCtx ->
                    let
                        ( newType, bindingCtx1 ) =
                            rewriteCanType bindingCtx canType

                        ( newBody, bindingCtx2 ) =
                            rewriteExpr bindingCtx1 body
                    in
                    ( TOpt.Def region name newBody newType, bindingCtx2 )
                )

        TOpt.TailDef region name args body canType maybeTvar ->
            withFreshBinding outerCtx
                (\bindingCtx ->
                    let
                        ( newType, bindingCtx1 ) =
                            rewriteCanType bindingCtx canType

                        ( newArgs, bindingCtx2 ) =
                            rewriteTrackedArgs bindingCtx1 args

                        ( newBody, bindingCtx3 ) =
                            rewriteExpr bindingCtx2 body
                    in
                    ( TOpt.TailDef region name newArgs newBody newType maybeTvar, bindingCtx3 )
                )



rewriteDestructor : Ctx -> TOpt.Destructor Name -> ( TOpt.Destructor TypeIds.MVarId, Ctx )
rewriteDestructor ctx (TOpt.Destructor name path meta) =
    let
        ( newMeta, ctx1 ) =
            rewriteMeta ctx meta
    in
    ( TOpt.Destructor name path newMeta, ctx1 )


rewriteDecider : Ctx -> TOpt.Decider (TOpt.Choice Name) -> ( TOpt.Decider (TOpt.Choice TypeIds.MVarId), Ctx )
rewriteDecider ctx decider =
    case decider of
        TOpt.Leaf choice ->
            let
                ( newChoice, ctx1 ) =
                    rewriteChoice ctx choice
            in
            ( TOpt.Leaf newChoice, ctx1 )

        TOpt.Chain tests yes no ->
            let
                ( newYes, ctx1 ) =
                    rewriteDecider ctx yes

                ( newNo, ctx2 ) =
                    rewriteDecider ctx1 no
            in
            ( TOpt.Chain tests newYes newNo, ctx2 )

        TOpt.FanOut path options fallback ->
            let
                ( newOptions, ctx1 ) =
                    List.foldl
                        (\( test, dec ) ( acc, c ) ->
                            let
                                ( newDec, c1 ) =
                                    rewriteDecider c dec
                            in
                            ( ( test, newDec ) :: acc, c1 )
                        )
                        ( [], ctx )
                        options
                        |> Tuple.mapFirst List.reverse

                ( newFallback, ctx2 ) =
                    rewriteDecider ctx1 fallback
            in
            ( TOpt.FanOut path newOptions newFallback, ctx2 )


rewriteChoice : Ctx -> TOpt.Choice Name -> ( TOpt.Choice TypeIds.MVarId, Ctx )
rewriteChoice ctx choice =
    case choice of
        TOpt.Inline expr ->
            let
                ( newExpr, ctx1 ) =
                    rewriteExpr ctx expr
            in
            ( TOpt.Inline newExpr, ctx1 )

        TOpt.Jump idx ->
            ( TOpt.Jump idx, ctx )


rewriteJumps : Ctx -> List ( Int, TOpt.Expr Name ) -> ( List ( Int, TOpt.Expr TypeIds.MVarId ), Ctx )
rewriteJumps ctx jumps =
    List.foldl
        (\( idx, e ) ( acc, c ) ->
            let
                ( newE, c1 ) =
                    rewriteExpr c e
            in
            ( ( idx, newE ) :: acc, c1 )
        )
        ( [], ctx )
        jumps
        |> Tuple.mapFirst List.reverse



-- ============================================================================
-- CANONICAL TYPE REWRITING
-- ============================================================================


rewriteCanType : Ctx -> Can.Type Name -> ( Can.Type TypeIds.MVarId, Ctx )
rewriteCanType ctx canType =
    case canType of
        Can.TVar name ->
            let
                ( mvarId, ctx1 ) =
                    case Dict.get name ctx.schemeRootsForDef of
                        Just root ->
                            ensureMVarIdForRoot root name ctx

                        Nothing ->
                            ensureMVarId name ctx
            in
            ( Can.TVar mvarId, ctx1 )

        Can.TLambda from to ->
            let
                ( newFrom, ctx1 ) =
                    rewriteCanType ctx from

                ( newTo, ctx2 ) =
                    rewriteCanType ctx1 to
            in
            ( Can.TLambda newFrom newTo, ctx2 )

        Can.TType canonical name args ->
            let
                ( newArgs, ctx1 ) =
                    rewriteCanTypeList ctx args
            in
            ( Can.TType canonical name newArgs, ctx1 )

        Can.TRecord fields maybeExt ->
            let
                ( newFields, ctx1 ) =
                    rewriteFieldTypes ctx fields

                ( newExt, ctx2 ) =
                    case maybeExt of
                        Just extName ->
                            let
                                ( mvarId, c ) =
                                    case Dict.get extName ctx1.schemeRootsForDef of
                                        Just root ->
                                            ensureMVarIdForRoot root extName ctx1

                                        Nothing ->
                                            ensureMVarId extName ctx1
                            in
                            ( Just mvarId, c )

                        Nothing ->
                            ( Nothing, ctx1 )
            in
            ( Can.TRecord newFields newExt, ctx2 )

        Can.TUnit ->
            ( Can.TUnit, ctx )

        Can.TTuple a b rest ->
            let
                ( newA, ctx1 ) =
                    rewriteCanType ctx a

                ( newB, ctx2 ) =
                    rewriteCanType ctx1 b

                ( newRest, ctx3 ) =
                    rewriteCanTypeList ctx2 rest
            in
            ( Can.TTuple newA newB newRest, ctx3 )

        Can.TAlias canonical name args aliasType ->
            let
                ( newArgs, ctx1 ) =
                    List.foldl
                        (\( argName, t ) ( acc, c ) ->
                            let
                                -- Convert alias parameter name to MVarId, using root if available
                                ( paramId, c0 ) =
                                    case Dict.get argName c.schemeRootsForDef of
                                        Just root ->
                                            ensureMVarIdForRoot root argName c

                                        Nothing ->
                                            ensureMVarId argName c

                                ( newT, c1 ) =
                                    rewriteCanType c0 t
                            in
                            ( ( paramId, newT ) :: acc, c1 )
                        )
                        ( [], ctx )
                        args
                        |> Tuple.mapFirst List.reverse

                ( newAliasType, ctx2 ) =
                    rewriteAliasType ctx1 aliasType
            in
            ( Can.TAlias canonical name newArgs newAliasType, ctx2 )


rewriteCanTypeList : Ctx -> List (Can.Type Name) -> ( List (Can.Type TypeIds.MVarId), Ctx )
rewriteCanTypeList ctx types =
    List.foldl
        (\t ( acc, c ) ->
            let
                ( newT, c1 ) =
                    rewriteCanType c t
            in
            ( newT :: acc, c1 )
        )
        ( [], ctx )
        types
        |> Tuple.mapFirst List.reverse


rewriteFieldTypes : Ctx -> Dict Name (Can.FieldType Name) -> ( Dict Name (Can.FieldType TypeIds.MVarId), Ctx )
rewriteFieldTypes ctx fields =
    Dict.foldl
        (\fieldName (Can.FieldType idx t) ( acc, c ) ->
            let
                ( newT, c1 ) =
                    rewriteCanType c t
            in
            ( Dict.insert fieldName (Can.FieldType idx newT) acc, c1 )
        )
        ( Dict.empty, ctx )
        fields


rewriteAliasType : Ctx -> Can.AliasType Name -> ( Can.AliasType TypeIds.MVarId, Ctx )
rewriteAliasType ctx aliasType =
    case aliasType of
        Can.Holey t ->
            let
                ( newT, ctx1 ) =
                    rewriteCanType ctx t
            in
            ( Can.Holey newT, ctx1 )

        Can.Filled t ->
            let
                ( newT, ctx1 ) =
                    rewriteCanType ctx t
            in
            ( Can.Filled newT, ctx1 )
