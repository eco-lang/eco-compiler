module Compiler.GlobalOpt.PreMono.Fresh exposing
    ( Subst
    , freshenCopy, freshenType, mintNewNode
    , assertMinted
    )

{-| Identity for typed-optimized code that a pre-monomorphization pass copies
or creates.

By the time the pre-monomorphization passes run, `AssignMVarIds` has already
given the graph its identities: an `MVarId` for every type variable, a
`SrcLambdaId` for every function value and an `ArrowId` in the slot of every
`TLambda`. A pass that rewrites the graph must keep those identities sound, and
there are two ways to break them.

A pass that copies a subtree and keeps its ids, as an inliner does, leaves two
bodies under one lambda id. Lambda-set specialization (LSS) tracks which
function values can reach a call, one member per lambda id, and then treats the
two as one member, so two different instantiations can stand in for each other.
This is a wrong program, not a crash.

A pass that creates a node, such as a wrapper lambda, and leaves its lambda id
`Nothing` or its arrow slot `NoArrow`, produces a closure with no member, which
lambda-set specialization cannot resolve.

The module therefore has two entry points, one per kind of change, and a
validator.

`freshenCopy` has copy semantics. Every `SrcLambdaId` and every `ArrowId` in the
copy is re-minted, and every type variable is either replaced by the type the
caller supplies for it in a `Subst` or re-minted, except a record extension
variable whose substitution is not a variable, which keeps its original id.
`freshenType` does the same for a single type.

`mintNewNode` has new-node semantics. A pass builds its nodes with
`Function Nothing` and `Can.tLambda` (which leaves the slot `NoArrow`), then
calls it once on the built subtree. It assigns ids only where they are missing.

`assertMinted` checks a whole graph: it fails on a lambda or arrow without an
id, and on any lambda id or arrow id that occurs twice. Only the second check
can see a copy that kept its ids.

Every id comes from `AssignMVarIds`'s own supplies (`freshMVarId`, `mintLamId`,
`mintArrowId`), so a new id never collides with one assigned earlier. Term-level
names are not renamed here; a caller that copies binders renames them itself.

@docs Subst
@docs freshenCopy, freshenType, mintNewNode
@docs assertMinted

-}

import Compiler.AST.Canonical as Can
import Compiler.AST.TypeIds as TypeIds
import Compiler.AST.TypedOptimized as TOpt
import Compiler.Data.Id as Id
import Compiler.Data.Name exposing (Name)
import Compiler.Monomorphize.AssignMVarIds as AssignMVarIds
import Compiler.Reporting.Annotation as A
import Data.Map as DMap
import Dict exposing (Dict)


{-| A substitution from a copied body's type variables to the types the caller
gives them, keyed by `Id.toComparable` of the variable's `MVarId`.

A substituted type is inserted as it is, without being walked, so its own ids
and arrow slots are kept. This is a name for a `Dict`; nothing checks that the
keys are type-variable ids.

-}
type alias Subst =
    Dict Int (Can.Type TypeIds.MVarId)


{-| The state threaded through one copy.

`renamed` maps each original type variable or alias parameter that was not
substituted to its fresh `MVarId`, so that every occurrence of one original
variable within the copy becomes the same fresh one.

-}
type alias Env =
    { subst : Subst
    , renamed : Dict Int TypeIds.MVarId
    , state : AssignMVarIds.GlobalMVarState
    }



-- ============================================================================
-- ====== COPY ======
-- ============================================================================


{-| Returns a copy of `expr` with a new `SrcLambdaId` on every function and a
new `ArrowId` in every arrow slot, together with the advanced id state.

Each type variable found in `subst` is replaced by its entry. Each other type
variable is replaced by a fresh one carrying the original's super constraint
from the state's `superVars`, the same fresh one at every occurrence within the
copy. Alias parameters are always re-minted, never substituted. A record
extension variable whose substitution is not itself a variable keeps its
original id. Term-level names, including binders, are left unchanged.

-}
freshenCopy :
    Subst
    -> AssignMVarIds.GlobalMVarState
    -> TOpt.Expr TypeIds.MVarId
    -> ( TOpt.Expr TypeIds.MVarId, AssignMVarIds.GlobalMVarState )
freshenCopy subst state expr =
    let
        ( copied, env ) =
            copyExpr { subst = subst, renamed = Dict.empty, state = state } expr
    in
    ( copied, env.state )


{-| Returns a copy of one type, freshened as `freshenCopy` freshens the types
inside an expression, together with the advanced id state.

Each call starts a new variable mapping and returns only the state. A variable
that `subst` does not cover therefore gets a different fresh id here than it
gets in a separate `freshenCopy` or `freshenType` call on the same state.

-}
freshenType :
    Subst
    -> AssignMVarIds.GlobalMVarState
    -> Can.Type TypeIds.MVarId
    -> ( Can.Type TypeIds.MVarId, AssignMVarIds.GlobalMVarState )
freshenType subst state tipe =
    let
        ( copied, env ) =
            copyType { subst = subst, renamed = Dict.empty, state = state } tipe
    in
    ( copied, env.state )


