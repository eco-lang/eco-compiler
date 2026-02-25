module Compiler.GlobalOpt.MonoTraverse exposing
    ( traverseExpr
    , foldExpr
    )

{-| Generic AST traversal abstractions for MonoExpr.

This module provides three core traversal patterns:

  - **mapExpr** - Pure transformation (bottom-up)
  - **traverseExpr** - Context-threaded transformation (bottom-up)
  - **foldExpr** - Pure fold/analysis (bottom-up)

Each function handles structural recursion, calling the user-provided
function on each node after processing children.


# Pure Mapping


# Context-Threaded Traversal

@docs traverseExpr


# Fold

@docs foldExpr

-}

import Compiler.AST.Monomorphized exposing (Decider(..), MonoChoice(..), MonoDef(..), MonoExpr(..))



-- ============================================================================
-- ====== PURE MAPPING (BOTTOM-UP) ======
-- ============================================================================


{-| Pure transformation over expressions. Applies the function bottom-up
(children are transformed before the parent).
-}
mapExpr : (MonoExpr -> MonoExpr) -> MonoExpr -> MonoExpr
mapExpr f expr =
    f (mapExprChildren (mapExpr f) expr)


{-| Map over definitions.
-}
mapDef : (MonoExpr -> MonoExpr) -> MonoDef -> MonoDef
mapDef f def =
    case def of
        MonoDef name bound ->
            MonoDef name (mapExpr f bound)

        MonoTailDef name params bound ->
            MonoTailDef name params (mapExpr f bound)


{-| Map over deciders.
-}
mapDecider : (MonoExpr -> MonoExpr) -> Decider MonoChoice -> Decider MonoChoice
mapDecider f decider =
    case decider of
        Leaf choice ->
            Leaf (mapChoice f choice)

        Chain test success failure ->
            Chain test
                (mapDecider f success)
                (mapDecider f failure)

        FanOut path edges fallback ->
            FanOut path
                (List.map (\( test, d ) -> ( test, mapDecider f d )) edges)
                (mapDecider f fallback)


{-| Map over choices.
-}
mapChoice : (MonoExpr -> MonoExpr) -> MonoChoice -> MonoChoice
mapChoice f choice =
    case choice of
        Inline e ->
            Inline (mapExpr f e)

        Jump i ->
            Jump i



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
                ( newEdges, ctx1 ) =
                    List.foldl
                        (\( test, d ) ( acc, c ) ->
                            let
                                ( newD, c1 ) =
                                    traverseDecider f c d
                            in
                            ( acc ++ [ ( test, newD ) ], c1 )
                        )
                        ( [], ctx )
                        edges

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
foldExpr f acc expr =
    let
        childAcc =
            foldExprChildren (foldExpr f) acc expr
    in
    f expr childAcc


{-| Fold over definitions.
-}
foldDef : (MonoExpr -> acc -> acc) -> acc -> MonoDef -> acc
foldDef f acc def =
    case def of
        MonoDef _ bound ->
            foldExpr f acc bound

        MonoTailDef _ _ bound ->
            foldExpr f acc bound


{-| Fold over deciders.
-}
foldDecider : (MonoExpr -> acc -> acc) -> acc -> Decider MonoChoice -> acc
foldDecider f acc decider =
    case decider of
        Leaf choice ->
            foldChoice f acc choice

        Chain _ success failure ->
            let
                acc1 =
                    foldDecider f acc success
            in
            foldDecider f acc1 failure

        FanOut _ edges fallback ->
            let
                acc1 =
                    List.foldl (\( _, d ) a -> foldDecider f a d) acc edges
            in
            foldDecider f acc1 fallback


{-| Fold over choices.
-}
foldChoice : (MonoExpr -> acc -> acc) -> acc -> MonoChoice -> acc
foldChoice f acc choice =
    case choice of
        Inline e ->
            foldExpr f acc e

        Jump _ ->
            acc



-- ============================================================================
-- ====== INTERNAL HELPERS ======
-- ============================================================================


