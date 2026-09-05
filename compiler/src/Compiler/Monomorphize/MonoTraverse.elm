module Compiler.Monomorphize.MonoTraverse exposing
    ( traverseExpr, mapExpr
    , foldExpr, foldExprAccFirst
    , mapNodeTypes, anyNodeType
    , childrenOf
    )

{-| Generic AST traversal abstractions for MonoExpr.

This module provides two core traversal patterns:

  - **traverseExpr** - Context-threaded transformation (bottom-up)
  - **foldExpr** - Pure fold/analysis (bottom-up)

Each function handles structural recursion, calling the user-provided
function on each node after processing children.


# Context-Threaded Traversal

@docs traverseExpr, mapExpr


# Fold

@docs foldExpr, foldExprAccFirst


# Type mapping / query

@docs mapNodeTypes, anyNodeType


# Children

@docs childrenOf

-}

import Compiler.AST.Monomorphized as Mono exposing (CallInfo, CaptureABI, ClosureInfo, CtorShape, Decider(..), MonoChoice(..), MonoDef(..), MonoDestructor, MonoDtPath, MonoExpr(..), MonoNode, MonoPath, MonoType)



-- ============================================================================
-- ====== CONTEXT-THREADED TRAVERSAL (BOTTOM-UP) ======
-- ============================================================================