{-| Returns a copy of a type under the copy semantics of `freshenCopy`, with the
copy state advanced.
-}
copyType : Env -> Can.Type TypeIds.MVarId -> ( Can.Type TypeIds.MVarId, Env )
copyType env tipe =
    case tipe of
        Can.TVar id ->
            case Dict.get (Id.toComparable id) env.subst of
                Just concrete ->
                    ( concrete, env )

                Nothing ->
                    case Dict.get (Id.toComparable id) env.renamed of
                        Just already ->
                            ( Can.TVar already, env )

                        Nothing ->
                            let
                                ( fresh, st1 ) =
                                    AssignMVarIds.freshMVarId
                                        (Dict.get (Id.toComparable id) env.state.superVars)
                                        env.state
                            in
                            ( Can.TVar fresh
                            , { env
                                | state = st1
                                , renamed =
                                    Dict.insert (Id.toComparable id) fresh env.renamed
                              }
                            )

        Can.TLambda _ from to ->
            -- The old slot is ignored: every arrow in a copy is a new occurrence.
            let
                ( arrowId, st1 ) =
                    AssignMVarIds.mintArrowId env.state

                ( newFrom, env1 ) =
                    copyType { env | state = st1 } from

                ( newTo, env2 ) =
                    copyType env1 to
            in
            ( Can.TLambda (TypeIds.Arrow arrowId) newFrom newTo, env2 )

        Can.TType home name args ->
            let
                ( newArgs, env1 ) =
                    copyTypeList env args
            in
            ( Can.TType home name newArgs, env1 )

        Can.TRecord fields ext ->
            let
                ( newFields, env1 ) =
                    Dict.foldl
                        (\field ft ( acc, e ) ->
                            let
                                ( newFt, e1 ) =
                                    copyFieldType e ft
                            in
                            ( Dict.insert field newFt acc, e1 )
                        )
                        ( Dict.empty, env )
                        fields

                ( newExt, env2 ) =
                    case ext of
                        Nothing ->
                            ( Nothing, env1 )

                        Just extId ->
                            case copyType env1 (Can.TVar extId) of
                                ( Can.TVar renamedId, e ) ->
                                    ( Just renamedId, e )

                                ( _, e ) ->
                                    -- A substituted extension variable is a
                                    -- whole record type, which cannot be spliced
                                    -- into an extension slot; keep it open under
                                    -- the original id rather than lose the row.
                                    ( Just extId, e )
            in
            ( Can.TRecord newFields newExt, env2 )

        Can.TUnit ->
            ( Can.TUnit, env )

        Can.TTuple a b rest ->
            let
                ( newA, env1 ) =
                    copyType env a

                ( newB, env2 ) =
                    copyType env1 b

                ( newRest, env3 ) =
                    copyTypeList env2 rest
            in
            ( Can.TTuple newA newB newRest, env3 )

        Can.TAlias home name args real ->
            -- An alias parameter can share its id with a same-named variable of
            -- the enclosing definition, so it is re-minted through `renamed`
            -- (never substituted). Occurrences in the `Holey` body follow it
            -- only when the id is not in the substitution.
            let
                ( newArgs, env1 ) =
                    List.foldl
                        (\( paramId, t ) ( acc, e ) ->
                            let
                                ( newParamId, e1 ) =
                                    copyParamId e paramId

                                ( newT, e2 ) =
                                    copyType e1 t
                            in
                            ( ( newParamId, newT ) :: acc, e2 )
                        )
                        ( [], env )
                        args

                ( newReal, env2 ) =
                    copyAliasType env1 real
            in
            ( Can.TAlias home name (List.reverse newArgs) newReal, env2 )


{-| Returns the fresh id for an alias parameter, minting one and recording it in
`renamed` on its first occurrence in the copy. The substitution is not
consulted: the parameter is bound by the alias, not by the caller.
-}
copyParamId : Env -> TypeIds.MVarId -> ( TypeIds.MVarId, Env )
copyParamId env paramId =
    case Dict.get (Id.toComparable paramId) env.renamed of
        Just already ->
            ( already, env )

        Nothing ->
            let
                ( fresh, st1 ) =
                    AssignMVarIds.freshMVarId
                        (Dict.get (Id.toComparable paramId) env.state.superVars)
                        env.state
            in
            ( fresh
            , { env
                | state = st1
                , renamed = Dict.insert (Id.toComparable paramId) fresh env.renamed
              }
            )


{-| Returns a copy of a record field's type, keeping its field index.
-}
copyFieldType : Env -> Can.FieldType TypeIds.MVarId -> ( Can.FieldType TypeIds.MVarId, Env )
copyFieldType env (Can.FieldType index t) =
    let
        ( newT, env1 ) =
            copyType env t
    in
    ( Can.FieldType index newT, env1 )


{-| Returns a copy of an alias's expanded body, keeping whether it is `Holey` or
`Filled`.
-}
copyAliasType : Env -> Can.AliasType TypeIds.MVarId -> ( Can.AliasType TypeIds.MVarId, Env )
copyAliasType env real =
    case real of
        Can.Holey t ->
            let
                ( newT, env1 ) =
                    copyType env t
            in
            ( Can.Holey newT, env1 )

        Can.Filled t ->
            let
                ( newT, env1 ) =
                    copyType env t
            in
            ( Can.Filled newT, env1 )


{-| Returns copies of a list of types, in order, threading one copy state.
-}
copyTypeList : Env -> List (Can.Type TypeIds.MVarId) -> ( List (Can.Type TypeIds.MVarId), Env )
copyTypeList env types =
    let
        ( acc, env1 ) =
            List.foldl
                (\t ( out, e ) ->
                    let
                        ( newT, e1 ) =
                            copyType e t
                    in
                    ( newT :: out, e1 )
                )
                ( [], env )
                types
    in
    ( List.reverse acc, env1 )


{-| Returns a copy of a node's `Meta`. Only `tipe` is copied; `tvar` is kept as
it is.
-}
copyMeta : Env -> TOpt.Meta TypeIds.MVarId -> ( TOpt.Meta TypeIds.MVarId, Env )
copyMeta env meta =
    let
        ( newTipe, env1 ) =
            copyType env meta.tipe
    in
    ( { tipe = newTipe, tvar = meta.tvar }, env1 )


