module Compiler.IR.Mono.Traverse exposing
    ( traverseExpr, mapExpr, renameLocal
    , foldExpr, foldExprAccFirst
    , mapNodeTypes, mapNodeTypesMaybe, anyNodeType
    , childrenOf
    , collectSpecEdges, specEdgesOfNode
    )

{-| Walks over the expressions inside an expression, and over the types inside
a node. A pass that only needs to reach the sub-expressions or the types of a
node can use these walks instead of listing the `MonoExpr` constructors itself.

There are two kinds of walk, and they see different things. An expression walk
visits sub-expressions: the callee and arguments of a call, a closure's captured
values and its body, a let's definition and body, the conditions and branches
of an `if`, and so on. It never looks at a type, a region, a destructuring path
or a decision-tree path. A type walk visits every `MonoType` stored anywhere in
a node, including those.

The expression walks run bottom-up: a node's children are visited before the
node itself. Children are visited in a fixed order: a call's callee before its
arguments; a closure's captures before its body; a let's definition before its
body; each `if` condition before its branch, and the final `else` last; a
record update's record before its fields. A `MonoCase` is visited through its
decision tree first, then its list of jump targets. Only `Inline` leaves of the
tree hold an expression; a `Jump` leaf holds only the number of a branch in the
jump list, so it is visited there and not at the leaf. `traverseExpr`, `mapExpr`,
`foldExpr`, `foldExprAccFirst` and `childrenOf` all follow this order.

The type walks, `mapNodeTypes` and `anyNodeType`, reach the same positions as
each other: a node's own type and parameter types, every expression's type,
destructuring and decision-tree paths, constructor field types, closure
parameters, a closure's `captureAbi`, and a call's `captureAbi` and
`evaluatorReturnType`. A caller that asks `anyNodeType` whether a node
needs rewriting and then rewrites it with `mapNodeTypes` relies on that
agreement.

`collectSpecEdges` gives, for each specialization, the specializations its
body names through a `MonoVarGlobal`. A **spec-reference edge** is any
`MonoVarGlobal` in the body, wherever it occurs: as the head of a call, inside
a partial application, or as a value stored in data.


# Context-Threaded Traversal

@docs traverseExpr, mapExpr, renameLocal


# Fold

@docs foldExpr, foldExprAccFirst


# Type mapping / query

@docs mapNodeTypes, mapNodeTypesMaybe, anyNodeType


# Children

@docs childrenOf


# Spec reference edges

@docs collectSpecEdges, specEdgesOfNode

-}

import Array exposing (Array)
import Compiler.IR.Mono as Mono exposing (CallInfo, CaptureABI, ClosureInfo, CtorShape, Decider(..), MonoChoice(..), MonoDef(..), MonoDestructor, MonoDtPath, MonoExpr(..), MonoNode, MonoPath, MonoType)
import Data.NonEmptyList as NE



-- ============================================================================
-- ====== CONTEXT-THREADED TRAVERSAL (BOTTOM-UP) ======
-- ============================================================================


{-| Rewrites `expr` bottom-up with `f`, threading a context through the walk, and
returns the rewritten expression with the final context.

`f` is called exactly once on every expression node, after its children, in
the order the module docstring gives, and each call receives the context the
previous call returned. It answers `Nothing` to leave the node as it is, or
`Just` a replacement. The node it is given already holds its rewritten children.

A subtree in which `f` answered `Nothing` everywhere is returned as the same
value that was passed in, not a copy. A `Just` answer, even one holding the
same node, rebuilds every node above it.

Calling `f` once per node matters: applying it once per path through nested
lets and cases would multiply the work at every level of nesting.

-}
traverseExpr : (ctx -> MonoExpr -> ( Maybe MonoExpr, ctx )) -> ctx -> MonoExpr -> ( MonoExpr, ctx )
traverseExpr f ctx expr =
    let
        ( m, ctx1 ) =
            travExpr f ctx expr
    in
    case m of
        Nothing ->
            ( expr, ctx1 )

        Just e ->
            ( e, ctx1 )


{-| Rewrites `expr` bottom-up with `f`, as `traverseExpr` does but with no
context: `Nothing` leaves a node as it is, and an unchanged subtree is returned
as the same value.
-}
mapExpr : (MonoExpr -> Maybe MonoExpr) -> MonoExpr -> MonoExpr
mapExpr f expr =
    let
        ( m, _ ) =
            travExpr (\() e -> ( f e, () )) () expr
    in
    case m of
        Nothing ->
            expr

        Just e ->
            e


{-| Returns the rewrite of `expr`, or `Nothing` when neither `f` nor any rewrite
of its children changed it. The children are rewritten first and `f` is then
called once on the node, rebuilt if a child changed.
-}
travExpr : (ctx -> MonoExpr -> ( Maybe MonoExpr, ctx )) -> ctx -> MonoExpr -> ( Maybe MonoExpr, ctx )
travExpr f ctx expr =
    let
        ( mChildren, ctx1 ) =
            travChildren f ctx expr
    in
    case mChildren of
        Nothing ->
            f ctx1 expr

        Just rebuilt ->
            let
                ( mSelf, ctx2 ) =
                    f ctx1 rebuilt
            in
            case mSelf of
                Nothing ->
                    ( Just rebuilt, ctx2 )

                Just _ ->
                    ( mSelf, ctx2 )


{-| Returns `expr` rebuilt around the rewrites of its direct children, or
`Nothing` when no child changed. It does not call `f` on `expr` itself.
-}
travChildren : (ctx -> MonoExpr -> ( Maybe MonoExpr, ctx )) -> ctx -> MonoExpr -> ( Maybe MonoExpr, ctx )
travChildren f ctx expr =
    case expr of
        MonoClosure info body closureType ->
            let
                ( mCaps, ctx1 ) =
                    travCaptures f ctx info.captures

                ( mBody, ctx2 ) =
                    travExpr f ctx1 body
            in
            case mCaps of
                Nothing ->
                    case mBody of
                        Nothing ->
                            ( Nothing, ctx2 )

                        Just b ->
                            ( Just (MonoClosure info b closureType), ctx2 )

                Just caps ->
                    ( Just (MonoClosure { info | captures = caps } (withDefaultExpr body mBody) closureType), ctx2 )

        MonoCall region func args resultType callInfo ->
            let
                ( mFunc, ctx1 ) =
                    travExpr f ctx func

                ( mArgs, ctx2 ) =
                    travExprs f ctx1 args
            in
            case mFunc of
                Nothing ->
                    case mArgs of
                        Nothing ->
                            ( Nothing, ctx2 )

                        Just a ->
                            ( Just (MonoCall region func a resultType callInfo), ctx2 )

                Just fn ->
                    ( Just (MonoCall region fn (withDefaultExprs args mArgs) resultType callInfo), ctx2 )

        MonoTailCall name args resultType ->
            let
                ( mArgs, ctx1 ) =
                    travKeyed f ctx args
            in
            case mArgs of
                Nothing ->
                    ( Nothing, ctx1 )

                Just a ->
                    ( Just (MonoTailCall name a resultType), ctx1 )

        MonoIf branches final resultType ->
            let
                ( mBranches, ctx1 ) =
                    travBranches f ctx branches

                ( mFinal, ctx2 ) =
                    travExpr f ctx1 final
            in
            case mBranches of
                Nothing ->
                    case mFinal of
                        Nothing ->
                            ( Nothing, ctx2 )

                        Just fi ->
                            ( Just (MonoIf branches fi resultType), ctx2 )

                Just br ->
                    ( Just (MonoIf br (withDefaultExpr final mFinal) resultType), ctx2 )

        MonoLet def body resultType ->
            let
                ( mDef, ctx1 ) =
                    travDef f ctx def

                ( mBody, ctx2 ) =
                    travExpr f ctx1 body
            in
            case mDef of
                Nothing ->
                    case mBody of
                        Nothing ->
                            ( Nothing, ctx2 )

                        Just b ->
                            ( Just (MonoLet def b resultType), ctx2 )

                Just d ->
                    ( Just (MonoLet d (withDefaultExpr body mBody) resultType), ctx2 )

        MonoDestruct path inner resultType ->
            let
                ( mInner, ctx1 ) =
                    travExpr f ctx inner
            in
            case mInner of
                Nothing ->
                    ( Nothing, ctx1 )

                Just i ->
                    ( Just (MonoDestruct path i resultType), ctx1 )

        MonoCase label scrutinee decider jumps resultType ->
            let
                ( mDecider, ctx1 ) =
                    travDecider f ctx decider

                ( mJumps, ctx2 ) =
                    travKeyed f ctx1 jumps
            in
            case mDecider of
                Nothing ->
                    case mJumps of
                        Nothing ->
                            ( Nothing, ctx2 )

                        Just j ->
                            ( Just (MonoCase label scrutinee decider j resultType), ctx2 )

                Just d ->
                    ( Just (MonoCase label scrutinee d (withDefaultKeyed jumps mJumps) resultType), ctx2 )

        MonoList region items resultType ->
            let
                ( mItems, ctx1 ) =
                    travExprs f ctx items
            in
            case mItems of
                Nothing ->
                    ( Nothing, ctx1 )

                Just i ->
                    ( Just (MonoList region i resultType), ctx1 )

        MonoRecordCreate fields resultType ->
            let
                ( mFields, ctx1 ) =
                    travKeyed f ctx fields
            in
            case mFields of
                Nothing ->
                    ( Nothing, ctx1 )

                Just fl ->
                    ( Just (MonoRecordCreate fl resultType), ctx1 )

        MonoRecordAccess inner field resultType ->
            let
                ( mInner, ctx1 ) =
                    travExpr f ctx inner
            in
            case mInner of
                Nothing ->
                    ( Nothing, ctx1 )

                Just i ->
                    ( Just (MonoRecordAccess i field resultType), ctx1 )

        MonoRecordUpdate record updates resultType ->
            let
                ( mRecord, ctx1 ) =
                    travExpr f ctx record

                ( mUpdates, ctx2 ) =
                    travKeyed f ctx1 updates
            in
            case mRecord of
                Nothing ->
                    case mUpdates of
                        Nothing ->
                            ( Nothing, ctx2 )

                        Just u ->
                            ( Just (MonoRecordUpdate record u resultType), ctx2 )

                Just r ->
                    ( Just (MonoRecordUpdate r (withDefaultKeyed updates mUpdates) resultType), ctx2 )

        MonoTupleCreate region elements resultType ->
            let
                ( results, ctx1 ) =
                    Mono.tupleMapAccum
                        (\e c ->
                            let
                                ( me, c1 ) =
                                    travExpr f c e
                            in
                            ( ( e, me ), c1 )
                        )
                        ctx
                        elements

                changed ( _, me ) =
                    case me of
                        Just _ ->
                            True

                        Nothing ->
                            False
            in
            if List.any changed (Mono.tupleToList results) then
                ( Just (MonoTupleCreate region (Mono.tupleMap (\( e, me ) -> Maybe.withDefault e me) results) resultType), ctx1 )

            else
                ( Nothing, ctx1 )

        MonoLiteral _ _ ->
            ( Nothing, ctx )

        MonoVarLocal _ _ ->
            ( Nothing, ctx )

        MonoVarGlobal _ _ _ ->
            ( Nothing, ctx )

        MonoVarKernel _ _ _ _ _ ->
            ( Nothing, ctx )

        MonoUnit ->
            ( Nothing, ctx )

        MonoAccessorValue _ _ _ ->
            ( Nothing, ctx )


