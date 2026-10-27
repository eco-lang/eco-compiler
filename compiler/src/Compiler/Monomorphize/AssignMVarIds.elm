module Compiler.Monomorphize.AssignMVarIds exposing
    ( GlobalMVarState, assignIds, assignIdsToType
    , freshMVarId, mintLamId, mintArrowId
    )

{-| Monomorphization needs each type variable of the whole program to have one
identity, unique across the program, where the type checker gave it only a name
that means something inside one annotation. This module gives every type
variable, lambda and arrow of a merged typed graph such an identity, turning a
`TOpt.GlobalGraph Name` into a `TOpt.GlobalGraph MVarId`.

Three supplies of ids are drawn from as the graph is walked. An _MVarId_ names a
type variable. A source-lambda id is stamped onto every `Function` and
`TrackedFunction`, replacing whatever id it had. An _ArrowId_ is put into the
slot of every `Can.TLambda`, so every arrow of the output carries an `Arrow`
slot. The three id types are described in `Compiler.AST.TypeIds`.

A type variable's super-type, such as `number` or `comparable`, is not kept in
the type. It is recorded in a side table, the _super table_ (`superVars`),
keyed by the MVarId, and a variable with no super-type has no entry. In
`assignIds` the super-type is read from the graph's scheme roots or its
var-supers table; `assignIds` never infers a super-type from how a name is
spelled.

Names are resolved within a _scope_, in which one name means one MVarId. Each
global's annotation and each global's node starts a new scope, and so does each
local definition and each value of a `Cycle`; a scope's names are dropped when
it ends, while the supplies carry on. A name that the global's scheme roots
(`SolverRoots.SchemeRootsForDef`) map to a solver root is resolved through that
root instead: every name of one module whose variable the type checker put in
one class gets one MVarId, in every scope of that module, and its super-type is
the one recorded on the root. A root index is numbered from zero in each
module's solve, so roots are keyed by the pair of home module and index; an
unscoped index would join unrelated variables of different modules.

Arrows are resolved the same way when `assignIds` is asked to use solver roots:
every arrow stamped with one `SolverRoot` of one module gets one `ArrowId`.
Otherwise, and for any arrow without a `SolverRoot` stamp, each occurrence gets
a fresh `ArrowId`.

The walk visits the annotations and then the nodes, each in key order, so the
ids are the same every time a given graph is processed. The returned state
holds the supplies where the walk left them; `freshMVarId`, `mintLamId` and
`mintArrowId` draw further ids from it that collide with none assigned here.

@docs GlobalMVarState, assignIds, assignIdsToType
@docs freshMVarId, mintLamId, mintArrowId

-}

import Compiler.AST.Canonical as Can
import Compiler.AST.TypeIds as TypeIds
import Compiler.AST.TypeVars as Vars
import Compiler.AST.TypedOptimized as TOpt
import Compiler.Data.Id as Id
import Compiler.Data.Name exposing (Name)
import Compiler.Elm.ModuleName as ModuleName
import Compiler.Reporting.Annotation as A
import Compiler.Type.SolverRoots as SolverRoots
import Data.Map as DMap
import Dict exposing (Dict)