{-| Returns a copy of an expression under the copy semantics of `freshenCopy`,
with the copy state advanced.
-}
copyExpr : Env -> TOpt.Expr TypeIds.MVarId -> ( TOpt.Expr TypeIds.MVarId, Env )
copyExpr env expr =
    let
        withMeta rebuild meta =
            let
                ( m, e1 ) =
                    copyMeta env meta
            in
            ( rebuild m, e1 )
    in
    case expr of
        TOpt.Bool region b meta ->
            withMeta (TOpt.Bool region b) meta

        TOpt.Chr region c meta ->
            withMeta (TOpt.Chr region c) meta

        TOpt.Str region v meta ->
            withMeta (TOpt.Str region v) meta

        TOpt.Int region i meta ->
            withMeta (TOpt.Int region i) meta

        TOpt.Float region f meta ->
            withMeta (TOpt.Float region f) meta

        TOpt.VarLocal n meta ->
            withMeta (TOpt.VarLocal n) meta

        TOpt.TrackedVarLocal region n meta ->
            withMeta (TOpt.TrackedVarLocal region n) meta

        TOpt.VarGlobal region g meta ->
            withMeta (TOpt.VarGlobal region g) meta

        TOpt.VarEnum region g idx meta ->
            withMeta (TOpt.VarEnum region g idx) meta

        TOpt.VarBox region g meta ->
            withMeta (TOpt.VarBox region g) meta

        TOpt.VarCycle region home n meta ->
            withMeta (TOpt.VarCycle region home n) meta

        TOpt.VarDebug region n home unqualified meta ->
            withMeta (TOpt.VarDebug region n home unqualified) meta

        TOpt.VarKernel region prefix home n meta ->
            withMeta (TOpt.VarKernel region prefix home n) meta

        TOpt.List region items meta ->
            let
                ( newItems, env1 ) =
                    copyExprList env items

                ( m, env2 ) =
                    copyMeta env1 meta
            in
            ( TOpt.List region newItems m, env2 )

        TOpt.Function _ params body meta ->
            -- The original lambda id is dropped: a copied lambda is a new member.
            let
                ( lamId, st1 ) =
                    AssignMVarIds.mintLamId env.state

                ( newParams, env1 ) =
                    copyParams { env | state = st1 } params

                ( newBody, env2 ) =
                    copyExpr env1 body

                ( m, env3 ) =
                    copyMeta env2 meta
            in
            ( TOpt.Function (Just lamId) newParams newBody m, env3 )

        TOpt.TrackedFunction _ params body meta ->
            let
                ( lamId, st1 ) =
                    AssignMVarIds.mintLamId env.state

                ( newParams, env1 ) =
                    copyLocatedParams { env | state = st1 } params

                ( newBody, env2 ) =
                    copyExpr env1 body

                ( m, env3 ) =
                    copyMeta env2 meta
            in
            ( TOpt.TrackedFunction (Just lamId) newParams newBody m, env3 )

        TOpt.Call region f args meta ->
            let
                ( newF, env1 ) =
                    copyExpr env f

                ( newArgs, env2 ) =
                    copyExprList env1 args

                ( m, env3 ) =
                    copyMeta env2 meta
            in
            ( TOpt.Call region newF newArgs m, env3 )

        TOpt.TailCall n args meta ->
            let
                ( newArgs, env1 ) =
                    List.foldl
                        (\( an, e ) ( out, en ) ->
                            let
                                ( newE, en1 ) =
                                    copyExpr en e
                            in
                            ( ( an, newE ) :: out, en1 )
                        )
                        ( [], env )
                        args

                ( m, env2 ) =
                    copyMeta env1 meta
            in
            ( TOpt.TailCall n (List.reverse newArgs) m, env2 )

        TOpt.If branches final meta ->
            let
                ( newBranches, env1 ) =
                    List.foldl
                        (\( c, t ) ( out, en ) ->
                            let
                                ( newC, en1 ) =
                                    copyExpr en c

                                ( newT, en2 ) =
                                    copyExpr en1 t
                            in
                            ( ( newC, newT ) :: out, en2 )
                        )
                        ( [], env )
                        branches

                ( newFinal, env2 ) =
                    copyExpr env1 final

                ( m, env3 ) =
                    copyMeta env2 meta
            in
            ( TOpt.If (List.reverse newBranches) newFinal m, env3 )

        TOpt.Let def body meta ->
            let
                ( newDef, env1 ) =
                    copyDef env def

                ( newBody, env2 ) =
                    copyExpr env1 body

                ( m, env3 ) =
                    copyMeta env2 meta
            in
            ( TOpt.Let newDef newBody m, env3 )

        TOpt.Destruct (TOpt.Destructor n path dmeta) body meta ->
            let
                ( dm, env1 ) =
                    copyMeta env dmeta

                ( newBody, env2 ) =
                    copyExpr env1 body

                ( m, env3 ) =
                    copyMeta env2 meta
            in
            ( TOpt.Destruct (TOpt.Destructor n path dm) newBody m, env3 )

        TOpt.Case label root decider jumps meta ->
            let
                ( newDecider, env1 ) =
                    copyDecider env decider

                ( newJumps, env2 ) =
                    List.foldl
                        (\( i, e ) ( out, en ) ->
                            let
                                ( newE, en1 ) =
                                    copyExpr en e
                            in
                            ( ( i, newE ) :: out, en1 )
                        )
                        ( [], env1 )
                        jumps

                ( m, env3 ) =
                    copyMeta env2 meta
            in
            ( TOpt.Case label root newDecider (List.reverse newJumps) m, env3 )

        TOpt.Accessor region field meta ->
            withMeta (TOpt.Accessor region field) meta

        TOpt.Access inner region field meta ->
            let
                ( newInner, env1 ) =
                    copyExpr env inner

                ( m, env2 ) =
                    copyMeta env1 meta
            in
            ( TOpt.Access newInner region field m, env2 )

        TOpt.Update region record fields meta ->
            let
                ( newRecord, env1 ) =
                    copyExpr env record

                ( newFields, env2 ) =
                    copyLocatedFields env1 fields

                ( m, env3 ) =
                    copyMeta env2 meta
            in
            ( TOpt.Update region newRecord newFields m, env3 )

        TOpt.Record fields meta ->
            let
                ( newFields, env1 ) =
                    Dict.foldl
                        (\k e ( out, en ) ->
                            let
                                ( newE, en1 ) =
                                    copyExpr en e
                            in
                            ( Dict.insert k newE out, en1 )
                        )
                        ( Dict.empty, env )
                        fields

                ( m, env2 ) =
                    copyMeta env1 meta
            in
            ( TOpt.Record newFields m, env2 )

        TOpt.TrackedRecord region fields meta ->
            let
                ( newFields, env1 ) =
                    copyLocatedFields env fields

                ( m, env2 ) =
                    copyMeta env1 meta
            in
            ( TOpt.TrackedRecord region newFields m, env2 )

        TOpt.Unit meta ->
            withMeta TOpt.Unit meta

        TOpt.Tuple region a b rest meta ->
            let
                ( newA, env1 ) =
                    copyExpr env a

                ( newB, env2 ) =
                    copyExpr env1 b

                ( newRest, env3 ) =
                    copyExprList env2 rest

                ( m, env4 ) =
                    copyMeta env3 meta
            in
            ( TOpt.Tuple region newA newB newRest m, env4 )

        TOpt.Shader src inputs outputs meta ->
            withMeta (TOpt.Shader src inputs outputs) meta


