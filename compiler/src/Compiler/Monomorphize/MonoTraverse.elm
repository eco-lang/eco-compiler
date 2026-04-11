module Compiler.Monomorphize.MonoTraverse exposing
    ( traverseExpr
    , foldExpr
    )

{-| Generic AST traversal abstractions for MonoExpr.

This module provides two core traversal patterns:

  - **traverseExpr** - Context-threaded transformation (bottom-up)
  - **foldExpr** - Pure fold/analysis (bottom-up)

Each function handles structural recursion, calling the user-provided
function on each node after processing children.


# Context-Threaded Traversal

@docs traverseExpr


# Fold

@docs foldExpr

-}

import Compiler.AST.Monomorphized exposing (Decider(..), MonoChoice(..), MonoDef(..), MonoExpr(..))



-- ============================================================================
-- ====== CONTEXT-THREADED TRAVERSAL (BOTTOM-UP) ======
-- ============================================================================


{-| Context-threaded transformation over expressions.
The context is threaded through in evaluation order (left to right).
Transformation is applied bottom-up (children first).
-}
traverseExpr : (ctx -> MonoExpr -> ( MonoExpr, ctx )) -> ctx -> MonoExpr -> ( MonoExpr, ctx )
traverseExpr f ctx expr =
    let
        ( mapped, ctx1 ) =
            traverseExprChildren (traverseExpr f) ctx expr
    in
    f ctx1 mapped


{-| Traverse definitions with context.
-}
traverseDef : (ctx -> MonoExpr -> ( MonoExpr, ctx )) -> ctx -> MonoDef -> ( MonoDef, ctx )
traverseDef f ctx def =
    case def of
        MonoDef name bound ->
            let
                ( newBound, ctx1 ) =
                    traverseExpr f ctx bound
            in
            ( MonoDef name newBound, ctx1 )

        MonoTailDef name params bound ->
            let
                ( newBound, ctx1 ) =
                    traverseExpr f ctx bound
            in
            ( MonoTailDef name params newBound, ctx1 )


{-| Traverse deciders with context.
-}
traverseDecider : (ctx -> MonoExpr -> ( MonoExpr, ctx )) -> ctx -> Decider MonoChoice -> ( Decider MonoChoice, ctx )
traverseDecider f ctx decider =
    case decider of
        Leaf choice ->
            let
                ( newChoice, ctx1 ) =
                    traverseChoice f ctx choice
            in
            ( Leaf newChoice, ctx1 )

        Chain test success failure ->
            let
                ( newSuccess, ctx1 ) =
                    traverseDecider f ctx success

                ( newFailure, ctx2 ) =
                    traverseDecider f ctx1 failure
            in
            ( Chain test newSuccess newFailure, ctx2 )

        FanOut path edges fallback ->
            let
                ( newEdgesRev, ctx1 ) =
                    List.foldl
                        (\( test, d ) ( acc, c ) ->
                            let
                                ( newD, c1 ) =
                                    traverseDecider f c d
                            in
                            ( ( test, newD ) :: acc, c1 )
                        )
                        ( [], ctx )
                        edges

                newEdges =
                    List.reverse newEdgesRev

                ( newFallback, ctx2 ) =
                    traverseDecider f ctx1 fallback
            in
            ( FanOut path newEdges newFallback, ctx2 )


{-| Traverse choices with context.
-}
traverseChoice : (ctx -> MonoExpr -> ( MonoExpr, ctx )) -> ctx -> MonoChoice -> ( MonoChoice, ctx )
traverseChoice f ctx choice =
    case choice of
        Inline e ->
            let
                ( newE, ctx1 ) =
                    traverseExpr f ctx e
            in
            ( Inline newE, ctx1 )

        Jump i ->
            ( Jump i, ctx )



-- ============================================================================
-- ====== PURE FOLD (BOTTOM-UP) ======
-- ============================================================================


{-| Pure fold over expressions. Accumulates bottom-up
(children are folded before the parent).
-}
foldExpr : (MonoExpr -> acc -> acc) -> acc -> MonoExpr -> acc
foldExpr f =
    -- Flip the callback once here, then use acc-first internally
    let
        accFirst =
            \a e -> f e a
    in
    foldExprAccFirst accFirst


{-| Acc-first fold over expressions (internal). Avoids per-call flip overhead.
Uses direct recursion instead of passing a PAP to foldExprChildren, so each
recursive call is a direct A3 call rather than PAP resolution.
-}
foldExprAccFirst : (acc -> MonoExpr -> acc) -> acc -> MonoExpr -> acc
foldExprAccFirst f acc expr =
    f (foldExprAccFirstChildren f acc expr) expr