{-| Returns a let definition with its bound expression rewritten, or `Nothing`
when that expression did not change.
-}
travDef : (ctx -> MonoExpr -> ( Maybe MonoExpr, ctx )) -> ctx -> MonoDef -> ( Maybe MonoDef, ctx )
travDef f ctx def =
    case def of
        MonoDef name bound ->
            let
                ( m, ctx1 ) =
                    travExpr f ctx bound
            in
            case m of
                Nothing ->
                    ( Nothing, ctx1 )

                Just b ->
                    ( Just (MonoDef name b), ctx1 )

        MonoTailDef name params bound ->
            let
                ( m, ctx1 ) =
                    travExpr f ctx bound
            in
            case m of
                Nothing ->
                    ( Nothing, ctx1 )

                Just b ->
                    ( Just (MonoTailDef name params b), ctx1 )


{-| Returns a decision tree with the expressions of its `Inline` leaves rewritten,
or `Nothing` when none changed. A `Chain` is walked success branch first, a
`FanOut` its edges in order and then its fallback.
-}
travDecider : (ctx -> MonoExpr -> ( Maybe MonoExpr, ctx )) -> ctx -> Decider MonoChoice -> ( Maybe (Decider MonoChoice), ctx )
travDecider f ctx decider =
    case decider of
        Leaf choice ->
            let
                ( m, ctx1 ) =
                    travChoice f ctx choice
            in
            case m of
                Nothing ->
                    ( Nothing, ctx1 )

                Just c ->
                    ( Just (Leaf c), ctx1 )

        Chain test success failure ->
            let
                ( mSuccess, ctx1 ) =
                    travDecider f ctx success

                ( mFailure, ctx2 ) =
                    travDecider f ctx1 failure
            in
            case mSuccess of
                Nothing ->
                    case mFailure of
                        Nothing ->
                            ( Nothing, ctx2 )

                        Just fl ->
                            ( Just (Chain test success fl), ctx2 )

                Just sc ->
                    ( Just (Chain test sc (withDefaultDecider failure mFailure)), ctx2 )

        FanOut path edges fallback ->
            let
                ( mEdges, ctx1 ) =
                    travNonemptyEdges f ctx edges

                ( mFallback, ctx2 ) =
                    travDecider f ctx1 fallback
            in
            case mEdges of
                Nothing ->
                    case mFallback of
                        Nothing ->
                            ( Nothing, ctx2 )

                        Just fl ->
                            ( Just (FanOut path edges fl), ctx2 )

                Just es ->
                    ( Just (FanOut path es (withDefaultDecider fallback mFallback)), ctx2 )


{-| Returns an `Inline` leaf with its expression rewritten, or `Nothing` when it
did not change. A `Jump` leaf has no expression and is never changed.
-}
travChoice : (ctx -> MonoExpr -> ( Maybe MonoExpr, ctx )) -> ctx -> MonoChoice -> ( Maybe MonoChoice, ctx )
travChoice f ctx choice =
    case choice of
        Inline e ->
            let
                ( m, ctx1 ) =
                    travExpr f ctx e
            in
            case m of
                Nothing ->
                    ( Nothing, ctx1 )

                Just e1 ->
                    ( Just (Inline e1), ctx1 )

        Jump _ ->
            ( Nothing, ctx )


{-| Returns `items` with each element rewritten, left to right, or `Nothing` when
none changed. An unchanged tail is kept as it is rather than rebuilt.
-}
travExprs : (ctx -> MonoExpr -> ( Maybe MonoExpr, ctx )) -> ctx -> List MonoExpr -> ( Maybe (List MonoExpr), ctx )
travExprs f ctx items =
    case items of
        [] ->
            ( Nothing, ctx )

        x :: xs ->
            let
                ( mx, ctx1 ) =
                    travExpr f ctx x

                ( mxs, ctx2 ) =
                    travExprs f ctx1 xs
            in
            case mx of
                Nothing ->
                    case mxs of
                        Nothing ->
                            ( Nothing, ctx2 )

                        Just xs1 ->
                            ( Just (x :: xs1), ctx2 )

                Just x1 ->
                    ( Just (x1 :: withDefaultExprs xs mxs), ctx2 )


{-| Returns `items` with the expression of each pair rewritten, left to right, or
`Nothing` when none changed. The keys are kept as they are.
-}
travKeyed : (ctx -> MonoExpr -> ( Maybe MonoExpr, ctx )) -> ctx -> List ( k, MonoExpr ) -> ( Maybe (List ( k, MonoExpr )), ctx )
travKeyed f ctx items =
    case items of
        [] ->
            ( Nothing, ctx )

        (( k, x ) as pair) :: xs ->
            let
                ( mx, ctx1 ) =
                    travExpr f ctx x

                ( mxs, ctx2 ) =
                    travKeyed f ctx1 xs
            in
            case mx of
                Nothing ->
                    case mxs of
                        Nothing ->
                            ( Nothing, ctx2 )

                        Just xs1 ->
                            ( Just (pair :: xs1), ctx2 )

                Just x1 ->
                    ( Just (( k, x1 ) :: withDefaultKeyed xs mxs), ctx2 )


{-| Returns a closure's captures with each captured value rewritten, left to
right, or `Nothing` when none changed. The name and flag of each capture are
kept as they are.
-}
travCaptures : (ctx -> MonoExpr -> ( Maybe MonoExpr, ctx )) -> ctx -> List ( n, MonoExpr, a ) -> ( Maybe (List ( n, MonoExpr, a )), ctx )
travCaptures f ctx items =
    case items of
        [] ->
            ( Nothing, ctx )

        (( n, x, t ) as triple) :: xs ->
            let
                ( mx, ctx1 ) =
                    travExpr f ctx x

                ( mxs, ctx2 ) =
                    travCaptures f ctx1 xs
            in
            case mx of
                Nothing ->
                    case mxs of
                        Nothing ->
                            ( Nothing, ctx2 )

                        Just xs1 ->
                            ( Just (triple :: xs1), ctx2 )

                Just x1 ->
                    ( Just (( n, x1, t ) :: withDefaultCaptures xs mxs), ctx2 )