{-| Map over direct children of an expression (one level only).
-}
mapExprChildren : (MonoExpr -> MonoExpr) -> MonoExpr -> MonoExpr
mapExprChildren f expr =
    case expr of
        MonoClosure info body closureType ->
            let
                newCaptures =
                    List.map (\( n, e, t ) -> ( n, f e, t )) info.captures
            in
            MonoClosure { info | captures = newCaptures } (f body) closureType

        MonoCall region func args resultType callInfo ->
            MonoCall region (f func) (List.map f args) resultType callInfo

        MonoTailCall name args resultType ->
            MonoTailCall name (List.map (\( n, e ) -> ( n, f e )) args) resultType

        MonoIf branches final resultType ->
            MonoIf
                (List.map (\( c, t ) -> ( f c, f t )) branches)
                (f final)
                resultType

        MonoLet def body resultType ->
            MonoLet (mapDef f def) (f body) resultType

        MonoDestruct path inner resultType ->
            MonoDestruct path (f inner) resultType

        MonoCase label scrutinee decider jumps resultType ->
            MonoCase label
                scrutinee
                (mapDecider f decider)
                (List.map (\( i, e ) -> ( i, f e )) jumps)
                resultType

        MonoList region items resultType ->
            MonoList region (List.map f items) resultType

        MonoRecordCreate fields resultType ->
            MonoRecordCreate (List.map (\( n, e ) -> ( n, f e )) fields) resultType

        MonoRecordAccess inner field resultType ->
            MonoRecordAccess (f inner) field resultType

        MonoRecordUpdate record updates resultType ->
            MonoRecordUpdate (f record) (List.map (\( n, e ) -> ( n, f e )) updates) resultType

        MonoTupleCreate region elements resultType ->
            MonoTupleCreate region (List.map f elements) resultType

        -- Leaf expressions - no children
        MonoLiteral _ _ ->
            expr

        MonoVarLocal _ _ ->
            expr

        MonoVarGlobal _ _ _ ->
            expr

        MonoVarKernel _ _ _ _ ->
            expr

        MonoUnit ->
            expr


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

        MonoVarKernel _ _ _ _ ->
            ( expr, ctx )

        MonoUnit ->
            ( expr, ctx )


{-| Fold over direct children of an expression.
-}
foldExprChildren : (acc -> MonoExpr -> acc) -> acc -> MonoExpr -> acc
foldExprChildren f acc expr =
    -- Note: f has arguments (acc, expr) but foldDef/foldDecider expect (expr, acc)
    -- so we flip when calling those
    let
        flipped =
            \e a -> f a e
    in
    case expr of
        MonoClosure info body _ ->
            let
                captureAcc =
                    List.foldl (\( _, e, _ ) a -> f a e) acc info.captures
            in
            f captureAcc body

        MonoCall _ func args _ _ ->
            let
                funcAcc =
                    f acc func
            in
            List.foldl (\e a -> f a e) funcAcc args

        MonoTailCall _ args _ ->
            List.foldl (\( _, e ) a -> f a e) acc args

        MonoIf branches final _ ->
            let
                branchAcc =
                    List.foldl (\( c, t ) a -> f (f a c) t) acc branches
            in
            f branchAcc final

        MonoLet def body _ ->
            let
                defAcc =
                    foldDef flipped acc def
            in
            f defAcc body

        MonoDestruct _ inner _ ->
            f acc inner

        MonoCase _ _ decider jumps _ ->
            let
                deciderAcc =
                    foldDecider flipped acc decider
            in
            List.foldl (\( _, e ) a -> f a e) deciderAcc jumps

        MonoList _ items _ ->
            List.foldl (\e a -> f a e) acc items

        MonoRecordCreate fields _ ->
            List.foldl (\( _, e ) a -> f a e) acc fields

        MonoRecordAccess inner _ _ ->
            f acc inner

        MonoRecordUpdate record updates _ ->
            let
                recAcc =
                    f acc record
            in
            List.foldl (\( _, e ) a -> f a e) recAcc updates

        MonoTupleCreate _ elements _ ->
            List.foldl (\e a -> f a e) acc elements

        -- Leaf expressions - no children
        MonoLiteral _ _ ->
            acc

        MonoVarLocal _ _ ->
            acc

        MonoVarGlobal _ _ _ ->
            acc

        MonoVarKernel _ _ _ _ ->
            acc

        MonoUnit ->
            acc


{-| Helper for threading context through a list.
-}
traverseList : (ctx -> a -> ( b, ctx )) -> ctx -> List a -> ( List b, ctx )
traverseList f ctx list =
    List.foldl
        (\item ( acc, c ) ->
            let
                ( newItem, c1 ) =
                    f c item
            in
            ( acc ++ [ newItem ], c1 )
        )
        ( [], ctx )
        list