{-| Fold over direct children, recursing via foldExprAccFirst directly.
This avoids creating a PAP (foldExprAccFirst f) that would need resolution
on every recursive call.
-}
foldExprAccFirstChildren : (acc -> MonoExpr -> acc) -> acc -> MonoExpr -> acc
foldExprAccFirstChildren f acc expr =
    case expr of
        MonoClosure info body _ ->
            let
                captureAcc =
                    List.foldl (\( _, e, _ ) a -> foldExprAccFirst f a e) acc info.captures
            in
            foldExprAccFirst f captureAcc body

        MonoCall _ func args _ _ ->
            List.foldl (\e a -> foldExprAccFirst f a e) (foldExprAccFirst f acc func) args

        MonoTailCall _ args _ ->
            List.foldl (\( _, e ) a -> foldExprAccFirst f a e) acc args

        MonoIf branches final _ ->
            let
                branchAcc =
                    List.foldl (\( c, t ) a -> foldExprAccFirst f (foldExprAccFirst f a c) t) acc branches
            in
            foldExprAccFirst f branchAcc final

        MonoLet def body _ ->
            let
                defAcc =
                    foldDefAccFirst f acc def
            in
            foldExprAccFirst f defAcc body

        MonoDestruct _ inner _ ->
            foldExprAccFirst f acc inner

        MonoCase _ _ decider jumps _ ->
            let
                deciderAcc =
                    foldDeciderAccFirst f acc decider
            in
            List.foldl (\( _, e ) a -> foldExprAccFirst f a e) deciderAcc jumps

        MonoList _ items _ ->
            List.foldl (\e a -> foldExprAccFirst f a e) acc items

        MonoRecordCreate fields _ ->
            List.foldl (\( _, e ) a -> foldExprAccFirst f a e) acc fields

        MonoRecordAccess inner _ _ ->
            foldExprAccFirst f acc inner

        MonoRecordUpdate record updates _ ->
            List.foldl (\( _, e ) a -> foldExprAccFirst f a e) (foldExprAccFirst f acc record) updates

        MonoTupleCreate _ elements _ ->
            List.foldl (\e a -> foldExprAccFirst f a e) acc elements

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


{-| Acc-first fold over definitions (internal).
-}
foldDefAccFirst : (acc -> MonoExpr -> acc) -> acc -> MonoDef -> acc
foldDefAccFirst f acc def =
    case def of
        MonoDef _ bound ->
            foldExprAccFirst f acc bound

        MonoTailDef _ _ bound ->
            foldExprAccFirst f acc bound


{-| Acc-first fold over deciders (internal).
-}
foldDeciderAccFirst : (acc -> MonoExpr -> acc) -> acc -> Decider MonoChoice -> acc
foldDeciderAccFirst f acc decider =
    case decider of
        Leaf choice ->
            foldChoiceAccFirst f acc choice

        Chain _ success failure ->
            let
                acc1 =
                    foldDeciderAccFirst f acc success
            in
            foldDeciderAccFirst f acc1 failure

        FanOut _ edges fallback ->
            let
                acc1 =
                    List.foldl (\( _, d ) a -> foldDeciderAccFirst f a d) acc edges
            in
            foldDeciderAccFirst f acc1 fallback


{-| Acc-first fold over choices (internal).
-}
foldChoiceAccFirst : (acc -> MonoExpr -> acc) -> acc -> MonoChoice -> acc
foldChoiceAccFirst f acc choice =
    case choice of
        Inline e ->
            foldExprAccFirst f acc e

        Jump _ ->
            acc



-- ============================================================================
-- ====== INTERNAL HELPERS ======
-- ============================================================================