{-| Returns the condition and branch pairs of an `if` with each rewritten,
condition before branch and pair by pair, or `Nothing` when none changed.
-}
travBranches : (ctx -> MonoExpr -> ( Maybe MonoExpr, ctx )) -> ctx -> List ( MonoExpr, MonoExpr ) -> ( Maybe (List ( MonoExpr, MonoExpr )), ctx )
travBranches f ctx items =
    case items of
        [] ->
            ( Nothing, ctx )

        (( cond, then_ ) as pair) :: xs ->
            let
                ( mCond, ctx1 ) =
                    travExpr f ctx cond

                ( mThen, ctx2 ) =
                    travExpr f ctx1 then_

                ( mxs, ctx3 ) =
                    travBranches f ctx2 xs
            in
            case mCond of
                Nothing ->
                    case mThen of
                        Nothing ->
                            case mxs of
                                Nothing ->
                                    ( Nothing, ctx3 )

                                Just xs1 ->
                                    ( Just (pair :: xs1), ctx3 )

                        Just t1 ->
                            ( Just (( cond, t1 ) :: withDefaultBranches xs mxs), ctx3 )

                Just c1 ->
                    ( Just (( c1, withDefaultExpr then_ mThen ) :: withDefaultBranches xs mxs), ctx3 )


{-| Returns the edges of a `FanOut` with each edge's subtree rewritten, left to
right, or `Nothing` when none changed. The tests are kept as they are.
-}
travNonemptyEdges : (ctx -> MonoExpr -> ( Maybe MonoExpr, ctx )) -> ctx -> NE.Nonempty ( a, Decider MonoChoice ) -> ( Maybe (NE.Nonempty ( a, Decider MonoChoice )), ctx )
travNonemptyEdges f ctx (NE.Nonempty (( test, d ) as pair) rest) =
    let
        ( mD, ctx1 ) =
            travDecider f ctx d

        ( mRest, ctx2 ) =
            travEdges f ctx1 rest
    in
    case mD of
        Nothing ->
            case mRest of
                Nothing ->
                    ( Nothing, ctx2 )

                Just rest1 ->
                    ( Just (NE.Nonempty pair rest1), ctx2 )

        Just d1 ->
            ( Just (NE.Nonempty ( test, d1 ) (withDefaultEdges rest mRest)), ctx2 )


{-| Returns the edges after the first in `travNonemptyEdges`, each with its
subtree rewritten, left to right, or `Nothing` when none changed.
-}
travEdges : (ctx -> MonoExpr -> ( Maybe MonoExpr, ctx )) -> ctx -> List ( a, Decider MonoChoice ) -> ( Maybe (List ( a, Decider MonoChoice )), ctx )
travEdges f ctx edges =
    case edges of
        [] ->
            ( Nothing, ctx )

        (( test, d ) as pair) :: rest ->
            let
                ( mD, ctx1 ) =
                    travDecider f ctx d

                ( mRest, ctx2 ) =
                    travEdges f ctx1 rest
            in
            case mD of
                Nothing ->
                    case mRest of
                        Nothing ->
                            ( Nothing, ctx2 )

                        Just rest1 ->
                            ( Just (pair :: rest1), ctx2 )

                Just d1 ->
                    ( Just (( test, d1 ) :: withDefaultEdges rest mRest), ctx2 )


{-| Returns the value in `m`, or `original` when `m` is `Nothing`. This and the
other `withDefault*` functions are `Maybe.withDefault` written once per type,
so that the walk makes no call to the polymorphic one.
-}
withDefaultExpr : MonoExpr -> Maybe MonoExpr -> MonoExpr
withDefaultExpr original m =
    case m of
        Nothing ->
            original

        Just x ->
            x


{-| Returns the list in `m`, or `original` when `m` is `Nothing`.
-}
withDefaultExprs : List MonoExpr -> Maybe (List MonoExpr) -> List MonoExpr
withDefaultExprs original m =
    case m of
        Nothing ->
            original

        Just x ->
            x


{-| Returns the list in `m`, or `original` when `m` is `Nothing`.
-}
withDefaultKeyed : List ( k, MonoExpr ) -> Maybe (List ( k, MonoExpr )) -> List ( k, MonoExpr )
withDefaultKeyed original m =
    case m of
        Nothing ->
            original

        Just x ->
            x


{-| Returns the captures in `m`, or `original` when `m` is `Nothing`.
-}
withDefaultCaptures : List ( n, MonoExpr, a ) -> Maybe (List ( n, MonoExpr, a )) -> List ( n, MonoExpr, a )
withDefaultCaptures original m =
    case m of
        Nothing ->
            original

        Just x ->
            x


{-| Returns the branches in `m`, or `original` when `m` is `Nothing`.
-}
withDefaultBranches : List ( MonoExpr, MonoExpr ) -> Maybe (List ( MonoExpr, MonoExpr )) -> List ( MonoExpr, MonoExpr )
withDefaultBranches original m =
    case m of
        Nothing ->
            original

        Just x ->
            x


{-| Returns the decision tree in `m`, or `original` when `m` is `Nothing`.
-}
withDefaultDecider : Decider MonoChoice -> Maybe (Decider MonoChoice) -> Decider MonoChoice
withDefaultDecider original m =
    case m of
        Nothing ->
            original

        Just x ->
            x


{-| Returns the edges in `m`, or `original` when `m` is `Nothing`.
-}
withDefaultEdges : List ( a, Decider MonoChoice ) -> Maybe (List ( a, Decider MonoChoice )) -> List ( a, Decider MonoChoice )
withDefaultEdges original m =
    case m of
        Nothing ->
            original

        Just x ->
            x



-- ============================================================================
-- ====== PURE FOLD (BOTTOM-UP) ======
-- ============================================================================


{-| Folds `f` over every expression node in `expr`, starting from `acc`. A node's
children are folded before the node, in the order the module docstring
gives.

`foldExprAccFirst` is the same fold with the callback's arguments the other
way round, and avoids building a closure to swap them.

-}
foldExpr : (MonoExpr -> acc -> acc) -> acc -> MonoExpr -> acc
foldExpr f acc expr =
    foldExprAccFirst (\a e -> f e a) acc expr


{-| Folds `f` over every expression node in `expr`, starting from `acc`, exactly
as `foldExpr` does, but with a callback that takes the accumulator first.
-}
foldExprAccFirst : (acc -> MonoExpr -> acc) -> acc -> MonoExpr -> acc
foldExprAccFirst f acc expr =
    f (foldChildren f acc expr) expr


{-| Returns `acc` with every expression strictly below `expr` folded in, in the
module's child order, without folding `expr` itself.
-}
foldChildren : (acc -> MonoExpr -> acc) -> acc -> MonoExpr -> acc
foldChildren f acc expr =
    case expr of
        MonoClosure info body _ ->
            foldExprAccFirst f (foldCaptures f acc info.captures) body

        MonoCall _ func args _ _ ->
            foldExprs f (foldExprAccFirst f acc func) args

        MonoTailCall _ args _ ->
            foldKeyed f acc args

        MonoIf branches final _ ->
            foldExprAccFirst f (foldBranches f acc branches) final

        MonoLet def body _ ->
            foldExprAccFirst f (foldDef f acc def) body

        MonoDestruct _ inner _ ->
            foldExprAccFirst f acc inner

        MonoCase _ _ decider jumps _ ->
            foldKeyed f (foldDecider f acc decider) jumps

        MonoList _ items _ ->
            foldExprs f acc items

        MonoRecordCreate fields _ ->
            foldKeyed f acc fields

        MonoRecordAccess inner _ _ ->
            foldExprAccFirst f acc inner

        MonoRecordUpdate record updates _ ->
            foldKeyed f (foldExprAccFirst f acc record) updates

        MonoTupleCreate _ elements _ ->
            foldExprs f acc (Mono.tupleToList elements)

        MonoLiteral _ _ ->
            acc

        MonoVarLocal _ _ ->
            acc

        MonoVarGlobal _ _ _ ->
            acc

        MonoVarKernel _ _ _ _ _ ->
            acc

        MonoUnit ->
            acc

        MonoAccessorValue _ _ _ ->
            acc


{-| Returns `acc` with each expression of `items` folded in, left to right.
-}
foldExprs : (acc -> MonoExpr -> acc) -> acc -> List MonoExpr -> acc
foldExprs f acc items =
    case items of
        [] ->
            acc

        x :: xs ->
            foldExprs f (foldExprAccFirst f acc x) xs