{-| Returns copies of a list of expressions, in order, threading one copy state.
-}
copyExprList : Env -> List (TOpt.Expr TypeIds.MVarId) -> ( List (TOpt.Expr TypeIds.MVarId), Env )
copyExprList env exprs =
    let
        ( acc, env1 ) =
            List.foldl
                (\e ( out, en ) ->
                    let
                        ( newE, en1 ) =
                            copyExpr en e
                    in
                    ( newE :: out, en1 )
                )
                ( [], env )
                exprs
    in
    ( List.reverse acc, env1 )


{-| Returns copies of the field expressions of a record or record update.
-}
copyLocatedFields :
    Env
    -> DMap.Dict String (A.Located Name) (TOpt.Expr TypeIds.MVarId)
    -> ( DMap.Dict String (A.Located Name) (TOpt.Expr TypeIds.MVarId), Env )
copyLocatedFields env fields =
    DMap.foldl
        (\k e ( out, en ) ->
            let
                ( newE, en1 ) =
                    copyExpr en e
            in
            ( DMap.insert A.toValue k newE out, en1 )
        )
        ( DMap.empty, env )
        fields


{-| Returns a function's parameters with their types copied and their names
unchanged.
-}
copyParams :
    Env
    -> List ( Name, Can.Type TypeIds.MVarId )
    -> ( List ( Name, Can.Type TypeIds.MVarId ), Env )
copyParams env params =
    let
        ( acc, env1 ) =
            List.foldl
                (\( n, t ) ( out, en ) ->
                    let
                        ( newT, en1 ) =
                            copyType en t
                    in
                    ( ( n, newT ) :: out, en1 )
                )
                ( [], env )
                params
    in
    ( List.reverse acc, env1 )


{-| Returns located parameters with their types copied and their names
unchanged.
-}
copyLocatedParams :
    Env
    -> List ( A.Located Name, Can.Type TypeIds.MVarId )
    -> ( List ( A.Located Name, Can.Type TypeIds.MVarId ), Env )
copyLocatedParams env params =
    let
        ( acc, env1 ) =
            List.foldl
                (\( n, t ) ( out, en ) ->
                    let
                        ( newT, en1 ) =
                            copyType en t
                    in
                    ( ( n, newT ) :: out, en1 )
                )
                ( [], env )
                params
    in
    ( List.reverse acc, env1 )


{-| Returns a copy of a `let` definition: its bound expression or tail-function
arguments and body, and its type. A `TailDef`'s `tvar` is kept as it is.
-}
copyDef : Env -> TOpt.Def TypeIds.MVarId -> ( TOpt.Def TypeIds.MVarId, Env )
copyDef env def =
    case def of
        TOpt.Def region n bound tipe ->
            let
                ( newBound, env1 ) =
                    copyExpr env bound

                ( newTipe, env2 ) =
                    copyType env1 tipe
            in
            ( TOpt.Def region n newBound newTipe, env2 )

        TOpt.TailDef region n args body tipe tvar ->
            let
                ( newArgs, env1 ) =
                    copyLocatedParams env args

                ( newBody, env2 ) =
                    copyExpr env1 body

                ( newTipe, env3 ) =
                    copyType env2 tipe
            in
            ( TOpt.TailDef region n newArgs newBody newTipe tvar, env3 )


{-| Returns a copy of a decision tree, copying the expressions inlined at its
leaves. Jump leaves and tests are kept as they are.
-}
copyDecider :
    Env
    -> TOpt.Decider (TOpt.Choice TypeIds.MVarId)
    -> ( TOpt.Decider (TOpt.Choice TypeIds.MVarId), Env )
copyDecider env decider =
    case decider of
        TOpt.Leaf (TOpt.Inline e) ->
            let
                ( newE, env1 ) =
                    copyExpr env e
            in
            ( TOpt.Leaf (TOpt.Inline newE), env1 )

        TOpt.Leaf (TOpt.Jump i) ->
            ( TOpt.Leaf (TOpt.Jump i), env )

        TOpt.Chain tests ok ko ->
            let
                ( newOk, env1 ) =
                    copyDecider env ok

                ( newKo, env2 ) =
                    copyDecider env1 ko
            in
            ( TOpt.Chain tests newOk newKo, env2 )

        TOpt.FanOut path branches fallback ->
            let
                ( newBranches, env1 ) =
                    List.foldl
                        (\( t, d ) ( out, en ) ->
                            let
                                ( newD, en1 ) =
                                    copyDecider en d
                            in
                            ( ( t, newD ) :: out, en1 )
                        )
                        ( [], env )
                        branches

                ( newFallback, env2 ) =
                    copyDecider env1 fallback
            in
            ( TOpt.FanOut path (List.reverse newBranches) newFallback, env2 )



-- ============================================================================
-- ====== NEW NODES ======
-- ============================================================================


{-| Returns `expr` with ids assigned to the nodes that lack them, together with
the advanced id state.

A `Function` or `TrackedFunction` with no lambda id gets a fresh `SrcLambdaId`,
and every arrow slot that is not `Arrow`, whether `NoArrow` or `SolverRoot`,
gets a fresh `ArrowId`. Ids already present are kept, so the function is
idempotent and can be run over a subtree that mixes new nodes with existing
ones. Type variables are never minted; a pass that needs a fresh one calls
`AssignMVarIds.freshMVarId` itself.

-}
mintNewNode :
    AssignMVarIds.GlobalMVarState
    -> TOpt.Expr TypeIds.MVarId
    -> ( TOpt.Expr TypeIds.MVarId, AssignMVarIds.GlobalMVarState )
mintNewNode state expr =
    mintExpr state expr