{-| Context-threaded transformation over expressions.
The context is threaded through in evaluation order (left to right).
The callback runs bottom-up (children first), EXACTLY ONCE per node.

**The callback returns `( Maybe MonoExpr, ctx )`: `Nothing` means "I did not
change this node".** That is what keeps the traversal from copying the tree.
Its callers rewrite a few percent of the nodes they visit, and the walk below
rebuilds a node only when one of its children (or the callback) actually
returned something new — so an untouched subtree is returned as-is and costs
zero allocation. Returning `Just expr` unchanged is legal (and is how a
callback that only wants to update `ctx` at an untouched node says so); it
just re-allocates the spine above it.

`f` is the user callback everywhere below: the children walk recurses through
`travExpr f` as a saturated direct call, so no `travExpr f` PAP is built per
node, and the def / decider / choice helpers apply the SAME single lift.
(Until 2026-09-04 `traverseExprChildren` received the lifted function and
`traverseDef`/`traverseDecider`/`traverseChoice` lifted it again, so every
let-RHS and case-branch subtree was walked by `traverseExpr (traverseExpr f)`
— exponential in let/case nesting, and `f` ran once per path. That was the
Aug-26 -> Sep-3 self-compile regression: `plans/e4a-deferred-overlay.md`,
`DEFECTS_DO_NOT_FORGET.md` §3.)

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


{-| `traverseExpr` for a callback that needs no context.
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


{-| The change-tracking walk. `Nothing` = this subtree is unchanged, so the
caller keeps the node it already has and nothing is allocated on that path.
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


{-| Rebuild a node's direct children, keeping the node when nothing moved.
`f` is the user callback; recursion is `travExpr f` (a direct saturated call).
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
                            -- body only: the ClosureInfo record is NOT copied
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
                ( mElements, ctx1 ) =
                    travExprs f ctx elements
            in
            case mElements of
                Nothing ->
                    ( Nothing, ctx1 )

                Just e ->
                    ( Just (MonoTupleCreate region e resultType), ctx1 )

        -- Leaf expressions - no children
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
                    travEdges f ctx edges

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


{-| The list walks. Each recurses through `travExpr f` directly (no PAP per
item), threads the context left to right, and returns `Nothing` — allocating
no list at all — when no element changed.
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


{-| Monomorphic `Maybe.withDefault`s: they keep the hot walk free of a
polymorphic kernel call per rebuilt node.
-}
withDefaultExpr : MonoExpr -> Maybe MonoExpr -> MonoExpr
withDefaultExpr original m =
    case m of
        Nothing ->
            original

        Just x ->
            x


withDefaultExprs : List MonoExpr -> Maybe (List MonoExpr) -> List MonoExpr
withDefaultExprs original m =
    case m of
        Nothing ->
            original

        Just x ->
            x


withDefaultKeyed : List ( k, MonoExpr ) -> Maybe (List ( k, MonoExpr )) -> List ( k, MonoExpr )
withDefaultKeyed original m =
    case m of
        Nothing ->
            original

        Just x ->
            x


withDefaultCaptures : List ( n, MonoExpr, a ) -> Maybe (List ( n, MonoExpr, a )) -> List ( n, MonoExpr, a )
withDefaultCaptures original m =
    case m of
        Nothing ->
            original

        Just x ->
            x


withDefaultBranches : List ( MonoExpr, MonoExpr ) -> Maybe (List ( MonoExpr, MonoExpr )) -> List ( MonoExpr, MonoExpr )
withDefaultBranches original m =
    case m of
        Nothing ->
            original

        Just x ->
            x


withDefaultDecider : Decider MonoChoice -> Maybe (Decider MonoChoice) -> Decider MonoChoice
withDefaultDecider original m =
    case m of
        Nothing ->
            original

        Just x ->
            x


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


{-| Pure fold over expressions. Accumulates bottom-up
(children are folded before the parent).

Takes its arguments explicitly: written point-free (`foldExpr f = …`) this is
declared arity 3 but defined with one parameter, so every one of its ~29 call
sites paid a `papCreate` + `papExtend` and an indirect entry. Hot callers can
skip the argument flip entirely by using `foldExprAccFirst`.

-}
foldExpr : (MonoExpr -> acc -> acc) -> acc -> MonoExpr -> acc
foldExpr f acc expr =
    foldExprAccFirst (\a e -> f e a) acc expr


{-| Acc-first fold over expressions — the shape the internal loops want, so a
caller that can supply it avoids the flip closure `foldExpr` builds.
-}
foldExprAccFirst : (acc -> MonoExpr -> acc) -> acc -> MonoExpr -> acc
foldExprAccFirst f acc expr =
    f (foldChildren f acc expr) expr


{-| Fold over direct children, recursing via `foldExprAccFirst` directly. The
list walks are direct tail recursion rather than `List.foldl (\e a -> …)`: the
lambda made HOF elimination leave a `papCreate` behind at every one of these
nine sites, one per visited node with a list child.
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
            foldExprs f acc elements

        -- Leaf expressions - no children
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


foldExprs : (acc -> MonoExpr -> acc) -> acc -> List MonoExpr -> acc
foldExprs f acc items =
    case items of
        [] ->
            acc

        x :: xs ->
            foldExprs f (foldExprAccFirst f acc x) xs


foldKeyed : (acc -> MonoExpr -> acc) -> acc -> List ( k, MonoExpr ) -> acc
foldKeyed f acc items =
    case items of
        [] ->
            acc

        ( _, x ) :: xs ->
            foldKeyed f (foldExprAccFirst f acc x) xs


foldCaptures : (acc -> MonoExpr -> acc) -> acc -> List ( n, MonoExpr, a ) -> acc
foldCaptures f acc items =
    case items of
        [] ->
            acc

        ( _, x, _ ) :: xs ->
            foldCaptures f (foldExprAccFirst f acc x) xs


foldBranches : (acc -> MonoExpr -> acc) -> acc -> List ( MonoExpr, MonoExpr ) -> acc
foldBranches f acc items =
    case items of
        [] ->
            acc

        ( cond, then_ ) :: xs ->
            foldBranches f (foldExprAccFirst f (foldExprAccFirst f acc cond) then_) xs


foldEdges : (acc -> MonoExpr -> acc) -> acc -> List ( a, Decider MonoChoice ) -> acc
foldEdges f acc edges =
    case edges of
        [] ->
            acc

        ( _, d ) :: rest ->
            foldEdges f (foldDecider f acc d) rest


foldDef : (acc -> MonoExpr -> acc) -> acc -> MonoDef -> acc
foldDef f acc def =
    case def of
        MonoDef _ bound ->
            foldExprAccFirst f acc bound

        MonoTailDef _ _ bound ->
            foldExprAccFirst f acc bound


foldDecider : (acc -> MonoExpr -> acc) -> acc -> Decider MonoChoice -> acc
foldDecider f acc decider =
    case decider of
        Leaf choice ->
            foldChoice f acc choice

        Chain _ success failure ->
            foldDecider f (foldDecider f acc success) failure

        FanOut _ edges fallback ->
            foldDecider f (foldEdges f acc edges) fallback


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


{-| The DIRECT sub-expressions of a node, in evaluation order (a `MonoDef`'s
RHS, a decider's inline choices, jump bodies, captures...). Lets a caller
write its own recursion — e.g. one that needs each child's SUBTREE result
rather than a flat fold — without re-enumerating the constructors.

Materialises a list, so it is for callers that want one (tests, censuses);
anything hot should use `foldExprAccFirst`.

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
            elements

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


defBody : MonoDef -> MonoExpr
defBody def =
    case def of
        MonoDef _ e ->
            e

        MonoTailDef _ _ e ->
            e


{-| Inline choice bodies of a decider, prepended (in order) to `rest`.
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
            List.foldr (\( _, d ) acc -> deciderExprs d acc) (deciderExprs fallback rest) edges



-- ============================================================================
-- TYPE MAPPING
-- ============================================================================


{-| Apply a `MonoType -> MonoType` function to EVERY MonoType embedded anywhere
in a MonoNode. Total by construction over the AST (mirrors the shape of
`Analysis.collectCustomTypesFrom*`): every constructor field that is, contains,
or nests a MonoType is rewritten. Used by the quiescence closing pass to
discharge residual number vars across the whole reachable graph.
-}
mapNodeTypes : (MonoType -> MonoType) -> MonoNode -> MonoNode
mapNodeTypes f node =
    case node of
        Mono.MonoDefine expr t ->
            Mono.MonoDefine (mapExprTypes f expr) (f t)

        Mono.MonoTailFunc params expr t ->
            Mono.MonoTailFunc (List.map (\( n, pt ) -> ( n, f pt )) params) (mapExprTypes f expr) (f t)

        Mono.MonoCtor shape t ->
            Mono.MonoCtor (mapCtorShapeTypes f shape) (f t)

        Mono.MonoEnum i t ->
            Mono.MonoEnum i (f t)

        Mono.MonoExtern t ->
            Mono.MonoExtern (f t)

        Mono.MonoManagerLeaf s t ->
            Mono.MonoManagerLeaf s (f t)

        Mono.MonoPortIncoming expr t ->
            Mono.MonoPortIncoming (mapExprTypes f expr) (f t)

        Mono.MonoPortOutgoing expr t ->
            Mono.MonoPortOutgoing (mapExprTypes f expr) (f t)


mapCtorShapeTypes : (MonoType -> MonoType) -> CtorShape -> CtorShape
mapCtorShapeTypes f shape =
    { shape | fieldTypes = List.map f shape.fieldTypes }


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
            Mono.MonoTupleCreate r (List.map (mapExprTypes f) elems) (f t)

        Mono.MonoUnit ->
            Mono.MonoUnit

        Mono.MonoAccessorValue r n t ->
            Mono.MonoAccessorValue r n (f t)


mapClosureInfoTypes : (MonoType -> MonoType) -> ClosureInfo -> ClosureInfo
mapClosureInfoTypes f info =
    { info
        | captures = List.map (\( n, e, b ) -> ( n, mapExprTypes f e, b )) info.captures
        , params = List.map (\( n, t ) -> ( n, f t )) info.params
        , captureAbi = Maybe.map (mapCaptureAbiTypes f) info.captureAbi
    }


mapCallInfoTypes : (MonoType -> MonoType) -> CallInfo -> CallInfo
mapCallInfoTypes f info =
    { info
        | captureAbi = Maybe.map (mapCaptureAbiTypes f) info.captureAbi
        , evaluatorReturnType = f info.evaluatorReturnType
    }


mapCaptureAbiTypes : (MonoType -> MonoType) -> CaptureABI -> CaptureABI
mapCaptureAbiTypes f abi =
    { abi
        | captureTypes = List.map f abi.captureTypes
        , paramTypes = List.map f abi.paramTypes
        , returnType = f abi.returnType
    }


mapDefTypes : (MonoType -> MonoType) -> MonoDef -> MonoDef
mapDefTypes f def =
    case def of
        Mono.MonoDef n e ->
            Mono.MonoDef n (mapExprTypes f e)

        Mono.MonoTailDef n params e ->
            Mono.MonoTailDef n (List.map (\( nm, t ) -> ( nm, f t )) params) (mapExprTypes f e)


mapDestructorTypes : (MonoType -> MonoType) -> MonoDestructor -> MonoDestructor
mapDestructorTypes f (Mono.MonoDestructor n path t) =
    Mono.MonoDestructor n (mapPathTypes f path) (f t)


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


mapDtPathTypes : (MonoType -> MonoType) -> MonoDtPath -> MonoDtPath
mapDtPathTypes f path =
    case path of
        Mono.DtRoot n t ->
            Mono.DtRoot n (f t)

        Mono.DtIndex i ck t rest ->
            Mono.DtIndex i ck (f t) (mapDtPathTypes f rest)

        Mono.DtUnbox t rest ->
            Mono.DtUnbox (f t) (mapDtPathTypes f rest)


mapDeciderTypes : (MonoType -> MonoType) -> Decider MonoChoice -> Decider MonoChoice
mapDeciderTypes f decider =
    case decider of
        Mono.Leaf choice ->
            Mono.Leaf (mapChoiceTypes f choice)

        Mono.Chain tests ifDec elseDec ->
            Mono.Chain (List.map (\( p, test ) -> ( mapDtPathTypes f p, test )) tests) (mapDeciderTypes f ifDec) (mapDeciderTypes f elseDec)

        Mono.FanOut p edges fallback ->
            Mono.FanOut (mapDtPathTypes f p) (List.map (\( test, dec ) -> ( test, mapDeciderTypes f dec )) edges) (mapDeciderTypes f fallback)


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


{-| Does any MonoType embedded anywhere in this node satisfy `p`?

Short-circuits on the first hit (`||` is lazy), and the list walks are direct
tail recursion rather than `List.any (anyExprType p)` / `List.any (\x -> …)`,
each of which allocated a PAP or a closure per visited node with a list child.
The quiescence pass calls this over the whole reachable graph
(`if anyNodeType hasResidual n then mapNodeTypes close n else n`), so it is
the hottest member of this module.

-}
anyNodeType : (MonoType -> Bool) -> MonoNode -> Bool
anyNodeType p node =
    case node of
        Mono.MonoDefine expr t ->
            p t || anyExprType p expr

        Mono.MonoTailFunc params expr t ->
            p t || anyParamType p params || anyExprType p expr

        Mono.MonoCtor shape t ->
            p t || anyType p shape.fieldTypes

        Mono.MonoEnum _ t ->
            p t

        Mono.MonoExtern t ->
            p t

        Mono.MonoManagerLeaf _ t ->
            p t

        Mono.MonoPortIncoming expr t ->
            p t || anyExprType p expr

        Mono.MonoPortOutgoing expr t ->
            p t || anyExprType p expr


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
            p t || anyExprs p elems

        Mono.MonoUnit ->
            False

        Mono.MonoAccessorValue _ _ t ->
            p t


anyExprs : (MonoType -> Bool) -> List MonoExpr -> Bool
anyExprs p items =
    case items of
        [] ->
            False

        x :: xs ->
            anyExprType p x || anyExprs p xs


anyKeyed : (MonoType -> Bool) -> List ( k, MonoExpr ) -> Bool
anyKeyed p items =
    case items of
        [] ->
            False

        ( _, x ) :: xs ->
            anyExprType p x || anyKeyed p xs


anyCaptures : (MonoType -> Bool) -> List ( n, MonoExpr, a ) -> Bool
anyCaptures p items =
    case items of
        [] ->
            False

        ( _, x, _ ) :: xs ->
            anyExprType p x || anyCaptures p xs


anyBranches : (MonoType -> Bool) -> List ( MonoExpr, MonoExpr ) -> Bool
anyBranches p items =
    case items of
        [] ->
            False

        ( cond, then_ ) :: xs ->
            anyExprType p cond || anyExprType p then_ || anyBranches p xs


anyType : (MonoType -> Bool) -> List MonoType -> Bool
anyType p types =
    case types of
        [] ->
            False

        t :: rest ->
            p t || anyType p rest


anyParamType : (MonoType -> Bool) -> List ( n, MonoType ) -> Bool
anyParamType p params =
    case params of
        [] ->
            False

        ( _, t ) :: rest ->
            p t || anyParamType p rest


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


anyCallInfoType : (MonoType -> Bool) -> CallInfo -> Bool
anyCallInfoType p info =
    p info.evaluatorReturnType
        || (case info.captureAbi of
                Just abi ->
                    anyCaptureAbiType p abi

                Nothing ->
                    False
           )


anyCaptureAbiType : (MonoType -> Bool) -> CaptureABI -> Bool
anyCaptureAbiType p abi =
    anyType p abi.captureTypes || anyType p abi.paramTypes || p abi.returnType


anyDefType : (MonoType -> Bool) -> MonoDef -> Bool
anyDefType p def =
    case def of
        Mono.MonoDef _ e ->
            anyExprType p e

        Mono.MonoTailDef _ params e ->
            anyParamType p params || anyExprType p e


anyDestructorType : (MonoType -> Bool) -> MonoDestructor -> Bool
anyDestructorType p (Mono.MonoDestructor _ path t) =
    p t || anyPathType p path


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


anyDtPathType : (MonoType -> Bool) -> MonoDtPath -> Bool
anyDtPathType p path =
    case path of
        Mono.DtRoot _ t ->
            p t

        Mono.DtIndex _ _ t rest ->
            p t || anyDtPathType p rest

        Mono.DtUnbox t rest ->
            p t || anyDtPathType p rest


anyDeciderType : (MonoType -> Bool) -> Decider MonoChoice -> Bool
anyDeciderType p decider =
    case decider of
        Mono.Leaf choice ->
            anyChoiceType p choice

        Mono.Chain tests ifDec elseDec ->
            anyTests p tests || anyDeciderType p ifDec || anyDeciderType p elseDec

        Mono.FanOut pth edges fallback ->
            anyDtPathType p pth || anyEdges p edges || anyDeciderType p fallback


anyTests : (MonoType -> Bool) -> List ( MonoDtPath, a ) -> Bool
anyTests p tests =
    case tests of
        [] ->
            False

        ( pth, _ ) :: rest ->
            anyDtPathType p pth || anyTests p rest


anyEdges : (MonoType -> Bool) -> List ( a, Decider MonoChoice ) -> Bool
anyEdges p edges =
    case edges of
        [] ->
            False

        ( _, d ) :: rest ->
            anyDeciderType p d || anyEdges p rest


anyChoiceType : (MonoType -> Bool) -> MonoChoice -> Bool
anyChoiceType p choice =
    case choice of
        Mono.Inline e ->
            anyExprType p e

        Mono.Jump _ ->
            False
