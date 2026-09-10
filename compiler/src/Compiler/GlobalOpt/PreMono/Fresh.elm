module Compiler.GlobalOpt.PreMono.Fresh exposing
    ( Subst
    , freshenCopy, freshenType, mintNewNode
    , assertMinted
    )

{-| The ONE place a pre-monomorphization pass mints identity.

`plans/pre-mono-lss-transforms-00-assign-mvar-ids-first.md` §3.3.

`AssignMVarIds` now runs BEFORE the pre-mono passes, so every `MVarId`,
`SrcLambdaId` and `ArrowId` already exists on the graph those passes rewrite.
That turns the pre-mono position's central guarantee — "nothing can be
destroyed here, because no identity exists yet" — into a DISCIPLINE:

  - a transform that COPIES a subtree and keeps its ids puts two bodies under
    one member, which is LSS\_009 impersonation across different
    instantiations: a silent miscompile, not a crash;
  - a transform that CREATES a node and leaves `Function Nothing` /
    `TLambda NoArrow` produces a memberless closure, which declines as
    `g1absentl`.

So there are exactly two entry points and every pass must use one of them:

  - `freshenCopy` — COPY semantics. Every `SrcLambdaId` and every `ArrowId` in
    the copy is re-minted; every `MVarId` is either substituted from the call
    site or re-minted with its supertype constraint carried across.
  - `mintNewNode` — NEW-NODE semantics. A transform builds nodes with
    `Function Nothing` and `Can.tLambda` (which is `TLambda NoArrow`) and calls
    this once on the built subtree; ids are assigned ONLY where absent, so it
    is idempotent and safe to run over a mixture of new and existing nodes.

`assertMinted` is the validator (`mono.validate`): it fails on an unminted node
AND on a REPEATED lambda or arrow id. The second check is the one that matters
— a presence check cannot see copy-without-mint, which is the miscompile shape.

All three mint from `AssignMVarIds`'s own supplies, so `Engine.initState`'s
`nextMemberId = Id.toComparable state.nextLam` stays past every id ever minted
(LSS\_003).

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


{-| What the call site says each of the copied body's type variables is, keyed
by `Id.toComparable`. A hit is spliced in VERBATIM: it is the CALLER's type, so
its ids and arrow identities are already consistent with the caller and must
not be walked or re-minted.
-}
type alias Subst =
    Dict Int (Can.Type TypeIds.MVarId)


{-| Copy-walk state: the substitution, the per-copy mapping for variables that
were NOT substituted (so every occurrence of one original variable becomes the
same fresh one), and the allocator.
-}
type alias Env =
    { subst : Subst
    , renamed : Dict Int TypeIds.MVarId
    , state : AssignMVarIds.GlobalMVarState
    }



-- ============================================================================
-- ====== COPY ======
-- ============================================================================


{-| Freshen a copied expression: new lambda ids, new arrow ids, and either the
call site's type or a fresh variable for every type variable.

This replaces the whole `_pi` type-name suffix machinery (`suffixType`,
`suffixMeta`, `withRenamedSupers`, the `SolverRoot -> NoArrow` clearing) that
the pre-mono inliner used while it ran on `GlobalGraph Name`. TERM-level names
are NOT touched here — the caller renames its own binders.

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


{-| `freshenCopy` for a bare type — the copied definition's parameter types go
through this so they share the copy's variable mapping.

Returns the env so a caller freshening several types plus a body keeps ONE
mapping across all of them; use `freshenCopy` when a single expression is all
that is needed.

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


copyType : Env -> Can.Type TypeIds.MVarId -> ( Can.Type TypeIds.MVarId, Env )
copyType env tipe =
    case tipe of
        Can.TVar id ->
            case Dict.get (Id.toComparable id) env.subst of
                Just concrete ->
                    -- The call site's type, spliced verbatim: its ids are the
                    -- CALLER's and are already consistent there.
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
            -- Every arrow in a copy is a NEW occurrence. A root-backed original
            -- keeps its `arrowRootOf` entry; the fresh id gets none and degrades
            -- to occurrence identity, which is what the old `NoArrow` clearing
            -- achieved and what `AssignMVarIds`'s own fallback arm does.
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
            -- ALIAS PARAMETERS ARE ALIAS-LOCAL, BY POSITION. After assignment
            -- a parameter id was minted by NAME in the definition's env, so it
            -- can share an id with a same-named scheme binder: an "is this a
            -- binder?" test on ids is wrong here. The parameter is re-minted
            -- through `renamed` so the `Holey` body's occurrences of it follow.
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


{-| Re-mint an alias parameter id through the copy mapping. Unlike an ordinary
variable it is never substituted — it is bound by the alias, not by the call.
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


copyFieldType : Env -> Can.FieldType TypeIds.MVarId -> ( Can.FieldType TypeIds.MVarId, Env )
copyFieldType env (Can.FieldType index t) =
    let
        ( newT, env1 ) =
            copyType env t
    in
    ( Can.FieldType index newT, env1 )


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


copyMeta : Env -> TOpt.Meta TypeIds.MVarId -> ( TOpt.Meta TypeIds.MVarId, Env )
copyMeta env meta =
    let
        ( newTipe, env1 ) =
            copyType env meta.tipe
    in
    -- `tvar` is carried verbatim, as `AssignMVarIds.rewriteMeta` does;
    -- monomorphization never reads it.
    ( { tipe = newTipe, tvar = meta.tvar }, env1 )


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
            -- A COPIED lambda is a NEW member. Sharing the original's id is the
            -- LSS_009 impersonation this module exists to prevent.
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


copyLocatedFields :
    Env
    -> DMap.Dict String (A.Located Name) (TOpt.Expr TypeIds.MVarId)
    -> ( DMap.Dict String (A.Located Name) (TOpt.Expr TypeIds.MVarId), Env )
copyLocatedFields env fields =
    DMap.foldl A.compareLocated
        (\k e ( out, en ) ->
            let
                ( newE, en1 ) =
                    copyExpr en e
            in
            ( DMap.insert A.toValue k newE out, en1 )
        )
        ( DMap.empty, env )
        fields


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


{-| Assign identity to nodes a transform CREATED, and only to those.

`Function Nothing` gets a fresh `SrcLambdaId`; `TLambda NoArrow` gets a fresh
`ArrowId`. Anything already carrying identity is left exactly as it is, so this
is idempotent and safe over a subtree that mixes new nodes with existing ones —
which is the normal case, since a transform builds a wrapper around code it did
not create.

Type VARIABLES are never minted here: a new node is built from types that are
already assigned. A transform that genuinely needs a fresh variable calls
`AssignMVarIds.freshMVarId` itself.

`TLambda (SolverRoot _)` cannot occur after assignment (every slot is `Arrow`);
it is treated as unminted rather than trusted, so a stray one is repaired
instead of reaching `assertMinted`.

-}
mintNewNode :
    AssignMVarIds.GlobalMVarState
    -> TOpt.Expr TypeIds.MVarId
    -> ( TOpt.Expr TypeIds.MVarId, AssignMVarIds.GlobalMVarState )
mintNewNode state expr =
    mintExpr state expr


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


mintMeta : AssignMVarIds.GlobalMVarState -> TOpt.Meta TypeIds.MVarId -> ( TOpt.Meta TypeIds.MVarId, AssignMVarIds.GlobalMVarState )
mintMeta state meta =
    let
        ( newTipe, st1 ) =
            mintType state meta.tipe
    in
    ( { tipe = newTipe, tvar = meta.tvar }, st1 )


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


mintLocatedFields :
    AssignMVarIds.GlobalMVarState
    -> DMap.Dict String (A.Located Name) (TOpt.Expr TypeIds.MVarId)
    -> ( DMap.Dict String (A.Located Name) (TOpt.Expr TypeIds.MVarId), AssignMVarIds.GlobalMVarState )
mintLocatedFields state fields =
    DMap.foldl A.compareLocated
        (\k e ( out, s ) ->
            let
                ( newE, s1 ) =
                    mintExpr s e
            in
            ( DMap.insert A.toValue k newE out, s1 )
        )
        ( DMap.empty, state )
        fields


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


{-| Every lambda and arrow in the graph is minted, and no id occurs twice.

The DUPLICATE check is the one that earns its keep. A missing id is a
`Function Nothing`, which declines visibly as `g1absentl`; a REPEATED id is two
bodies under one member, which AbiCloning will treat as interchangeable
instances — a silent wrong answer. A presence check cannot see it, so this
collects every id and fails on a repeat.

Run under `mono.validate` (`ECO_MONO_VALIDATE=1`), which is the flag that
already gates the post-mono layout validator.

-}
assertMinted : TOpt.GlobalGraph TypeIds.MVarId -> Result String ()
assertMinted (TOpt.GlobalGraph nodes _ _ _ _) =
    let
        result =
            DMap.foldl TOpt.compareGlobal
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


type alias Seen =
    { lams : Dict Int ()
    , arrows : Dict Int ()
    }


emptySeen : Seen
emptySeen =
    { lams = Dict.empty, arrows = Dict.empty }


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


seeLam : String -> TypeIds.SrcLambdaId -> Seen -> Result String Seen
seeLam who lamId seen =
    let
        key =
            Id.toComparable lamId
    in
    if Dict.member key seen.lams then
        Err (who ++ ": SrcLambdaId " ++ String.fromInt key ++ " occurs twice — a copy kept its identity (LSS_009 impersonation). Use Fresh.freshenCopy.")

    else
        Ok { seen | lams = Dict.insert key () seen.lams }


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


{-| Immediate sub-expressions, including the decider's `Inline` choices — an
unshared `case` branch body lives there and would otherwise go unchecked.
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
            record :: DMap.values A.compareLocated fields

        TOpt.Record fields _ ->
            Dict.values fields

        TOpt.TrackedRecord _ fields _ ->
            DMap.values A.compareLocated fields

        TOpt.Tuple _ a b rest _ ->
            a :: b :: rest

        _ ->
            []


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