{-| Returns `acc` with the expression of each pair in `items` folded in, left to
right.
-}
foldKeyed : (acc -> MonoExpr -> acc) -> acc -> List ( k, MonoExpr ) -> acc
foldKeyed f acc items =
    case items of
        [] ->
            acc

        ( _, x ) :: xs ->
            foldKeyed f (foldExprAccFirst f acc x) xs


{-| Returns `acc` with each captured value folded in, left to right.
-}
foldCaptures : (acc -> MonoExpr -> acc) -> acc -> List ( n, MonoExpr, a ) -> acc
foldCaptures f acc items =
    case items of
        [] ->
            acc

        ( _, x, _ ) :: xs ->
            foldCaptures f (foldExprAccFirst f acc x) xs


{-| Returns `acc` with each condition and then its branch folded in, pair by pair.
-}
foldBranches : (acc -> MonoExpr -> acc) -> acc -> List ( MonoExpr, MonoExpr ) -> acc
foldBranches f acc items =
    case items of
        [] ->
            acc

        ( cond, then_ ) :: xs ->
            foldBranches f (foldExprAccFirst f (foldExprAccFirst f acc cond) then_) xs


{-| Returns `acc` with each edge's subtree folded in, left to right.
-}
foldEdges : (acc -> MonoExpr -> acc) -> acc -> List ( a, Decider MonoChoice ) -> acc
foldEdges f acc edges =
    case edges of
        [] ->
            acc

        ( _, d ) :: rest ->
            foldEdges f (foldDecider f acc d) rest


{-| Returns `acc` with the bound expression of a let definition folded in.
-}
foldDef : (acc -> MonoExpr -> acc) -> acc -> MonoDef -> acc
foldDef f acc def =
    case def of
        MonoDef _ bound ->
            foldExprAccFirst f acc bound

        MonoTailDef _ _ bound ->
            foldExprAccFirst f acc bound


{-| Returns `acc` with the expressions of a decision tree's `Inline` leaves folded
in. A `Chain` is folded success branch first, a `FanOut` its edges and then
its fallback.
-}
foldDecider : (acc -> MonoExpr -> acc) -> acc -> Decider MonoChoice -> acc
foldDecider f acc decider =
    case decider of
        Leaf choice ->
            foldChoice f acc choice

        Chain _ success failure ->
            foldDecider f (foldDecider f acc success) failure

        FanOut _ edges fallback ->
            foldDecider f (foldEdges f acc (NE.toList edges)) fallback


{-| Returns `acc` with an `Inline` leaf's expression folded in. A `Jump` leaf
leaves it unchanged.
-}
foldChoice : (acc -> MonoExpr -> acc) -> acc -> MonoChoice -> acc
foldChoice f acc choice =
    case choice of
        Inline e ->
            foldExprAccFirst f acc e

        Jump _ ->
            acc



-- ============================================================================
-- ====== CHILDREN ======
-- ============================================================================


{-| Returns the direct sub-expressions of `expr`, in the order the module
docstring gives.

It lets a caller write its own recursion, for instance one that needs a
result per subtree rather than a single accumulator, without listing the
constructors. It builds a list on every call, which `foldExprAccFirst` does
not.

-}
childrenOf : MonoExpr -> List MonoExpr
childrenOf expr =
    case expr of
        MonoClosure info body _ ->
            List.map (\( _, e, _ ) -> e) info.captures ++ [ body ]

        MonoCall _ func args _ _ ->
            func :: args

        MonoTailCall _ args _ ->
            List.map Tuple.second args

        MonoIf branches final _ ->
            List.concatMap (\( c, t ) -> [ c, t ]) branches ++ [ final ]

        MonoLet def body _ ->
            [ defBody def, body ]

        MonoDestruct _ inner _ ->
            [ inner ]

        MonoCase _ _ decider jumps _ ->
            deciderExprs decider (List.map Tuple.second jumps)

        MonoList _ items _ ->
            items

        MonoRecordCreate fields _ ->
            List.map Tuple.second fields

        MonoRecordAccess inner _ _ ->
            [ inner ]

        MonoRecordUpdate record updates _ ->
            record :: List.map Tuple.second updates

        MonoTupleCreate _ elements _ ->
            Mono.tupleToList elements

        MonoLiteral _ _ ->
            []

        MonoVarLocal _ _ ->
            []

        MonoVarGlobal _ _ _ ->
            []

        MonoVarKernel _ _ _ _ _ ->
            []

        MonoUnit ->
            []

        MonoAccessorValue _ _ _ ->
            []


{-| Returns the bound expression of a let definition.
-}
defBody : MonoDef -> MonoExpr
defBody def =
    case def of
        MonoDef _ e ->
            e

        MonoTailDef _ _ e ->
            e


{-| Returns the expressions of a decision tree's `Inline` leaves, in walk order,
followed by `rest`.
-}
deciderExprs : Decider MonoChoice -> List MonoExpr -> List MonoExpr
deciderExprs decider rest =
    case decider of
        Leaf (Inline e) ->
            e :: rest

        Leaf (Jump _) ->
            rest

        Chain _ success failure ->
            deciderExprs success (deciderExprs failure rest)

        FanOut _ edges fallback ->
            List.foldr (\( _, d ) acc -> deciderExprs d acc) (deciderExprs fallback rest) (NE.toList edges)



-- ============================================================================
-- TYPE MAPPING
-- ============================================================================


{-| Applies `f` to every `MonoType` stored anywhere in `node`, at the positions
the module docstring lists, and returns the node rebuilt with the results.
Unlike `traverseExpr`, it rebuilds the whole node even where `f` changes
nothing.

It must reach the same positions as `anyNodeType`.

-}
mapNodeTypes : (MonoType -> MonoType) -> MonoNode -> MonoNode
mapNodeTypes f node =
    case node of
        Mono.MonoDefine expr t ->
            Mono.MonoDefine (mapExprTypes f expr) (f t)

        Mono.MonoTailFunc params expr t ->
            Mono.MonoTailFunc (List.map (\( n, pt ) -> ( n, f pt )) params) (mapExprTypes f expr) (f t)

        Mono.MonoCtor home shape t ->
            Mono.MonoCtor home (mapCtorShapeTypes f shape) (f t)

        Mono.MonoEnum home name i t ->
            Mono.MonoEnum home name i (f t)

        Mono.MonoExtern t ->
            Mono.MonoExtern (f t)

        Mono.MonoManagerLeaf s t ->
            Mono.MonoManagerLeaf s (f t)

        Mono.MonoPortIncoming expr t ->
            Mono.MonoPortIncoming (mapExprTypes f expr) (f t)

        Mono.MonoPortOutgoing expr t ->
            Mono.MonoPortOutgoing (mapExprTypes f expr) (f t)


{-| `mapNodeTypes` for an `f` that returns `Nothing` for a type it leaves as it
is, with a state threaded through every call of `f` (a memo of the types already
mapped, say). Returns `Nothing` when no type of `node` changes; otherwise the
node with every type mapped, in which each subtree (expression, path, decision
tree, closure or call record, type list) that `f` leaves alone is the same value
as before, not a copy. It reaches the same positions as `mapNodeTypes`, each once.
-}
mapNodeTypesMaybe : (MonoType -> st -> ( Maybe MonoType, st )) -> st -> MonoNode -> ( Maybe MonoNode, st )
mapNodeTypesMaybe f st0 node =
    let
        g =
            mapExprTypesMaybe f
    in
    case node of
        Mono.MonoDefine expr t ->
            let
                ( me, st1 ) =
                    g expr st0

                ( mt, st2 ) =
                    f t st1
            in
            ( changed2 Mono.MonoDefine expr me t mt, st2 )

        Mono.MonoTailFunc params expr t ->
            let
                ( mp, st1 ) =
                    listMaybe (pairSecond f) params st0

                ( me, st2 ) =
                    g expr st1

                ( mt, st3 ) =
                    f t st2
            in
            ( changed3 Mono.MonoTailFunc params mp expr me t mt, st3 )

        Mono.MonoCtor home shape t ->
            let
                ( mfs, st1 ) =
                    listMaybe f shape.fieldTypes st0

                ( mt, st2 ) =
                    f t st1
            in
            ( changed2 (\fs t1 -> Mono.MonoCtor home { shape | fieldTypes = fs } t1) shape.fieldTypes mfs t mt, st2 )

        Mono.MonoEnum home name i t ->
            Tuple.mapFirst (Maybe.map (Mono.MonoEnum home name i)) (f t st0)

        Mono.MonoExtern t ->
            Tuple.mapFirst (Maybe.map Mono.MonoExtern) (f t st0)

        Mono.MonoManagerLeaf leaf t ->
            Tuple.mapFirst (Maybe.map (Mono.MonoManagerLeaf leaf)) (f t st0)

        Mono.MonoPortIncoming expr t ->
            let
                ( me, st1 ) =
                    g expr st0

                ( mt, st2 ) =
                    f t st1
            in
            ( changed2 Mono.MonoPortIncoming expr me t mt, st2 )

        Mono.MonoPortOutgoing expr t ->
            let
                ( me, st1 ) =
                    g expr st0

                ( mt, st2 ) =
                    f t st1
            in
            ( changed2 Mono.MonoPortOutgoing expr me t mt, st2 )