{-| Traverse direct children with context threading.
-}
traverseExprChildren : (ctx -> MonoExpr -> ( MonoExpr, ctx )) -> ctx -> MonoExpr -> ( MonoExpr, ctx )
traverseExprChildren f ctx expr =
    case expr of
        MonoClosure info body closureType ->
            let
                ( newCaptures, ctx1 ) =
                    traverseList
                        (\c ( n, e, t ) ->
                            let
                                ( e1, c1 ) =
                                    f c e
                            in
                            ( ( n, e1, t ), c1 )
                        )
                        ctx
                        info.captures

                ( newBody, ctx2 ) =
                    f ctx1 body
            in
            ( MonoClosure { info | captures = newCaptures } newBody closureType, ctx2 )

        MonoCall region func args resultType callInfo ->
            let
                ( newFunc, ctx1 ) =
                    f ctx func

                ( newArgs, ctx2 ) =
                    traverseList f ctx1 args
            in
            ( MonoCall region newFunc newArgs resultType callInfo, ctx2 )

        MonoTailCall name args resultType ->
            let
                ( newArgs, ctx1 ) =
                    traverseList
                        (\c ( n, e ) ->
                            let
                                ( e1, c1 ) =
                                    f c e
                            in
                            ( ( n, e1 ), c1 )
                        )
                        ctx
                        args
            in
            ( MonoTailCall name newArgs resultType, ctx1 )

        MonoIf branches final resultType ->
            let
                ( newBranches, ctx1 ) =
                    traverseList
                        (\c ( cond, then_ ) ->
                            let
                                ( newCond, c1 ) =
                                    f c cond

                                ( newThen, c2 ) =
                                    f c1 then_
                            in
                            ( ( newCond, newThen ), c2 )
                        )
                        ctx
                        branches

                ( newFinal, ctx2 ) =
                    f ctx1 final
            in
            ( MonoIf newBranches newFinal resultType, ctx2 )

        MonoLet def body resultType ->
            let
                ( newDef, ctx1 ) =
                    traverseDef f ctx def

                ( newBody, ctx2 ) =
                    f ctx1 body
            in
            ( MonoLet newDef newBody resultType, ctx2 )

        MonoDestruct path inner resultType ->
            let
                ( newInner, ctx1 ) =
                    f ctx inner
            in
            ( MonoDestruct path newInner resultType, ctx1 )

        MonoCase label scrutinee decider jumps resultType ->
            let
                ( newDecider, ctx1 ) =
                    traverseDecider f ctx decider

                ( newJumps, ctx2 ) =
                    traverseList
                        (\c ( i, e ) ->
                            let
                                ( e1, c1 ) =
                                    f c e
                            in
                            ( ( i, e1 ), c1 )
                        )
                        ctx1
                        jumps
            in
            ( MonoCase label scrutinee newDecider newJumps resultType, ctx2 )

        MonoList region items resultType ->
            let
                ( newItems, ctx1 ) =
                    traverseList f ctx items
            in
            ( MonoList region newItems resultType, ctx1 )

        MonoRecordCreate fields resultType ->
            let
                ( newFields, ctx1 ) =
                    traverseList
                        (\c ( n, e ) ->
                            let
                                ( e1, c1 ) =
                                    f c e
                            in
                            ( ( n, e1 ), c1 )
                        )
                        ctx
                        fields
            in
            ( MonoRecordCreate newFields resultType, ctx1 )

        MonoRecordAccess inner field resultType ->
            let
                ( newInner, ctx1 ) =
                    f ctx inner
            in
            ( MonoRecordAccess newInner field resultType, ctx1 )

        MonoRecordUpdate record updates resultType ->
            let
                ( newRecord, ctx1 ) =
                    f ctx record

                ( newUpdates, ctx2 ) =
                    traverseList
                        (\c ( n, e ) ->
                            let
                                ( e1, c1 ) =
                                    f c e
                            in
                            ( ( n, e1 ), c1 )
                        )
                        ctx1
                        updates
            in
            ( MonoRecordUpdate newRecord newUpdates resultType, ctx2 )

        MonoTupleCreate region elements resultType ->
            let
                ( newElements, ctx1 ) =
                    traverseList f ctx elements
            in
            ( MonoTupleCreate region newElements resultType, ctx1 )

        -- Leaf expressions - no children
        MonoLiteral _ _ ->
            ( expr, ctx )

        MonoVarLocal _ _ ->
            ( expr, ctx )

        MonoVarGlobal _ _ _ ->
            ( expr, ctx )

        MonoVarKernel _ _ _ _ _ ->
            ( expr, ctx )

        MonoUnit ->
            ( expr, ctx )

        MonoAccessorValue _ _ _ ->
            ( expr, ctx )


{-| Helper for threading context through a list.
-}
traverseList : (ctx -> a -> ( b, ctx )) -> ctx -> List a -> ( List b, ctx )
traverseList f ctx list =
    let
        ( revAcc, finalCtx ) =
            List.foldl
                (\item ( acc, c ) ->
                    let
                        ( newItem, c1 ) =
                            f c item
                    in
                    ( newItem :: acc, c1 )
                )
                ( [], ctx )
                list
    in
    ( List.reverse revAcc, finalCtx )