{-| Returns a type with a fresh `ArrowId` in every arrow slot that is not
already `Arrow`, with the state advanced. Type variables, record extensions and
alias parameter ids are kept.
-}
mintType : AssignMVarIds.GlobalMVarState -> Can.Type TypeIds.MVarId -> ( Can.Type TypeIds.MVarId, AssignMVarIds.GlobalMVarState )
mintType state tipe =
    case tipe of
        Can.TVar id ->
            ( Can.TVar id, state )

        Can.TLambda slot from to ->
            let
                ( newSlot, st1 ) =
                    case slot of
                        TypeIds.Arrow _ ->
                            ( slot, state )

                        _ ->
                            let
                                ( arrowId, s ) =
                                    AssignMVarIds.mintArrowId state
                            in
                            ( TypeIds.Arrow arrowId, s )

                ( newFrom, st2 ) =
                    mintType st1 from

                ( newTo, st3 ) =
                    mintType st2 to
            in
            ( Can.TLambda newSlot newFrom newTo, st3 )

        Can.TType home name args ->
            let
                ( newArgs, st1 ) =
                    mintTypeList state args
            in
            ( Can.TType home name newArgs, st1 )

        Can.TRecord fields ext ->
            let
                ( newFields, st1 ) =
                    Dict.foldl
                        (\field (Can.FieldType index t) ( acc, s ) ->
                            let
                                ( newT, s1 ) =
                                    mintType s t
                            in
                            ( Dict.insert field (Can.FieldType index newT) acc, s1 )
                        )
                        ( Dict.empty, state )
                        fields
            in
            ( Can.TRecord newFields ext, st1 )

        Can.TUnit ->
            ( Can.TUnit, state )

        Can.TTuple a b rest ->
            let
                ( newA, st1 ) =
                    mintType state a

                ( newB, st2 ) =
                    mintType st1 b

                ( newRest, st3 ) =
                    mintTypeList st2 rest
            in
            ( Can.TTuple newA newB newRest, st3 )

        Can.TAlias home name args real ->
            let
                ( newArgs, st1 ) =
                    List.foldl
                        (\( paramId, t ) ( acc, s ) ->
                            let
                                ( newT, s1 ) =
                                    mintType s t
                            in
                            ( ( paramId, newT ) :: acc, s1 )
                        )
                        ( [], state )
                        args

                ( newReal, st2 ) =
                    case real of
                        Can.Holey t ->
                            Tuple.mapFirst Can.Holey (mintType st1 t)

                        Can.Filled t ->
                            Tuple.mapFirst Can.Filled (mintType st1 t)
            in
            ( Can.TAlias home name (List.reverse newArgs) newReal, st2 )


{-| Returns a list of types each given the treatment of `mintType`, in order.
-}
mintTypeList : AssignMVarIds.GlobalMVarState -> List (Can.Type TypeIds.MVarId) -> ( List (Can.Type TypeIds.MVarId), AssignMVarIds.GlobalMVarState )
mintTypeList state types =
    let
        ( acc, st1 ) =
            List.foldl
                (\t ( out, s ) ->
                    let
                        ( newT, s1 ) =
                            mintType s t
                    in
                    ( newT :: out, s1 )
                )
                ( [], state )
                types
    in
    ( List.reverse acc, st1 )


{-| Returns a node's `Meta` with its `tipe` given the treatment of `mintType`.
-}
mintMeta : AssignMVarIds.GlobalMVarState -> TOpt.Meta TypeIds.MVarId -> ( TOpt.Meta TypeIds.MVarId, AssignMVarIds.GlobalMVarState )
mintMeta state meta =
    let
        ( newTipe, st1 ) =
            mintType state meta.tipe
    in
    ( { tipe = newTipe, tvar = meta.tvar }, st1 )