keep : a -> Maybe a -> a
keep x m =
    Maybe.withDefault x m


{-| `Nothing` when neither part changed; otherwise `build` applied to the parts,
each changed one replaced.
-}
changed2 : (a -> b -> c) -> a -> Maybe a -> b -> Maybe b -> Maybe c
changed2 build a ma b mb =
    case ( ma, mb ) of
        ( Nothing, Nothing ) ->
            Nothing

        _ ->
            Just (build (keep a ma) (keep b mb))


changed3 : (a -> b -> c -> d) -> a -> Maybe a -> b -> Maybe b -> c -> Maybe c -> Maybe d
changed3 build a ma b mb c mc =
    case ( ma, mb, mc ) of
        ( Nothing, Nothing, Nothing ) ->
            Nothing

        _ ->
            Just (build (keep a ma) (keep b mb) (keep c mc))


changed4 : (a -> b -> c -> d -> e) -> a -> Maybe a -> b -> Maybe b -> c -> Maybe c -> d -> Maybe d -> Maybe e
changed4 build a ma b mb c mc d md =
    case ( ma, mb, ( mc, md ) ) of
        ( Nothing, Nothing, ( Nothing, Nothing ) ) ->
            Nothing

        _ ->
            Just (build (keep a ma) (keep b mb) (keep c mc) (keep d md))


{-| `Nothing` when `f` leaves every element alone; otherwise the list with the
changed elements replaced, sharing the unchanged tail.
-}
listMaybe : (a -> st -> ( Maybe a, st )) -> List a -> st -> ( Maybe (List a), st )
listMaybe f xs st =
    case xs of
        [] ->
            ( Nothing, st )

        x :: rest ->
            let
                ( mx, st1 ) =
                    f x st

                ( mr, st2 ) =
                    listMaybe f rest st1
            in
            ( changed2 (::) x mx rest mr, st2 )


pairSecond : (b -> st -> ( Maybe b, st )) -> ( a, b ) -> st -> ( Maybe ( a, b ), st )
pairSecond f ( a, b ) st =
    Tuple.mapFirst (Maybe.map (Tuple.pair a)) (f b st)


tupleMaybe : (a -> st -> ( Maybe a, st )) -> Mono.TupleShape a -> st -> ( Maybe (Mono.TupleShape a), st )
tupleMaybe f shape st =
    case shape of
        Mono.T2 a b ->
            let
                ( ma, st1 ) =
                    f a st

                ( mb, st2 ) =
                    f b st1
            in
            ( changed2 Mono.T2 a ma b mb, st2 )

        Mono.T3 a b c ->
            let
                ( ma, st1 ) =
                    f a st

                ( mb, st2 ) =
                    f b st1

                ( mc, st3 ) =
                    f c st2
            in
            ( changed3 Mono.T3 a ma b mb c mc, st3 )


mapExprTypesMaybe : (MonoType -> st -> ( Maybe MonoType, st )) -> MonoExpr -> st -> ( Maybe MonoExpr, st )
mapExprTypesMaybe f expr st0 =
    let
        g =
            mapExprTypesMaybe f
    in
    case expr of
        Mono.MonoLiteral lit t ->
            Tuple.mapFirst (Maybe.map (Mono.MonoLiteral lit)) (f t st0)

        Mono.MonoVarLocal n t ->
            Tuple.mapFirst (Maybe.map (Mono.MonoVarLocal n)) (f t st0)

        Mono.MonoVarGlobal r sp t ->
            Tuple.mapFirst (Maybe.map (Mono.MonoVarGlobal r sp)) (f t st0)

        Mono.MonoVarKernel r a b c t ->
            Tuple.mapFirst (Maybe.map (Mono.MonoVarKernel r a b c)) (f t st0)

        Mono.MonoList r elems t ->
            let
                ( me, st1 ) =
                    listMaybe g elems st0

                ( mt, st2 ) =
                    f t st1
            in
            ( changed2 (Mono.MonoList r) elems me t mt, st2 )

        Mono.MonoClosure info body t ->
            let
                ( mi, st1 ) =
                    closureInfoTypesMaybe f info st0

                ( mb, st2 ) =
                    g body st1

                ( mt, st3 ) =
                    f t st2
            in
            ( changed3 Mono.MonoClosure info mi body mb t mt, st3 )

        Mono.MonoCall r fn args t info ->
            let
                ( mf, st1 ) =
                    g fn st0

                ( ma, st2 ) =
                    listMaybe g args st1

                ( mt, st3 ) =
                    f t st2

                ( mi, st4 ) =
                    callInfoTypesMaybe f info st3
            in
            ( changed4 (Mono.MonoCall r) fn mf args ma t mt info mi, st4 )

        Mono.MonoTailCall n args t ->
            let
                ( ma, st1 ) =
                    listMaybe (pairSecond g) args st0

                ( mt, st2 ) =
                    f t st1
            in
            ( changed2 (Mono.MonoTailCall n) args ma t mt, st2 )

        Mono.MonoIf branches elseExpr t ->
            let
                branch ( c, e ) st =
                    let
                        ( mCond, stA ) =
                            g c st

                        ( mThen, stB ) =
                            g e stA
                    in
                    ( changed2 Tuple.pair c mCond e mThen, stB )

                ( mb, st1 ) =
                    listMaybe branch branches st0

                ( me, st2 ) =
                    g elseExpr st1

                ( mt, st3 ) =
                    f t st2
            in
            ( changed3 Mono.MonoIf branches mb elseExpr me t mt, st3 )

        Mono.MonoLet def body t ->
            let
                ( md, st1 ) =
                    defTypesMaybe f def st0

                ( mb, st2 ) =
                    g body st1

                ( mt, st3 ) =
                    f t st2
            in
            ( changed3 Mono.MonoLet def md body mb t mt, st3 )

        Mono.MonoDestruct (Mono.MonoDestructor dn path dt) body t ->
            let
                ( mp, st1 ) =
                    pathTypesMaybe f path st0

                ( mdt, st2 ) =
                    f dt st1

                ( mb, st3 ) =
                    g body st2

                ( mt, st4 ) =
                    f t st3
            in
            ( changed4 (\p d b t1 -> Mono.MonoDestruct (Mono.MonoDestructor dn p d) b t1) path mp dt mdt body mb t mt, st4 )

        Mono.MonoCase n1 n2 decider jumps t ->
            let
                ( md, st1 ) =
                    deciderTypesMaybe f decider st0

                ( mj, st2 ) =
                    listMaybe (pairSecond g) jumps st1

                ( mt, st3 ) =
                    f t st2
            in
            ( changed3 (Mono.MonoCase n1 n2) decider md jumps mj t mt, st3 )

        Mono.MonoRecordCreate fields t ->
            let
                ( mf, st1 ) =
                    listMaybe (pairSecond g) fields st0

                ( mt, st2 ) =
                    f t st1
            in
            ( changed2 Mono.MonoRecordCreate fields mf t mt, st2 )

        Mono.MonoRecordAccess e n t ->
            let
                ( me, st1 ) =
                    g e st0

                ( mt, st2 ) =
                    f t st1
            in
            ( changed2 (\e1 t1 -> Mono.MonoRecordAccess e1 n t1) e me t mt, st2 )

        Mono.MonoRecordUpdate e fields t ->
            let
                ( me, st1 ) =
                    g e st0

                ( mf, st2 ) =
                    listMaybe (pairSecond g) fields st1

                ( mt, st3 ) =
                    f t st2
            in
            ( changed3 Mono.MonoRecordUpdate e me fields mf t mt, st3 )

        Mono.MonoTupleCreate r elems t ->
            let
                ( me, st1 ) =
                    tupleMaybe g elems st0

                ( mt, st2 ) =
                    f t st1
            in
            ( changed2 (Mono.MonoTupleCreate r) elems me t mt, st2 )

        Mono.MonoUnit ->
            ( Nothing, st0 )

        Mono.MonoAccessorValue r n t ->
            Tuple.mapFirst (Maybe.map (Mono.MonoAccessorValue r n)) (f t st0)


closureInfoTypesMaybe : (MonoType -> st -> ( Maybe MonoType, st )) -> ClosureInfo -> st -> ( Maybe ClosureInfo, st )
closureInfoTypesMaybe f info st0 =
    let
        capture ( n, e, b ) st =
            Tuple.mapFirst (Maybe.map (\e1 -> ( n, e1, b ))) (mapExprTypesMaybe f e st)

        ( mc, st1 ) =
            listMaybe capture info.captures st0

        ( mp, st2 ) =
            listMaybe (pairSecond f) info.params st1

        ( ma, st3 ) =
            captureAbiMaybe f info.captureAbi st2
    in
    ( changed3 (\c p a -> { info | captures = c, params = p, captureAbi = a }) info.captures mc info.params mp info.captureAbi ma, st3 )


