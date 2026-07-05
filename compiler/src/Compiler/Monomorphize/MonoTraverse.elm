module Compiler.Monomorphize.MonoTraverse exposing
    ( traverseExpr
    , foldExpr
    , mapNodeTypes
    , anyNodeType
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


# Type Mapping

@docs mapNodeTypes, anyNodeType

-}

import Compiler.AST.Monomorphized as Mono exposing (CallInfo, CaptureABI, ClosureInfo, CtorShape, Decider(..), MonoChoice(..), MonoDef(..), MonoDestructor(..), MonoDtPath(..), MonoExpr(..), MonoNode(..), MonoPath(..), MonoType)



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
-- TYPE-POSITION PREDICATE (gate for the closing pass)
-- ============================================================================


{-| Does any MonoType embedded anywhere in the node satisfy `p`? Mirrors
`mapNodeTypes` position-for-position (coverage MUST match, or the closing pass
would skip a node that still carries a residual) but is a zero-allocation
short-circuiting `||` fold instead of a rebuild. Used to gate `mapNodeTypes`:
`if anyNodeType hasResidual n then mapNodeTypes close n else n`.
-}
anyNodeType : (MonoType -> Bool) -> MonoNode -> Bool
anyNodeType p node =
    case node of
        Mono.MonoDefine expr t ->
            p t || anyExprType p expr

        Mono.MonoTailFunc params expr t ->
            p t || List.any (\( _, pt ) -> p pt) params || anyExprType p expr

        Mono.MonoCtor shape t ->
            p t || List.any p shape.fieldTypes

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
            p t || List.any (anyExprType p) elems

        Mono.MonoClosure info body t ->
            p t || anyClosureInfoType p info || anyExprType p body

        Mono.MonoCall _ fn args t info ->
            p t || anyExprType p fn || List.any (anyExprType p) args || anyCallInfoType p info

        Mono.MonoTailCall _ args t ->
            p t || List.any (\( _, e ) -> anyExprType p e) args

        Mono.MonoIf branches elseExpr t ->
            p t || List.any (\( c, e ) -> anyExprType p c || anyExprType p e) branches || anyExprType p elseExpr

        Mono.MonoLet def body t ->
            p t || anyDefType p def || anyExprType p body

        Mono.MonoDestruct destructor body t ->
            p t || anyDestructorType p destructor || anyExprType p body

        Mono.MonoCase _ _ decider jumps t ->
            p t || anyDeciderType p decider || List.any (\( _, e ) -> anyExprType p e) jumps

        Mono.MonoRecordCreate fields t ->
            p t || List.any (\( _, e ) -> anyExprType p e) fields

        Mono.MonoRecordAccess e _ t ->
            p t || anyExprType p e

        Mono.MonoRecordUpdate e fields t ->
            p t || anyExprType p e || List.any (\( _, fe ) -> anyExprType p fe) fields

        Mono.MonoTupleCreate _ elems t ->
            p t || List.any (anyExprType p) elems

        Mono.MonoUnit ->
            False

        Mono.MonoAccessorValue _ _ t ->
            p t


anyClosureInfoType : (MonoType -> Bool) -> ClosureInfo -> Bool
anyClosureInfoType p info =
    List.any (\( _, e, _ ) -> anyExprType p e) info.captures
        || List.any (\( _, t ) -> p t) info.params
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
    List.any p abi.captureTypes || List.any p abi.paramTypes || p abi.returnType


anyDefType : (MonoType -> Bool) -> MonoDef -> Bool
anyDefType p def =
    case def of
        Mono.MonoDef _ e ->
            anyExprType p e

        Mono.MonoTailDef _ params e ->
            List.any (\( _, t ) -> p t) params || anyExprType p e


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
            List.any (\( pth, _ ) -> anyDtPathType p pth) tests || anyDeciderType p ifDec || anyDeciderType p elseDec

        Mono.FanOut pth edges fallback ->
            anyDtPathType p pth || List.any (\( _, dec ) -> anyDeciderType p dec) edges || anyDeciderType p fallback


anyChoiceType : (MonoType -> Bool) -> MonoChoice -> Bool
anyChoiceType p choice =
    case choice of
        Mono.Inline e ->
            anyExprType p e

        Mono.Jump _ ->
            False