{-| Returns an expression under the new-node semantics of `mintNewNode`, with
the state advanced.
-}
mintExpr : AssignMVarIds.GlobalMVarState -> TOpt.Expr TypeIds.MVarId -> ( TOpt.Expr TypeIds.MVarId, AssignMVarIds.GlobalMVarState )
mintExpr state expr =
    let
        simple rebuild meta =
            Tuple.mapFirst rebuild (mintMeta state meta)
    in
    case expr of
        TOpt.Bool region b meta ->
            simple (TOpt.Bool region b) meta

        TOpt.Chr region c meta ->
            simple (TOpt.Chr region c) meta

        TOpt.Str region v meta ->
            simple (TOpt.Str region v) meta

        TOpt.Int region i meta ->
            simple (TOpt.Int region i) meta

        TOpt.Float region f meta ->
            simple (TOpt.Float region f) meta

        TOpt.VarLocal n meta ->
            simple (TOpt.VarLocal n) meta

        TOpt.TrackedVarLocal region n meta ->
            simple (TOpt.TrackedVarLocal region n) meta

        TOpt.VarGlobal region g meta ->
            simple (TOpt.VarGlobal region g) meta

        TOpt.VarEnum region g idx meta ->
            simple (TOpt.VarEnum region g idx) meta

        TOpt.VarBox region g meta ->
            simple (TOpt.VarBox region g) meta

        TOpt.VarCycle region home n meta ->
            simple (TOpt.VarCycle region home n) meta

        TOpt.VarDebug region n home unqualified meta ->
            simple (TOpt.VarDebug region n home unqualified) meta

        TOpt.VarKernel region prefix home n meta ->
            simple (TOpt.VarKernel region prefix home n) meta

        TOpt.List region items meta ->
            let
                ( newItems, st1 ) =
                    mintExprList state items

                ( m, st2 ) =
                    mintMeta st1 meta
            in
            ( TOpt.List region newItems m, st2 )

        TOpt.Function maybeLam params body meta ->
            let
                ( lamId, st1 ) =
                    case maybeLam of
                        Just existing ->
                            ( Just existing, state )

                        Nothing ->
                            Tuple.mapFirst Just (AssignMVarIds.mintLamId state)

                ( newParams, st2 ) =
                    mintParams st1 params

                ( newBody, st3 ) =
                    mintExpr st2 body

                ( m, st4 ) =
                    mintMeta st3 meta
            in
            ( TOpt.Function lamId newParams newBody m, st4 )

        TOpt.TrackedFunction maybeLam params body meta ->
            let
                ( lamId, st1 ) =
                    case maybeLam of
                        Just existing ->
                            ( Just existing, state )

                        Nothing ->
                            Tuple.mapFirst Just (AssignMVarIds.mintLamId state)

                ( newParams, st2 ) =
                    mintLocatedParams st1 params

                ( newBody, st3 ) =
                    mintExpr st2 body

                ( m, st4 ) =
                    mintMeta st3 meta
            in
            ( TOpt.TrackedFunction lamId newParams newBody m, st4 )

        TOpt.Call region f args meta ->
            let
                ( newF, st1 ) =
                    mintExpr state f

                ( newArgs, st2 ) =
                    mintExprList st1 args

                ( m, st3 ) =
                    mintMeta st2 meta
            in
            ( TOpt.Call region newF newArgs m, st3 )

        TOpt.TailCall n args meta ->
            let
                ( newArgs, st1 ) =
                    List.foldl
                        (\( an, e ) ( out, s ) ->
                            let
                                ( newE, s1 ) =
                                    mintExpr s e
                            in
                            ( ( an, newE ) :: out, s1 )
                        )
                        ( [], state )
                        args

                ( m, st2 ) =
                    mintMeta st1 meta
            in
            ( TOpt.TailCall n (List.reverse newArgs) m, st2 )

        TOpt.If branches final meta ->
            let
                ( newBranches, st1 ) =
                    List.foldl
                        (\( c, t ) ( out, s ) ->
                            let
                                ( newC, s1 ) =
                                    mintExpr s c

                                ( newT, s2 ) =
                                    mintExpr s1 t
                            in
                            ( ( newC, newT ) :: out, s2 )
                        )
                        ( [], state )
                        branches

                ( newFinal, st2 ) =
                    mintExpr st1 final

                ( m, st3 ) =
                    mintMeta st2 meta
            in
            ( TOpt.If (List.reverse newBranches) newFinal m, st3 )

        TOpt.Let def body meta ->
            let
                ( newDef, st1 ) =
                    mintDef state def

                ( newBody, st2 ) =
                    mintExpr st1 body

                ( m, st3 ) =
                    mintMeta st2 meta
            in
            ( TOpt.Let newDef newBody m, st3 )

        TOpt.Destruct (TOpt.Destructor n path dmeta) body meta ->
            let
                ( dm, st1 ) =
                    mintMeta state dmeta

                ( newBody, st2 ) =
                    mintExpr st1 body

                ( m, st3 ) =
                    mintMeta st2 meta
            in
            ( TOpt.Destruct (TOpt.Destructor n path dm) newBody m, st3 )

        TOpt.Case label root decider jumps meta ->
            let
                ( newDecider, st1 ) =
                    mintDecider state decider

                ( newJumps, st2 ) =
                    List.foldl
                        (\( i, e ) ( out, s ) ->
                            let
                                ( newE, s1 ) =
                                    mintExpr s e
                            in
                            ( ( i, newE ) :: out, s1 )
                        )
                        ( [], st1 )
                        jumps

                ( m, st3 ) =
                    mintMeta st2 meta
            in
            ( TOpt.Case label root newDecider (List.reverse newJumps) m, st3 )

        TOpt.Accessor region field meta ->
            simple (TOpt.Accessor region field) meta

        TOpt.Access inner region field meta ->
            let
                ( newInner, st1 ) =
                    mintExpr state inner

                ( m, st2 ) =
                    mintMeta st1 meta
            in
            ( TOpt.Access newInner region field m, st2 )

        TOpt.Update region record fields meta ->
            let
                ( newRecord, st1 ) =
                    mintExpr state record

                ( newFields, st2 ) =
                    mintLocatedFields st1 fields

                ( m, st3 ) =
                    mintMeta st2 meta
            in
            ( TOpt.Update region newRecord newFields m, st3 )

        TOpt.Record fields meta ->
            let
                ( newFields, st1 ) =
                    Dict.foldl
                        (\k e ( out, s ) ->
                            let
                                ( newE, s1 ) =
                                    mintExpr s e
                            in
                            ( Dict.insert k newE out, s1 )
                        )
                        ( Dict.empty, state )
                        fields

                ( m, st2 ) =
                    mintMeta st1 meta
            in
            ( TOpt.Record newFields m, st2 )

        TOpt.TrackedRecord region fields meta ->
            let
                ( newFields, st1 ) =
                    mintLocatedFields state fields

                ( m, st2 ) =
                    mintMeta st1 meta
            in
            ( TOpt.TrackedRecord region newFields m, st2 )

        TOpt.Unit meta ->
            simple TOpt.Unit meta

        TOpt.Tuple region a b rest meta ->
            let
                ( newA, st1 ) =
                    mintExpr state a

                ( newB, st2 ) =
                    mintExpr st1 b

                ( newRest, st3 ) =
                    mintExprList st2 rest

                ( m, st4 ) =
                    mintMeta st3 meta
            in
            ( TOpt.Tuple region newA newB newRest m, st4 )

        TOpt.Shader src inputs outputs meta ->
            simple (TOpt.Shader src inputs outputs) meta


{-| Returns a list of expressions each given the treatment of `mintExpr`, in
order.
-}
mintExprList : AssignMVarIds.GlobalMVarState -> List (TOpt.Expr TypeIds.MVarId) -> ( List (TOpt.Expr TypeIds.MVarId), AssignMVarIds.GlobalMVarState )
mintExprList state exprs =
    let
        ( acc, st1 ) =
            List.foldl
                (\e ( out, s ) ->
                    let
                        ( newE, s1 ) =
                            mintExpr s e
                    in
                    ( newE :: out, s1 )
                )
                ( [], state )
                exprs
    in
    ( List.reverse acc, st1 )


{-| Returns the field expressions of a record or record update, each given the
treatment of `mintExpr`.
-}
mintLocatedFields :
    AssignMVarIds.GlobalMVarState
    -> DMap.Dict String (A.Located Name) (TOpt.Expr TypeIds.MVarId)
    -> ( DMap.Dict String (A.Located Name) (TOpt.Expr TypeIds.MVarId), AssignMVarIds.GlobalMVarState )
mintLocatedFields state fields =
    DMap.foldl
        (\k e ( out, s ) ->
            let
                ( newE, s1 ) =
                    mintExpr s e
            in
            ( DMap.insert A.toValue k newE out, s1 )
        )
        ( DMap.empty, state )
        fields


{-| Returns a function's parameters with their types given the treatment of
`mintType`.
-}
mintParams : AssignMVarIds.GlobalMVarState -> List ( Name, Can.Type TypeIds.MVarId ) -> ( List ( Name, Can.Type TypeIds.MVarId ), AssignMVarIds.GlobalMVarState )
mintParams state params =
    let
        ( acc, st1 ) =
            List.foldl
                (\( n, t ) ( out, s ) ->
                    let
                        ( newT, s1 ) =
                            mintType s t
                    in
                    ( ( n, newT ) :: out, s1 )
                )
                ( [], state )
                params
    in
    ( List.reverse acc, st1 )