callInfoTypesMaybe : (MonoType -> st -> ( Maybe MonoType, st )) -> CallInfo -> st -> ( Maybe CallInfo, st )
callInfoTypesMaybe f info st0 =
    let
        ( ma, st1 ) =
            captureAbiMaybe f info.captureAbi st0

        ( mr, st2 ) =
            f info.evaluatorReturnType st1
    in
    ( changed2 (\a r -> { info | captureAbi = a, evaluatorReturnType = r }) info.captureAbi ma info.evaluatorReturnType mr, st2 )


captureAbiMaybe : (MonoType -> st -> ( Maybe MonoType, st )) -> Maybe CaptureABI -> st -> ( Maybe (Maybe CaptureABI), st )
captureAbiMaybe f mAbi st0 =
    case mAbi of
        Nothing ->
            ( Nothing, st0 )

        Just abi ->
            let
                ( mc, st1 ) =
                    listMaybe f abi.captureTypes st0

                ( mp, st2 ) =
                    listMaybe f abi.paramTypes st1

                ( mr, st3 ) =
                    f abi.returnType st2
            in
            ( changed3 (\c p r -> Just { abi | captureTypes = c, paramTypes = p, returnType = r }) abi.captureTypes mc abi.paramTypes mp abi.returnType mr, st3 )


defTypesMaybe : (MonoType -> st -> ( Maybe MonoType, st )) -> MonoDef -> st -> ( Maybe MonoDef, st )
defTypesMaybe f def st0 =
    case def of
        Mono.MonoDef n e ->
            Tuple.mapFirst (Maybe.map (Mono.MonoDef n)) (mapExprTypesMaybe f e st0)

        Mono.MonoTailDef n params e ->
            let
                ( mp, st1 ) =
                    listMaybe (pairSecond f) params st0

                ( me, st2 ) =
                    mapExprTypesMaybe f e st1
            in
            ( changed2 (Mono.MonoTailDef n) params mp e me, st2 )


pathTypesMaybe : (MonoType -> st -> ( Maybe MonoType, st )) -> MonoPath -> st -> ( Maybe MonoPath, st )
pathTypesMaybe f path st0 =
    case path of
        Mono.MonoIndex i ck t rest ->
            let
                ( mt, st1 ) =
                    f t st0

                ( mr, st2 ) =
                    pathTypesMaybe f rest st1
            in
            ( changed2 (Mono.MonoIndex i ck) t mt rest mr, st2 )

        Mono.MonoField n t rest ->
            let
                ( mt, st1 ) =
                    f t st0

                ( mr, st2 ) =
                    pathTypesMaybe f rest st1
            in
            ( changed2 (Mono.MonoField n) t mt rest mr, st2 )

        Mono.MonoUnbox t rest ->
            let
                ( mt, st1 ) =
                    f t st0

                ( mr, st2 ) =
                    pathTypesMaybe f rest st1
            in
            ( changed2 Mono.MonoUnbox t mt rest mr, st2 )

        Mono.MonoRoot n t ->
            Tuple.mapFirst (Maybe.map (Mono.MonoRoot n)) (f t st0)


dtPathTypesMaybe : (MonoType -> st -> ( Maybe MonoType, st )) -> MonoDtPath -> st -> ( Maybe MonoDtPath, st )
dtPathTypesMaybe f path st0 =
    case path of
        Mono.DtRoot n t ->
            Tuple.mapFirst (Maybe.map (Mono.DtRoot n)) (f t st0)

        Mono.DtIndex i ck t rest ->
            let
                ( mt, st1 ) =
                    f t st0

                ( mr, st2 ) =
                    dtPathTypesMaybe f rest st1
            in
            ( changed2 (Mono.DtIndex i ck) t mt rest mr, st2 )

        Mono.DtUnbox t rest ->
            let
                ( mt, st1 ) =
                    f t st0

                ( mr, st2 ) =
                    dtPathTypesMaybe f rest st1
            in
            ( changed2 Mono.DtUnbox t mt rest mr, st2 )


nonemptyMaybe : (a -> st -> ( Maybe a, st )) -> NE.Nonempty a -> st -> ( Maybe (NE.Nonempty a), st )
nonemptyMaybe f (NE.Nonempty x rest) st0 =
    let
        ( mx, st1 ) =
            f x st0

        ( mr, st2 ) =
            listMaybe f rest st1
    in
    ( changed2 NE.Nonempty x mx rest mr, st2 )


deciderTypesMaybe : (MonoType -> st -> ( Maybe MonoType, st )) -> Decider MonoChoice -> st -> ( Maybe (Decider MonoChoice), st )
deciderTypesMaybe f decider st0 =
    case decider of
        Mono.Leaf choice ->
            case choice of
                Mono.Inline e ->
                    Tuple.mapFirst (Maybe.map (Mono.Leaf << Mono.Inline)) (mapExprTypesMaybe f e st0)

                Mono.Jump _ ->
                    ( Nothing, st0 )

        Mono.Chain tests ifDec elseDec ->
            let
                test ( p, t ) st =
                    Tuple.mapFirst (Maybe.map (\p1 -> ( p1, t ))) (dtPathTypesMaybe f p st)

                ( mt, st1 ) =
                    nonemptyMaybe test tests st0

                ( mi, st2 ) =
                    deciderTypesMaybe f ifDec st1

                ( me, st3 ) =
                    deciderTypesMaybe f elseDec st2
            in
            ( changed3 Mono.Chain tests mt ifDec mi elseDec me, st3 )

        Mono.FanOut p edges fallback ->
            let
                edge ( t, d ) st =
                    Tuple.mapFirst (Maybe.map (Tuple.pair t)) (deciderTypesMaybe f d st)

                ( mp, st1 ) =
                    dtPathTypesMaybe f p st0

                ( me, st2 ) =
                    nonemptyMaybe edge edges st1

                ( mf, st3 ) =
                    deciderTypesMaybe f fallback st2
            in
            ( changed3 Mono.FanOut p mp edges me fallback mf, st3 )


{-| Applies `f` to each field type of a constructor shape.
-}
mapCtorShapeTypes : (MonoType -> MonoType) -> CtorShape -> CtorShape
mapCtorShapeTypes f shape =
    { shape | fieldTypes = List.map f shape.fieldTypes }


{-| Applies `f` to every type in `expr` and in each expression below it,
including closure and call ABI records, destructuring paths and decision-tree
paths.
-}
mapExprTypes : (MonoType -> MonoType) -> MonoExpr -> MonoExpr
mapExprTypes f expr =
    case expr of
        Mono.MonoLiteral lit t ->
            Mono.MonoLiteral lit (f t)

        Mono.MonoVarLocal n t ->
            Mono.MonoVarLocal n (f t)

        Mono.MonoVarGlobal r s t ->
            Mono.MonoVarGlobal r s (f t)

        Mono.MonoVarKernel r a b c t ->
            Mono.MonoVarKernel r a b c (f t)

        Mono.MonoList r elems t ->
            Mono.MonoList r (List.map (mapExprTypes f) elems) (f t)

        Mono.MonoClosure info body t ->
            Mono.MonoClosure (mapClosureInfoTypes f info) (mapExprTypes f body) (f t)

        Mono.MonoCall r fn args t info ->
            Mono.MonoCall r (mapExprTypes f fn) (List.map (mapExprTypes f) args) (f t) (mapCallInfoTypes f info)

        Mono.MonoTailCall n args t ->
            Mono.MonoTailCall n (List.map (\( nm, e ) -> ( nm, mapExprTypes f e )) args) (f t)

        Mono.MonoIf branches elseExpr t ->
            Mono.MonoIf (List.map (\( c, e ) -> ( mapExprTypes f c, mapExprTypes f e )) branches) (mapExprTypes f elseExpr) (f t)

        Mono.MonoLet def body t ->
            Mono.MonoLet (mapDefTypes f def) (mapExprTypes f body) (f t)

        Mono.MonoDestruct destructor body t ->
            Mono.MonoDestruct (mapDestructorTypes f destructor) (mapExprTypes f body) (f t)

        Mono.MonoCase n1 n2 decider jumps t ->
            Mono.MonoCase n1 n2 (mapDeciderTypes f decider) (List.map (\( i, e ) -> ( i, mapExprTypes f e )) jumps) (f t)

        Mono.MonoRecordCreate fields t ->
            Mono.MonoRecordCreate (List.map (\( n, e ) -> ( n, mapExprTypes f e )) fields) (f t)

        Mono.MonoRecordAccess e n t ->
            Mono.MonoRecordAccess (mapExprTypes f e) n (f t)

        Mono.MonoRecordUpdate e fields t ->
            Mono.MonoRecordUpdate (mapExprTypes f e) (List.map (\( n, fe ) -> ( n, mapExprTypes f fe )) fields) (f t)

        Mono.MonoTupleCreate r elems t ->
            Mono.MonoTupleCreate r (Mono.tupleMap (mapExprTypes f) elems) (f t)

        Mono.MonoUnit ->
            Mono.MonoUnit

        Mono.MonoAccessorValue r n t ->
            Mono.MonoAccessorValue r n (f t)