{-| The id supplies and side tables of one assignment, together with the
counts of an optional census.

`superVars` is the super table, keyed by `Id.toComparable` of an MVarId.
`lamLabels` has one key per source-lambda id minted, each with the value `""`;
only its size is meaningful. `rootEnv` and `arrowRootEnv` map a pair of home
module and solver root index to the MVarId or `ArrowId` given to that root, and
are empty in the state `assignIds` returns.

The census, kept only when `stampCensusOn` is set, classifies each type the walk
starts on (not each subtree) by the number of new `ArrowId`s it drew from the
supply: all of them stamped (`typesAll`), none (`typesNone`, with
`arrowsInNone`), or some (`typesPartial`, with `arrowsUnstampedInPartial`). A
type that draws no new `ArrowId` (no arrows, or every arrow reusing a root's id)
is not counted. Nothing increments `arrowsStamped`, so every counted type is
counted in `typesNone`.

-}
type alias GlobalMVarState =
    { nextId : TypeIds.MVarId
    , superVars : Dict Int Vars.SuperType
    , rootEnv : Dict ( String, Int ) TypeIds.MVarId
    , nextLam : TypeIds.SrcLambdaId
    , lamLabels : Dict Int String
    , nextArrow : TypeIds.ArrowId
    , arrowRootEnv : Dict ( String, Int ) TypeIds.ArrowId

    -- The census
    , stampCensusOn : Bool
    , arrowsStamped : Int -- arrows with a SolverRoot stamp; nothing increments it
    , typesAll : Int
    , typesNone : Int
    , typesPartial : Int
    , arrowsInNone : Int
    , arrowsUnstampedInPartial : Int
    }


{-| The MVarIds given to the type variable names of one scope, as the module
docstring defines a scope. A name is added when it is first met.

This is a name for a `Dict`, not a new type.

-}
type alias SchemeEnv =
    Dict Name TypeIds.MVarId


{-| The current scope, the state being threaded, and what the walk knows about
the global it is inside: its scheme roots, the super-types of names without a
root, and its home module's key.
-}
type alias Ctx =
    { env : SchemeEnv
    , state : GlobalMVarState
    , schemeRootsForDef : SolverRoots.SchemeRootsForDef
    , varSupers : Dict Name Vars.SuperType
    , moduleKey : String
    , defKey : String -- the enclosing global's key; nothing reads it
    , useSolverRoots : Bool -- one ArrowId per SolverRoot, rather than one per arrow
    }


{-| Returns the next source-lambda id and the context with the supply advanced
and the id added to `lamLabels`.
-}
freshLamId : Ctx -> ( TypeIds.SrcLambdaId, Ctx )
freshLamId ctx =
    let
        st =
            ctx.state

        lamId =
            st.nextLam

        key =
            Id.toComparable lamId
    in
    ( lamId
    , { ctx
        | state =
            { st
                | nextLam = Id.succ lamId
                , lamLabels = Dict.insert key "" st.lamLabels
            }
      }
    )


{-| Returns the next source-lambda id and the state with the supply advanced
and the id added to `lamLabels`, for code that holds a `GlobalMVarState` after
assignment. Drawing every later lambda id from this supply keeps it clear of
every id already given.
-}
mintLamId : GlobalMVarState -> ( TypeIds.SrcLambdaId, GlobalMVarState )
mintLamId st =
    let
        lamId =
            st.nextLam
    in
    ( lamId
    , { st
        | nextLam = Id.succ lamId
        , lamLabels = Dict.insert (Id.toComparable lamId) "" st.lamLabels
      }
    )


{-| Returns the next `ArrowId` and the state with the supply advanced, for
code that holds a `GlobalMVarState` after assignment.
-}
mintArrowId : GlobalMVarState -> ( TypeIds.ArrowId, GlobalMVarState )
mintArrowId st =
    ( st.nextArrow, { st | nextArrow = Id.succ st.nextArrow } )


{-| Returns the next `ArrowId` and the context with the supply advanced.
-}
freshArrowId : Ctx -> ( TypeIds.ArrowId, Ctx )
freshArrowId ctx =
    let
        st =
            ctx.state

        arrowId =
            st.nextArrow
    in
    ( arrowId, { ctx | state = { st | nextArrow = Id.succ arrowId } } )


{-| Returns the `ArrowId` of the solver root `rootIdx` of the current module,
giving the root a fresh one the first time it is met.

Arrows stamped with the same root share an `ArrowId` even where they are
separate occurrences, such as an annotation's arrow and the matching arrow of
the body.

-}
ensureArrowIdForRoot : Int -> Ctx -> ( TypeIds.ArrowId, Ctx )
ensureArrowIdForRoot rootIdx ctx =
    let
        key =
            ( ctx.moduleKey, rootIdx )
    in
    case Dict.get key ctx.state.arrowRootEnv of
        Just arrowId ->
            ( arrowId, ctx )

        Nothing ->
            let
                ( arrowId, ctx1 ) =
                    freshArrowId ctx

                st =
                    ctx1.state
            in
            ( arrowId, { ctx1 | state = { st | arrowRootEnv = Dict.insert key arrowId st.arrowRootEnv } } )


{-| Runs `work` in a new, empty scope and returns its result with the outer
scope restored and the state `work` left behind.
-}
withFreshBinding : Ctx -> (Ctx -> ( a, Ctx )) -> ( a, Ctx )
withFreshBinding outerCtx work =
    let
        bindingCtx =
            { outerCtx | env = Dict.empty }

        ( result, bindingCtx1 ) =
            work bindingCtx
    in
    ( result, { outerCtx | state = bindingCtx1.state } )



-- ============================================================================
-- ENTRY POINT
-- ============================================================================


{-| Returns `graph` with an identity given to every type variable, lambda and
arrow, as the module docstring describes, and the state the supplies ended in.

The first flag makes arrows stamped with the same `SolverRoot` share an `ArrowId`; the
second turns the census on. The output graph's scheme-roots and var-supers
tables are empty, and so are `rootEnv` and `arrowRootEnv` in the returned state.

-}
assignIds : Bool -> Bool -> TOpt.GlobalGraph Name -> ( TOpt.GlobalGraph TypeIds.MVarId, GlobalMVarState )
assignIds useSolverRoots censusOn (TOpt.GlobalGraph nodes fields annotations allSchemeRoots varSupers) =
    let
        state0 =
            { nextId = TypeIds.firstMVarId
            , superVars = Dict.empty
            , rootEnv = Dict.empty
            , nextLam = TypeIds.firstSrcLambdaId
            , lamLabels = Dict.empty
            , nextArrow = TypeIds.firstArrowId
            , arrowRootEnv = Dict.empty
            , stampCensusOn = censusOn
            , arrowsStamped = 0
            , typesAll = 0
            , typesNone = 0
            , typesPartial = 0
            , arrowsInNone = 0
            , arrowsUnstampedInPartial = 0
            }

        ( newAnnotations, state1 ) =
            rewriteAnnotationsByGlobal useSolverRoots varSupers allSchemeRoots annotations state0

        ( newNodes, state2 ) =
            rewriteNodes useSolverRoots varSupers allSchemeRoots nodes state1
    in
    ( TOpt.GlobalGraph newNodes fields newAnnotations DMap.empty Dict.empty
    , { state2 | rootEnv = Dict.empty, arrowRootEnv = Dict.empty }
    )


{-| Returns `canType` with ids assigned as for one annotation, and the state
the supplies ended in.

There are no solver roots here, so every arrow gets a fresh `ArrowId`, and each
variable's super-type is taken from its name by `TOpt.varSupersOfType`.

-}
assignIdsToType : Can.Type Name -> ( Can.Type TypeIds.MVarId, GlobalMVarState )
assignIdsToType canType =
    let
        ctx =
            { env = Dict.empty
            , state = { nextId = TypeIds.firstMVarId, superVars = Dict.empty, rootEnv = Dict.empty, nextLam = TypeIds.firstSrcLambdaId, lamLabels = Dict.empty, nextArrow = TypeIds.firstArrowId, arrowRootEnv = Dict.empty, stampCensusOn = False, arrowsStamped = 0, typesAll = 0, typesNone = 0, typesPartial = 0, arrowsInNone = 0, arrowsUnstampedInPartial = 0 }
            , schemeRootsForDef = Dict.empty
            , varSupers = TOpt.varSupersOfType canType
            , moduleKey = ""
            , defKey = ""
            , useSolverRoots = False
            }

        ( newType, ctx1 ) =
            rewriteCanTypeTop ctx canType
    in
    ( newType, ctx1.state )



-- ============================================================================
-- ID ALLOCATION
-- ============================================================================


{-| Returns the next MVarId and the state with the supply advanced and
`maybeSuper`, when present, recorded for it in the super table.
-}
freshMVarId : Maybe Vars.SuperType -> GlobalMVarState -> ( TypeIds.MVarId, GlobalMVarState )
freshMVarId maybeSuper state =
    let
        currentId =
            state.nextId

        newSuperVars =
            case maybeSuper of
                Just s ->
                    Dict.insert (Id.toComparable currentId) s state.superVars

                Nothing ->
                    state.superVars
    in
    ( currentId
    , { state
        | nextId = Id.succ currentId
        , superVars = newSuperVars
      }
    )


{-| Returns the MVarId of `name` in the current scope, giving it a fresh one
the first time it is met. A fresh id takes the super-type the context's
`varSupers` records for the name.
-}
ensureMVarId : Name -> Ctx -> ( TypeIds.MVarId, Ctx )
ensureMVarId name ctx =
    case Dict.get name ctx.env of
        Just mvarId ->
            ( mvarId, ctx )

        Nothing ->
            let
                ( mvarId, newState ) =
                    freshMVarId (Dict.get name ctx.varSupers) ctx.state
            in
            ( mvarId
            , { ctx | env = Dict.insert name mvarId ctx.env, state = newState }
            )


{-| Returns the MVarId of `rooted`'s solver root in the current module, giving
the root a fresh one, with the super-type recorded on `rooted`, the first time
it is met.

All names backed by one root share the id, and the super-type of whichever name
reaches the root first is the one recorded.

-}
ensureMVarIdForRoot : Vars.RootedVar -> Ctx -> ( TypeIds.MVarId, Ctx )
ensureMVarIdForRoot rooted ctx =
    let
        rootIdx =
            case rooted.var of
                Vars.Pt idx ->
                    idx

        key =
            ( ctx.moduleKey, rootIdx )
    in
    case Dict.get key ctx.state.rootEnv of
        Just mvarId ->
            ( mvarId, ctx )

        Nothing ->
            let
                ( mvarId, newState ) =
                    freshMVarId rooted.super ctx.state

                rootEnv1 =
                    Dict.insert key mvarId newState.rootEnv
            in
            ( mvarId
            , { ctx | state = { newState | rootEnv = rootEnv1 } }
            )


{-| Returns the MVarId of the type variable `name`: through its solver root when
the global's scheme roots record one, and through the current scope otherwise.
-}
ensureBinder : Name -> Ctx -> ( TypeIds.MVarId, Ctx )
ensureBinder name ctx =
    case Dict.get name ctx.schemeRootsForDef of
        Just rooted ->
            ensureMVarIdForRoot rooted ctx

        Nothing ->
            ensureMVarId name ctx



-- ============================================================================
-- ANNOTATIONS
-- ============================================================================


{-| Returns every global's annotation with ids assigned, in key order, each in
its own scope.
-}
rewriteAnnotationsByGlobal :
    Bool
    -> Dict Name Vars.SuperType
    -> TOpt.SchemeRootsByGlobal
    -> TOpt.AnnotationsByGlobal Name
    -> GlobalMVarState
    -> ( TOpt.AnnotationsByGlobal TypeIds.MVarId, GlobalMVarState )
rewriteAnnotationsByGlobal useSolverRoots varSupers allSchemeRoots annotations state =
    DMap.foldl
        (\global ann ( acc, st ) ->
            let
                schemeRootsForDef =
                    DMap.get TOpt.toComparableGlobal global allSchemeRoots
                        |> Maybe.withDefault Dict.empty

                ( newAnn, st1 ) =
                    rewriteAnnotation useSolverRoots varSupers (moduleKeyOf global) schemeRootsForDef ann st
            in
            ( DMap.insert TOpt.toComparableGlobal global newAnn acc, st1 )
        )
        ( DMap.empty, state )
        annotations


{-| Returns the key of `global`'s home module, which scopes solver root indices.
-}
moduleKeyOf : TOpt.Global -> String
moduleKeyOf global =
    case global of
        TOpt.Global home _ ->
            ModuleName.toComparableCanonical home


{-| Returns the annotation with ids assigned in a new scope. Its declared
variables are bound first, in name order, before the type is walked.
-}
rewriteAnnotation :
    Bool
    -> Dict Name Vars.SuperType
    -> String
    -> SolverRoots.SchemeRootsForDef
    -> Can.Annotation Name
    -> GlobalMVarState
    -> ( Can.Annotation TypeIds.MVarId, GlobalMVarState )
rewriteAnnotation useSolverRoots varSupers moduleKey schemeRootsForDef (Can.Forall freeVars tipe) state =
    let
        ctx0 =
            { env = Dict.empty
            , state = state
            , schemeRootsForDef = schemeRootsForDef
            , varSupers = varSupers
            , moduleKey = moduleKey
            , defKey = ""
            , useSolverRoots = useSolverRoots
            }

        -- A rooted variable bound here keeps its id in this global's node, which
        -- has its own scope.
        ctxSeeded =
            Dict.foldl (\name _ c -> Tuple.second (ensureBinder name c)) ctx0 freeVars

        ( newType, ctx1 ) =
            rewriteCanTypeTop ctxSeeded tipe
    in
    ( Can.Forall freeVars newType, ctx1.state )



-- ============================================================================
-- NODES
-- ============================================================================


{-| Returns every global's node with ids assigned, in key order, each in its own
scope.
-}
rewriteNodes :
    Bool
    -> Dict Name Vars.SuperType
    -> TOpt.SchemeRootsByGlobal
    -> DMap.Dict String TOpt.Global (TOpt.Node Name)
    -> GlobalMVarState
    -> ( DMap.Dict String TOpt.Global (TOpt.Node TypeIds.MVarId), GlobalMVarState )
rewriteNodes useSolverRoots varSupers allSchemeRoots nodes state =
    DMap.foldl
        (\global node ( acc, st ) ->
            let
                schemeRootsForDef =
                    DMap.get TOpt.toComparableGlobal global allSchemeRoots
                        |> Maybe.withDefault Dict.empty

                ctx =
                    { env = Dict.empty
                    , state = st
                    , schemeRootsForDef = schemeRootsForDef
                    , varSupers = varSupers
                    , moduleKey = moduleKeyOf global
                    , defKey = TOpt.toComparableGlobal global
                    , useSolverRoots = useSolverRoots
                    }

                ( newNode, ctx1 ) =
                    rewriteNode ctx node
            in
            ( DMap.insert TOpt.toComparableGlobal global newNode acc, ctx1.state )
        )
        ( DMap.empty, state )
        nodes


{-| Returns `node` with ids assigned. `Link`, `Manager` and `Kernel` nodes carry
no types and are returned unchanged.
-}
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
                    rewriteCanTypeTop ctx canType
            in
            ( TOpt.Ctor index arity newType, ctx1 )

        TOpt.Enum index canType ->
            let
                ( newType, ctx1 ) =
                    rewriteCanTypeTop ctx canType
            in
            ( TOpt.Enum index newType, ctx1 )

        TOpt.Box canType ->
            let
                ( newType, ctx1 ) =
                    rewriteCanTypeTop ctx canType
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


{-| Returns `meta` with ids assigned in its type; its `tvar` is kept.
-}
rewriteMeta : Ctx -> TOpt.Meta Name -> ( TOpt.Meta TypeIds.MVarId, Ctx )
rewriteMeta ctx meta =
    let
        ( newType, ctx1 ) =
            rewriteCanTypeTop ctx meta.tipe
    in
    ( { tipe = newType, tvar = meta.tvar }, ctx1 )



-- ============================================================================
-- EXPRESSIONS
-- ============================================================================


{-| Returns `expr` with ids assigned throughout, each function getting a fresh
source-lambda id. Types are walked before subexpressions, in source order.
-}
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

        TOpt.Function _ args body meta ->
            let
                ( lamId, ctx0a ) =
                    freshLamId ctx

                ( newMeta, ctx1 ) =
                    rewriteMeta ctx0a meta

                ( newArgs, ctx2 ) =
                    rewriteTypedArgs ctx1 args

                ( newBody, ctx3 ) =
                    rewriteExpr ctx2 body
            in
            ( TOpt.Function (Just lamId) newArgs newBody newMeta, ctx3 )

        TOpt.TrackedFunction _ args body meta ->
            let
                ( lamId, ctx0a ) =
                    freshLamId ctx

                ( newMeta, ctx1 ) =
                    rewriteMeta ctx0a meta

                ( newArgs, ctx2 ) =
                    rewriteTrackedArgs ctx1 args

                ( newBody, ctx3 ) =
                    rewriteExpr ctx2 body
            in
            ( TOpt.TrackedFunction (Just lamId) newArgs newBody newMeta, ctx3 )

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


{-| Returns the expressions with ids assigned, in order.
-}
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


{-| Returns the named expressions with ids assigned, in order.
-}
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


{-| Returns the `if` branches with ids assigned, each condition before its body.
-}
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


{-| Returns the function arguments with ids assigned in their types.
-}
rewriteTypedArgs : Ctx -> List ( Name, Can.Type Name ) -> ( List ( Name, Can.Type TypeIds.MVarId ), Ctx )
rewriteTypedArgs ctx args =
    List.foldl
        (\( name, tipe ) ( acc, c ) ->
            let
                ( newType, c1 ) =
                    rewriteCanTypeTop c tipe
            in
            ( ( name, newType ) :: acc, c1 )
        )
        ( [], ctx )
        args
        |> Tuple.mapFirst List.reverse


{-| Returns the located function arguments with ids assigned in their types.
-}
rewriteTrackedArgs : Ctx -> List ( A.Located Name, Can.Type Name ) -> ( List ( A.Located Name, Can.Type TypeIds.MVarId ), Ctx )
rewriteTrackedArgs ctx args =
    List.foldl
        (\( locName, tipe ) ( acc, c ) ->
            let
                ( newType, c1 ) =
                    rewriteCanTypeTop c tipe
            in
            ( ( locName, newType ) :: acc, c1 )
        )
        ( [], ctx )
        args
        |> Tuple.mapFirst List.reverse


{-| Returns the record fields with ids assigned, in field-name order.
-}
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


{-| Returns the located record fields with ids assigned, in field-name order.
-}
rewriteDataMapExprs : Ctx -> DMap.Dict String (A.Located Name) (TOpt.Expr Name) -> ( DMap.Dict String (A.Located Name) (TOpt.Expr TypeIds.MVarId), Ctx )
rewriteDataMapExprs ctx dmap =
    let
        toComparable (A.At _ name) =
            name
    in
    DMap.foldl
        (\key e ( acc, c ) ->
            let
                ( newE, c1 ) =
                    rewriteExpr c e
            in
            ( DMap.insert toComparable key newE acc, c1 )
        )
        ( DMap.empty, ctx )
        dmap


{-| Returns a `Cycle`'s value definitions with ids assigned, each in a new scope.
-}
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


{-| Returns the definitions with ids assigned, in order.
-}
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


{-| Returns the local definition with ids assigned in a new scope: its type
first, then any arguments, then its body. A `TailDef`'s `tvar` is kept.
-}
rewriteDef : Ctx -> TOpt.Def Name -> ( TOpt.Def TypeIds.MVarId, Ctx )
rewriteDef outerCtx def =
    case def of
        TOpt.Def region name body canType ->
            withFreshBinding outerCtx
                (\bindingCtx ->
                    let
                        ( newType, bindingCtx1 ) =
                            rewriteCanTypeTop bindingCtx canType

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
                            rewriteCanTypeTop bindingCtx canType

                        ( newArgs, bindingCtx2 ) =
                            rewriteTrackedArgs bindingCtx1 args

                        ( newBody, bindingCtx3 ) =
                            rewriteExpr bindingCtx2 body
                    in
                    ( TOpt.TailDef region name newArgs newBody newType maybeTvar, bindingCtx3 )
                )


{-| Returns the destructor with ids assigned in its type.
-}
rewriteDestructor : Ctx -> TOpt.Destructor Name -> ( TOpt.Destructor TypeIds.MVarId, Ctx )
rewriteDestructor ctx (TOpt.Destructor name path meta) =
    let
        ( newMeta, ctx1 ) =
            rewriteMeta ctx meta
    in
    ( TOpt.Destructor name path newMeta, ctx1 )


{-| Returns the decision tree with ids assigned in its inline branches.
-}
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


{-| Returns the choice with ids assigned; a jump is unchanged.
-}
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


{-| Returns the jump targets with ids assigned, in order.
-}
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


{-| Returns `canType` with ids assigned, and, when the census is on, counts it
in the census by how many new `ArrowId`s it drew from the supply.

Only a type the walk starts on is counted, not its subtrees, so this is called
for each such type and `rewriteCanType` recurses without it. The arrow count is
the advance of the `ArrowId` supply during the call, and the stamped count the
advance of `arrowsStamped`, which nothing increments.

-}
rewriteCanTypeTop : Ctx -> Can.Type Name -> ( Can.Type TypeIds.MVarId, Ctx )
rewriteCanTypeTop ctx canType =
    let
        arrowsBefore =
            Id.toComparable ctx.state.nextArrow

        stampedBefore =
            ctx.state.arrowsStamped

        ( out, ctx1 ) =
            rewriteCanType ctx canType

        st =
            ctx1.state

        arrows =
            Id.toComparable st.nextArrow - arrowsBefore

        stamped =
            st.arrowsStamped - stampedBefore
    in
    if not st.stampCensusOn || arrows == 0 then
        -- Census off, or no new ArrowId drawn: not counted.
        ( out, ctx1 )

    else if stamped == arrows then
        ( out, { ctx1 | state = { st | typesAll = st.typesAll + 1 } } )

    else if stamped == 0 then
        ( out
        , { ctx1
            | state =
                { st
                    | typesNone = st.typesNone + 1
                    , arrowsInNone = st.arrowsInNone + arrows
                }
          }
        )

    else
        ( out
        , { ctx1
            | state =
                { st
                    | typesPartial = st.typesPartial + 1
                    , arrowsUnstampedInPartial =
                        st.arrowsUnstampedInPartial + (arrows - stamped)
                }
          }
        )


{-| Returns `canType` with every variable resolved by `ensureBinder` and every
arrow given an `ArrowId`. An alias's parameter names are resolved like any
other variable.
-}
rewriteCanType : Ctx -> Can.Type Name -> ( Can.Type TypeIds.MVarId, Ctx )
rewriteCanType ctx canType =
    case canType of
        Can.TVar name ->
            let
                ( mvarId, ctx1 ) =
                    ensureBinder name ctx
            in
            ( Can.TVar mvarId, ctx1 )

        Can.TLambda slot from to ->
            -- The arrow's id is taken before its children's.
            let
                ( arrowId, ctx0 ) =
                    case slot of
                        TypeIds.SolverRoot rootIdx ->
                            if ctx.useSolverRoots then
                                ensureArrowIdForRoot rootIdx ctx

                            else
                                freshArrowId ctx

                        _ ->
                            freshArrowId ctx

                ( newFrom, ctx1 ) =
                    rewriteCanType ctx0 from

                ( newTo, ctx2 ) =
                    rewriteCanType ctx1 to
            in
            ( Can.TLambda (TypeIds.Arrow arrowId) newFrom newTo, ctx2 )

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
                                    ensureBinder extName ctx1
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
                                ( paramId, c0 ) =
                                    ensureBinder argName c

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


{-| Returns the types with ids assigned, in order.
-}
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


{-| Returns the record field types with ids assigned, in field-name order.
-}
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


{-| Returns the alias's expansion with ids assigned.
-}
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