{-| Returns located parameters with their types given the treatment of
`mintType`.
-}
mintLocatedParams : AssignMVarIds.GlobalMVarState -> List ( A.Located Name, Can.Type TypeIds.MVarId ) -> ( List ( A.Located Name, Can.Type TypeIds.MVarId ), AssignMVarIds.GlobalMVarState )
mintLocatedParams state params =
    let
        ( acc, st1 ) =
            List.foldl
                (\( n, t ) ( out, s ) ->
                    let
                        ( newT, s1 ) =
                            mintType s t
                    in
                    ( ( n, newT ) :: out, s1 )
                )
                ( [], state )
                params
    in
    ( List.reverse acc, st1 )


{-| Returns a `let` definition with its expressions and types given the
new-node treatment.
-}
mintDef : AssignMVarIds.GlobalMVarState -> TOpt.Def TypeIds.MVarId -> ( TOpt.Def TypeIds.MVarId, AssignMVarIds.GlobalMVarState )
mintDef state def =
    case def of
        TOpt.Def region n bound tipe ->
            let
                ( newBound, st1 ) =
                    mintExpr state bound

                ( newTipe, st2 ) =
                    mintType st1 tipe
            in
            ( TOpt.Def region n newBound newTipe, st2 )

        TOpt.TailDef region n args body tipe tvar ->
            let
                ( newArgs, st1 ) =
                    mintLocatedParams state args

                ( newBody, st2 ) =
                    mintExpr st1 body

                ( newTipe, st3 ) =
                    mintType st2 tipe
            in
            ( TOpt.TailDef region n newArgs newBody newTipe tvar, st3 )


{-| Returns a decision tree with the expressions inlined at its leaves given the
treatment of `mintExpr`.
-}
mintDecider : AssignMVarIds.GlobalMVarState -> TOpt.Decider (TOpt.Choice TypeIds.MVarId) -> ( TOpt.Decider (TOpt.Choice TypeIds.MVarId), AssignMVarIds.GlobalMVarState )
mintDecider state decider =
    case decider of
        TOpt.Leaf (TOpt.Inline e) ->
            Tuple.mapFirst (TOpt.Leaf << TOpt.Inline) (mintExpr state e)

        TOpt.Leaf (TOpt.Jump i) ->
            ( TOpt.Leaf (TOpt.Jump i), state )

        TOpt.Chain tests ok ko ->
            let
                ( newOk, st1 ) =
                    mintDecider state ok

                ( newKo, st2 ) =
                    mintDecider st1 ko
            in
            ( TOpt.Chain tests newOk newKo, st2 )

        TOpt.FanOut path branches fallback ->
            let
                ( newBranches, st1 ) =
                    List.foldl
                        (\( t, d ) ( out, s ) ->
                            let
                                ( newD, s1 ) =
                                    mintDecider s d
                            in
                            ( ( t, newD ) :: out, s1 )
                        )
                        ( [], state )
                        branches

                ( newFallback, st2 ) =
                    mintDecider st1 fallback
            in
            ( TOpt.FanOut path (List.reverse newBranches) newFallback, st2 )



-- ============================================================================
-- ====== VALIDATOR ======
-- ============================================================================


{-| Checks the bodies of a graph's `Define`, `TrackedDefine`, `PortIncoming` and
`PortOutgoing` nodes, returning `Err` with a message naming the global at the
first failure.

It fails on a `Function` or `TrackedFunction` with no lambda id, on an arrow
slot that is `NoArrow` or `SolverRoot`, and on any lambda id or arrow id met a
second time anywhere in the walked bodies. The repeat check is the one that
catches a copy that kept its ids. The types checked are each node's `Meta`
type, function parameter types, `let` definition types and destructor types.

Other node kinds, including `Cycle`, are not walked. Every repeated `ArrowId`
fails, including arrows that `AssignMVarIds` deliberately gave one id because
they share a solver root.

-}
assertMinted : TOpt.GlobalGraph TypeIds.MVarId -> Result String ()
assertMinted (TOpt.GlobalGraph nodes _ _ _ _) =
    let
        result =
            DMap.foldl
                (\g node acc ->
                    case acc of
                        Err _ ->
                            acc

                        Ok seen ->
                            case nodeExpr node of
                                Nothing ->
                                    acc

                                Just expr ->
                                    checkExpr (TOpt.toComparableGlobal g) expr seen
                )
                (Ok emptySeen)
                nodes
    in
    Result.map (\_ -> ()) result


{-| The lambda ids and arrow ids met so far during `assertMinted`, keyed by
`Id.toComparable`.
-}
type alias Seen =
    { lams : Dict Int ()
    , arrows : Dict Int ()
    }


{-| The `Seen` record with no ids in it.
-}
emptySeen : Seen
emptySeen =
    { lams = Dict.empty, arrows = Dict.empty }


{-| Returns the body of a node that `assertMinted` walks, or `Nothing` for every
other kind of node.
-}
nodeExpr : TOpt.Node TypeIds.MVarId -> Maybe (TOpt.Expr TypeIds.MVarId)
nodeExpr node =
    case node of
        TOpt.Define e _ _ ->
            Just e

        TOpt.TrackedDefine _ e _ _ ->
            Just e

        TOpt.PortIncoming e _ _ ->
            Just e

        TOpt.PortOutgoing e _ _ ->
            Just e

        _ ->
            Nothing


{-| Records a lambda id as seen, or returns `Err` if it was already seen. `who`
names the global in the message.
-}
seeLam : String -> TypeIds.SrcLambdaId -> Seen -> Result String Seen
seeLam who lamId seen =
    let
        key =
            Id.toComparable lamId
    in
    if Dict.member key seen.lams then
        Err (who ++ ": SrcLambdaId " ++ String.fromInt key ++ " occurs twice — a copy kept its identity (verbatim-copy impersonation). Use Fresh.freshenCopy.")

    else
        Ok { seen | lams = Dict.insert key () seen.lams }