{-| Applies `f` to the types in a closure's captured values, its parameters and
its `captureAbi`.
-}
mapClosureInfoTypes : (MonoType -> MonoType) -> ClosureInfo -> ClosureInfo
mapClosureInfoTypes f info =
    { info
        | captures = List.map (\( n, e, b ) -> ( n, mapExprTypes f e, b )) info.captures
        , params = List.map (\( n, t ) -> ( n, f t )) info.params
        , captureAbi = Maybe.map (mapCaptureAbiTypes f) info.captureAbi
    }


{-| Applies `f` to a call's `captureAbi` and its `evaluatorReturnType`, the only
types a `CallInfo` holds.
-}
mapCallInfoTypes : (MonoType -> MonoType) -> CallInfo -> CallInfo
mapCallInfoTypes f info =
    { info
        | captureAbi = Maybe.map (mapCaptureAbiTypes f) info.captureAbi
        , evaluatorReturnType = f info.evaluatorReturnType
    }


{-| Applies `f` to every capture, parameter and return type of a `CaptureABI`.
-}
mapCaptureAbiTypes : (MonoType -> MonoType) -> CaptureABI -> CaptureABI
mapCaptureAbiTypes f abi =
    { abi
        | captureTypes = List.map f abi.captureTypes
        , paramTypes = List.map f abi.paramTypes
        , returnType = f abi.returnType
    }


{-| Applies `f` to the types in a let definition: a tail definition's parameter
types and the bound expression.
-}
mapDefTypes : (MonoType -> MonoType) -> MonoDef -> MonoDef
mapDefTypes f def =
    case def of
        Mono.MonoDef n e ->
            Mono.MonoDef n (mapExprTypes f e)

        Mono.MonoTailDef n params e ->
            Mono.MonoTailDef n (List.map (\( nm, t ) -> ( nm, f t )) params) (mapExprTypes f e)


{-| Applies `f` to a destructuring binding's type and to each step of its path.
-}
mapDestructorTypes : (MonoType -> MonoType) -> MonoDestructor -> MonoDestructor
mapDestructorTypes f (Mono.MonoDestructor n path t) =
    Mono.MonoDestructor n (mapPathTypes f path) (f t)


{-| Applies `f` to the type at every step of a destructuring path.
-}
mapPathTypes : (MonoType -> MonoType) -> MonoPath -> MonoPath
mapPathTypes f path =
    case path of
        Mono.MonoIndex i ck t rest ->
            Mono.MonoIndex i ck (f t) (mapPathTypes f rest)

        Mono.MonoField n t rest ->
            Mono.MonoField n (f t) (mapPathTypes f rest)

        Mono.MonoUnbox t rest ->
            Mono.MonoUnbox (f t) (mapPathTypes f rest)

        Mono.MonoRoot n t ->
            Mono.MonoRoot n (f t)


{-| Applies `f` to the type at every step of a decision-tree path.
-}
mapDtPathTypes : (MonoType -> MonoType) -> MonoDtPath -> MonoDtPath
mapDtPathTypes f path =
    case path of
        Mono.DtRoot n t ->
            Mono.DtRoot n (f t)

        Mono.DtIndex i ck t rest ->
            Mono.DtIndex i ck (f t) (mapDtPathTypes f rest)

        Mono.DtUnbox t rest ->
            Mono.DtUnbox (f t) (mapDtPathTypes f rest)


{-| Applies `f` to the paths of a decision tree's tests and to the expressions of
its `Inline` leaves.
-}
mapDeciderTypes : (MonoType -> MonoType) -> Decider MonoChoice -> Decider MonoChoice
mapDeciderTypes f decider =
    case decider of
        Mono.Leaf choice ->
            Mono.Leaf (mapChoiceTypes f choice)

        Mono.Chain tests ifDec elseDec ->
            Mono.Chain (NE.map (\( p, test ) -> ( mapDtPathTypes f p, test )) tests) (mapDeciderTypes f ifDec) (mapDeciderTypes f elseDec)

        Mono.FanOut p edges fallback ->
            Mono.FanOut (mapDtPathTypes f p) (NE.map (\( test, dec ) -> ( test, mapDeciderTypes f dec )) edges) (mapDeciderTypes f fallback)


{-| Applies `f` to the types in an `Inline` leaf's expression. A `Jump` leaf is
returned as it is.
-}
mapChoiceTypes : (MonoType -> MonoType) -> MonoChoice -> MonoChoice
mapChoiceTypes f choice =
    case choice of
        Mono.Inline e ->
            Mono.Inline (mapExprTypes f e)

        Mono.Jump i ->
            Mono.Jump i



-- ============================================================================
-- TYPE QUERY
-- ============================================================================


{-| Returns whether `p` holds for any `MonoType` stored in `node`, at the same
positions `mapNodeTypes` reaches. It stops at the first type for which `p`
holds.
-}
anyNodeType : (MonoType -> Bool) -> MonoNode -> Bool
anyNodeType p node =
    case node of
        Mono.MonoDefine expr t ->
            p t || anyExprType p expr

        Mono.MonoTailFunc params expr t ->
            p t || anyParamType p params || anyExprType p expr

        Mono.MonoCtor _ shape t ->
            p t || anyType p shape.fieldTypes

        Mono.MonoEnum _ _ _ t ->
            p t

        Mono.MonoExtern t ->
            p t

        Mono.MonoManagerLeaf _ t ->
            p t

        Mono.MonoPortIncoming expr t ->
            p t || anyExprType p expr

        Mono.MonoPortOutgoing expr t ->
            p t || anyExprType p expr


{-| Returns whether `p` holds for any type in `expr` or below it, at the same
positions `mapExprTypes` reaches.
-}
anyExprType : (MonoType -> Bool) -> MonoExpr -> Bool
anyExprType p expr =
    case expr of
        Mono.MonoLiteral _ t ->
            p t

        Mono.MonoVarLocal _ t ->
            p t

        Mono.MonoVarGlobal _ _ t ->
            p t

        Mono.MonoVarKernel _ _ _ _ t ->
            p t

        Mono.MonoList _ elems t ->
            p t || anyExprs p elems

        Mono.MonoClosure info body t ->
            p t || anyClosureInfoType p info || anyExprType p body

        Mono.MonoCall _ fn args t info ->
            p t || anyExprType p fn || anyExprs p args || anyCallInfoType p info

        Mono.MonoTailCall _ args t ->
            p t || anyKeyed p args

        Mono.MonoIf branches elseExpr t ->
            p t || anyBranches p branches || anyExprType p elseExpr

        Mono.MonoLet def body t ->
            p t || anyDefType p def || anyExprType p body

        Mono.MonoDestruct destructor body t ->
            p t || anyDestructorType p destructor || anyExprType p body

        Mono.MonoCase _ _ decider jumps t ->
            p t || anyDeciderType p decider || anyKeyed p jumps

        Mono.MonoRecordCreate fields t ->
            p t || anyKeyed p fields

        Mono.MonoRecordAccess e _ t ->
            p t || anyExprType p e

        Mono.MonoRecordUpdate e fields t ->
            p t || anyExprType p e || anyKeyed p fields

        Mono.MonoTupleCreate _ elems t ->
            p t || anyExprs p (Mono.tupleToList elems)

        Mono.MonoUnit ->
            False

        Mono.MonoAccessorValue _ _ t ->
            p t


{-| Returns whether `p` holds for a type in any of `items`.
-}
anyExprs : (MonoType -> Bool) -> List MonoExpr -> Bool
anyExprs p items =
    case items of
        [] ->
            False

        x :: xs ->
            anyExprType p x || anyExprs p xs


{-| Returns whether `p` holds for a type in the expression of any pair.
-}
anyKeyed : (MonoType -> Bool) -> List ( k, MonoExpr ) -> Bool
anyKeyed p items =
    case items of
        [] ->
            False

        ( _, x ) :: xs ->
            anyExprType p x || anyKeyed p xs