{-| Records an arrow id as seen, or returns `Err` if it was already seen. `who`
names the global in the message.
-}
seeArrow : String -> TypeIds.ArrowId -> Seen -> Result String Seen
seeArrow who arrowId seen =
    let
        key =
            Id.toComparable arrowId
    in
    if Dict.member key seen.arrows then
        Err (who ++ ": ArrowId " ++ String.fromInt key ++ " occurs twice — a copied type kept its arrow identity. Use Fresh.freshenCopy.")

    else
        Ok { seen | arrows = Dict.insert key () seen.arrows }


{-| Checks every arrow slot in a type, recording each `ArrowId` and failing on a
repeat or on a slot that is not `Arrow`.
-}
checkType : String -> Can.Type TypeIds.MVarId -> Seen -> Result String Seen
checkType who tipe seen =
    case tipe of
        Can.TVar _ ->
            Ok seen

        Can.TLambda slot from to ->
            (case slot of
                TypeIds.Arrow arrowId ->
                    seeArrow who arrowId seen

                TypeIds.NoArrow ->
                    Err (who ++ ": TLambda NoArrow after assignment — a created node was not minted. Use Fresh.mintNewNode.")

                TypeIds.SolverRoot _ ->
                    Err (who ++ ": TLambda SolverRoot after assignment — a created node was not minted. Use Fresh.mintNewNode.")
            )
                |> Result.andThen (checkType who from)
                |> Result.andThen (checkType who to)

        Can.TType _ _ args ->
            List.foldl (\t acc -> Result.andThen (checkType who t) acc) (Ok seen) args

        Can.TRecord fields _ ->
            Dict.foldl
                (\_ (Can.FieldType _ t) acc -> Result.andThen (checkType who t) acc)
                (Ok seen)
                fields

        Can.TUnit ->
            Ok seen

        Can.TTuple a b rest ->
            checkType who a seen
                |> Result.andThen (checkType who b)
                |> (\acc -> List.foldl (\t r -> Result.andThen (checkType who t) r) acc rest)

        Can.TAlias _ _ args real ->
            List.foldl (\( _, t ) acc -> Result.andThen (checkType who t) acc)
                (Ok seen)
                args
                |> Result.andThen
                    (checkType who
                        (case real of
                            Can.Holey t ->
                                t

                            Can.Filled t ->
                                t
                        )
                    )


{-| Checks one expression and, recursively, its sub-expressions: the lambda id of
a function, the types it carries, and the arrow slots in them.
-}
checkExpr : String -> TOpt.Expr TypeIds.MVarId -> Seen -> Result String Seen
checkExpr who expr seen =
    let
        metaOf e =
            TOpt.metaOf e

        checkChildren s =
            List.foldl (\c acc -> Result.andThen (checkExpr who c) acc) (Ok s) (exprChildren expr)
    in
    (case expr of
        TOpt.Function maybeLam params _ _ ->
            case maybeLam of
                Nothing ->
                    Err (who ++ ": Function with no SrcLambdaId after assignment — a created node was not minted. Use Fresh.mintNewNode.")

                Just lamId ->
                    seeLam who lamId seen
                        |> (\acc -> List.foldl (\( _, t ) r -> Result.andThen (checkType who t) r) acc params)

        TOpt.TrackedFunction maybeLam params _ _ ->
            case maybeLam of
                Nothing ->
                    Err (who ++ ": TrackedFunction with no SrcLambdaId after assignment — a created node was not minted. Use Fresh.mintNewNode.")

                Just lamId ->
                    seeLam who lamId seen
                        |> (\acc -> List.foldl (\( _, t ) r -> Result.andThen (checkType who t) r) acc params)

        TOpt.Let def _ _ ->
            case def of
                TOpt.Def _ _ _ t ->
                    checkType who t seen

                TOpt.TailDef _ _ args _ t _ ->
                    List.foldl (\( _, at ) r -> Result.andThen (checkType who at) r) (Ok seen) args
                        |> Result.andThen (checkType who t)

        TOpt.Destruct (TOpt.Destructor _ _ dmeta) _ _ ->
            checkType who dmeta.tipe seen

        _ ->
            Ok seen
    )
        |> Result.andThen (checkType who (metaOf expr).tipe)
        |> Result.andThen checkChildren


{-| Returns the immediate sub-expressions of an expression, including the
expressions inlined at a decision tree's leaves, where a `case` branch used by
only one path is stored.
-}
exprChildren : TOpt.Expr TypeIds.MVarId -> List (TOpt.Expr TypeIds.MVarId)
exprChildren expr =
    case expr of
        TOpt.List _ items _ ->
            items

        TOpt.Function _ _ body _ ->
            [ body ]

        TOpt.TrackedFunction _ _ body _ ->
            [ body ]

        TOpt.Call _ f args _ ->
            f :: args

        TOpt.TailCall _ args _ ->
            List.map Tuple.second args

        TOpt.If branches final _ ->
            List.concatMap (\( c, t ) -> [ c, t ]) branches ++ [ final ]

        TOpt.Let def body _ ->
            (case def of
                TOpt.Def _ _ bound _ ->
                    [ bound ]

                TOpt.TailDef _ _ _ b _ _ ->
                    [ b ]
            )
                ++ [ body ]

        TOpt.Destruct _ body _ ->
            [ body ]

        TOpt.Case _ _ decider jumps _ ->
            deciderChildren decider ++ List.map Tuple.second jumps

        TOpt.Access inner _ _ _ ->
            [ inner ]

        TOpt.Update _ record fields _ ->
            record :: DMap.values fields

        TOpt.Record fields _ ->
            Dict.values fields

        TOpt.TrackedRecord _ fields _ ->
            DMap.values fields

        TOpt.Tuple _ a b rest _ ->
            a :: b :: rest

        _ ->
            []


{-| Returns the expressions inlined at the leaves of a decision tree.
-}
deciderChildren : TOpt.Decider (TOpt.Choice TypeIds.MVarId) -> List (TOpt.Expr TypeIds.MVarId)
deciderChildren decider =
    case decider of
        TOpt.Leaf (TOpt.Inline e) ->
            [ e ]

        TOpt.Leaf (TOpt.Jump _) ->
            []

        TOpt.Chain _ ok ko ->
            deciderChildren ok ++ deciderChildren ko

        TOpt.FanOut _ branches fallback ->
            List.concatMap (\( _, d ) -> deciderChildren d) branches
                ++ deciderChildren fallback