{-| Returns whether `p` holds for a type in any captured value.
-}
anyCaptures : (MonoType -> Bool) -> List ( n, MonoExpr, a ) -> Bool
anyCaptures p items =
    case items of
        [] ->
            False

        ( _, x, _ ) :: xs ->
            anyExprType p x || anyCaptures p xs


{-| Returns whether `p` holds for a type in any condition or branch of an `if`.
-}
anyBranches : (MonoType -> Bool) -> List ( MonoExpr, MonoExpr ) -> Bool
anyBranches p items =
    case items of
        [] ->
            False

        ( cond, then_ ) :: xs ->
            anyExprType p cond || anyExprType p then_ || anyBranches p xs


{-| Returns whether `p` holds for any of `types`.
-}
anyType : (MonoType -> Bool) -> List MonoType -> Bool
anyType p types =
    case types of
        [] ->
            False

        t :: rest ->
            p t || anyType p rest


{-| Returns whether `p` holds for the type of any parameter.
-}
anyParamType : (MonoType -> Bool) -> List ( n, MonoType ) -> Bool
anyParamType p params =
    case params of
        [] ->
            False

        ( _, t ) :: rest ->
            p t || anyParamType p rest


{-| Returns whether `p` holds for a type in a closure's captured values,
parameters or `captureAbi`.
-}
anyClosureInfoType : (MonoType -> Bool) -> ClosureInfo -> Bool
anyClosureInfoType p info =
    anyCaptures p info.captures
        || anyParamType p info.params
        || (case info.captureAbi of
                Just abi ->
                    anyCaptureAbiType p abi

                Nothing ->
                    False
           )


{-| Returns whether `p` holds for a call's `evaluatorReturnType` or a type in its
`captureAbi`.
-}
anyCallInfoType : (MonoType -> Bool) -> CallInfo -> Bool
anyCallInfoType p info =
    p info.evaluatorReturnType
        || (case info.captureAbi of
                Just abi ->
                    anyCaptureAbiType p abi

                Nothing ->
                    False
           )


{-| Returns whether `p` holds for any capture, parameter or return type of a
`CaptureABI`.
-}
anyCaptureAbiType : (MonoType -> Bool) -> CaptureABI -> Bool
anyCaptureAbiType p abi =
    anyType p abi.captureTypes || anyType p abi.paramTypes || p abi.returnType


{-| Returns whether `p` holds for a type in a let definition.
-}
anyDefType : (MonoType -> Bool) -> MonoDef -> Bool
anyDefType p def =
    case def of
        Mono.MonoDef _ e ->
            anyExprType p e

        Mono.MonoTailDef _ params e ->
            anyParamType p params || anyExprType p e


{-| Returns whether `p` holds for a destructuring binding's type or a type on its
path.
-}
anyDestructorType : (MonoType -> Bool) -> MonoDestructor -> Bool
anyDestructorType p (Mono.MonoDestructor _ path t) =
    p t || anyPathType p path


{-| Returns whether `p` holds for the type at any step of a destructuring path.
-}
anyPathType : (MonoType -> Bool) -> MonoPath -> Bool
anyPathType p path =
    case path of
        Mono.MonoIndex _ _ t rest ->
            p t || anyPathType p rest

        Mono.MonoField _ t rest ->
            p t || anyPathType p rest

        Mono.MonoUnbox t rest ->
            p t || anyPathType p rest

        Mono.MonoRoot _ t ->
            p t


{-| Returns whether `p` holds for the type at any step of a decision-tree path.
-}
anyDtPathType : (MonoType -> Bool) -> MonoDtPath -> Bool
anyDtPathType p path =
    case path of
        Mono.DtRoot _ t ->
            p t

        Mono.DtIndex _ _ t rest ->
            p t || anyDtPathType p rest

        Mono.DtUnbox t rest ->
            p t || anyDtPathType p rest


{-| Returns whether `p` holds for a type on a test path or in an `Inline` leaf of
a decision tree.
-}
anyDeciderType : (MonoType -> Bool) -> Decider MonoChoice -> Bool
anyDeciderType p decider =
    case decider of
        Mono.Leaf choice ->
            anyChoiceType p choice

        Mono.Chain tests ifDec elseDec ->
            anyTests p (NE.toList tests) || anyDeciderType p ifDec || anyDeciderType p elseDec

        Mono.FanOut pth edges fallback ->
            anyDtPathType p pth || anyEdges p (NE.toList edges) || anyDeciderType p fallback


{-| Returns whether `p` holds for a type on the path of any test in a `Chain`.
-}
anyTests : (MonoType -> Bool) -> List ( MonoDtPath, a ) -> Bool
anyTests p tests =
    case tests of
        [] ->
            False

        ( pth, _ ) :: rest ->
            anyDtPathType p pth || anyTests p rest


{-| Returns whether `p` holds for a type in any edge's subtree.
-}
anyEdges : (MonoType -> Bool) -> List ( a, Decider MonoChoice ) -> Bool
anyEdges p edges =
    case edges of
        [] ->
            False

        ( _, d ) :: rest ->
            anyDeciderType p d || anyEdges p rest


{-| Returns whether `p` holds for a type in an `Inline` leaf's expression. A
`Jump` leaf has none.
-}
anyChoiceType : (MonoType -> Bool) -> MonoChoice -> Bool
anyChoiceType p choice =
    case choice of
        Mono.Inline e ->
            anyExprType p e

        Mono.Jump _ ->
            False



-- ============================================================================
-- ====== SPEC REFERENCE EDGES ======
-- ============================================================================


{-| Returns, for each entry of `nodes`, the SpecIds that the node's expression
refers to through a `MonoVarGlobal`, at the same index, so the result is
indexed by SpecId as `nodes` is. An empty entry stays `Nothing`. A SpecId
appears once per reference, so it can be repeated, and the order is not
meaningful.

Every `MonoVarGlobal` counts, wherever it occurs: as the head of a call,
inside a partial application, or as a value stored in data. A call's
`fastEvaluatorSpec` is not read, so it adds no edge.

`MonoCtor`, `MonoEnum`, `MonoExtern` and `MonoManagerLeaf` nodes hold no
expression and refer to nothing.

-}
collectSpecEdges : Array (Maybe MonoNode) -> Array (Maybe (List Mono.SpecId))
collectSpecEdges nodes =
    Array.map (Maybe.map specEdgesOfNode) nodes


{-| Returns the SpecIds referred to by `MonoVarGlobal`s in `node`'s expression,
or none for a node kind that has no expression.
-}
specEdgesOfNode : MonoNode -> List Mono.SpecId
specEdgesOfNode node =
    case node of
        Mono.MonoDefine body _ ->
            specEdgesOfExpr body

        Mono.MonoTailFunc _ body _ ->
            specEdgesOfExpr body

        Mono.MonoPortIncoming body _ ->
            specEdgesOfExpr body

        Mono.MonoPortOutgoing body _ ->
            specEdgesOfExpr body

        Mono.MonoCtor _ _ _ ->
            []

        Mono.MonoEnum _ _ _ _ ->
            []

        Mono.MonoExtern _ ->
            []

        Mono.MonoManagerLeaf _ _ ->
            []


{-| Returns the SpecId of every `MonoVarGlobal` in `body`, one per occurrence,
most recently visited first.
-}
specEdgesOfExpr : MonoExpr -> List Mono.SpecId
specEdgesOfExpr body =
    foldExprAccFirst
        (\acc e ->
            case e of
                MonoVarGlobal _ specId _ ->
                    specId :: acc

                _ ->
                    acc
        )
        []
        body


{-| Returns `expr` with every reference to the local `oldName` renamed to
`newName`: variable uses, tail calls, and closure captures, whose names must
change together with the uses inside the closure. Elm forbids shadowing, so
every occurrence of the name is the same variable.
-}
renameLocal : String -> String -> Mono.MonoExpr -> Mono.MonoExpr
renameLocal oldName newName expr =
    if oldName == newName then
        expr

    else
        mapExpr
            (\e ->
                case e of
                    Mono.MonoVarLocal n t ->
                        if n == oldName then
                            Just (Mono.MonoVarLocal newName t)

                        else
                            Nothing

                    Mono.MonoTailCall n args t ->
                        if n == oldName then
                            Just (Mono.MonoTailCall newName args t)

                        else
                            Nothing

                    Mono.MonoClosure info body t ->
                        if List.any (\( n, _, _ ) -> n == oldName) info.captures then
                            Just
                                (Mono.MonoClosure
                                    { info
                                        | captures =
                                            List.map
                                                (\( n, ce, u ) ->
                                                    ( if n == oldName then
                                                        newName

                                                      else
                                                        n
                                                    , ce
                                                    , u
                                                    )
                                                )
                                                info.captures
                                    }
                                    body
                                    t
                                )

                        else
                            Nothing

                    _ ->
                        Nothing
            )
            expr
