module Compiler.Monomorphize.ResolveAccessorValues exposing (accessorTypeNeedsDefer, rewriteNode)

{-| Eliminates MonoAccessorValue nodes from monomorphized expressions.

Two tiers of elimination are applied sequentially:

1.  **Data-flow analysis** — forward intraprocedural analysis that tracks which locals
    are definitely accessor values, enabling call-site elimination.

2.  **Closure fallback** — any surviving MonoAccessorValue is replaced with a closure
    `\record -> record.field`, guaranteeing all accessor values have concrete
    implementations.

After both tiers, no MonoAccessorValue remains (MONO\_027).

@docs accessorTypeNeedsDefer, rewriteNode

-}

import Compiler.AST.Monomorphized as Mono
    exposing
        ( Decider(..)
        , MonoChoice(..)
        , MonoDef(..)
        , MonoExpr(..)
        , MonoType(..)
        )
import Dict exposing (Dict)
import System.TypeCheck.IO as IO



-- ============================================================================
-- ====== PUBLIC API ======
-- ============================================================================


{-| Check whether an accessor's MonoType needs to be deferred via MonoAccessorValue
rather than creating an immediate Mono.Accessor virtual global.

Defer when:

  - The first parameter is not MRecord (row variable unresolved)
  - The result type is a function (accessor extracts a function-typed field, which
    causes arity mismatch: specializeAccessorGlobal creates a 1-param TailFunc but
    the flattened type arity would be > 1)

-}
accessorTypeNeedsDefer : MonoType -> Bool
accessorTypeNeedsDefer monoType =
    case monoType of
        MFunction _ ((MRecord _) :: _) resultType ->
            case resultType of
                MFunction _ _ _ ->
                    True

                _ ->
                    False

        _ ->
            True


{-| Rewrite an expression body to eliminate all MonoAccessorValue nodes.
Applies data-flow analysis with context-rooted closure fallback.
Returns ( rewrittenExpr, updatedLambdaCounter ).
-}
rewriteExprBody : IO.Canonical -> Int -> Maybe MonoType -> MonoExpr -> ( MonoExpr, Int )
rewriteExprBody home lambdaCounter maybeExpectedType expr =
    let
        ( afterDataFlow, _, finalCounter ) =
            rewriteExpr home lambdaCounter Dict.empty maybeExpectedType expr
    in
    ( afterDataFlow, finalCounter )


{-| Rewrite a MonoNode's body expression(s) to eliminate MonoAccessorValue.
Nodes without expression bodies (MonoCtor, MonoEnum, MonoExtern, MonoManagerLeaf)
are returned unchanged.
-}
rewriteNode : IO.Canonical -> Int -> Mono.MonoNode -> ( Mono.MonoNode, Int )
rewriteNode home lambdaCounter node =
    case node of
        Mono.MonoDefine expr monoType ->
            let
                ( expr1, c1 ) =
                    rewriteExprBody home lambdaCounter (Just monoType) expr
            in
            ( Mono.MonoDefine expr1 monoType, c1 )

        Mono.MonoTailFunc params expr monoType ->
            let
                bodyExpectedType =
                    Just (Mono.resultTypeOf monoType)

                ( expr1, c1 ) =
                    rewriteExprBody home lambdaCounter bodyExpectedType expr
            in
            ( Mono.MonoTailFunc params expr1 monoType, c1 )

        Mono.MonoCtor _ _ ->
            ( node, lambdaCounter )

        Mono.MonoEnum _ _ ->
            ( node, lambdaCounter )

        Mono.MonoExtern _ ->
            ( node, lambdaCounter )

        Mono.MonoManagerLeaf _ _ ->
            ( node, lambdaCounter )

        Mono.MonoPortIncoming expr monoType ->
            let
                ( expr1, c1 ) =
                    rewriteExprBody home lambdaCounter (Just monoType) expr
            in
            ( Mono.MonoPortIncoming expr1 monoType, c1 )

        Mono.MonoPortOutgoing expr monoType ->
            let
                ( expr1, c1 ) =
                    rewriteExprBody home lambdaCounter (Just monoType) expr
            in
            ( Mono.MonoPortOutgoing expr1 monoType, c1 )



-- ============================================================================
-- ====== DATA-FLOW ANALYSIS WITH CONTEXT-ROOTED CLOSURE FALLBACK ==
-- ============================================================================


type AccessorOrigin
    = AO_Field String


type ValueInfo
    = VI_Unknown
    | VI_Accessor AccessorOrigin
    | VI_Record (Dict String ValueInfo)


type alias Env =
    Dict String ValueInfo


joinValueInfo : ValueInfo -> ValueInfo -> ValueInfo
joinValueInfo v1 v2 =
    case ( v1, v2 ) of
        ( VI_Unknown, v ) ->
            v

        ( v, VI_Unknown ) ->
            v

        ( VI_Accessor (AO_Field f1), VI_Accessor (AO_Field f2) ) ->
            if f1 == f2 then
                v1

            else
                VI_Unknown

        ( VI_Record r1, VI_Record r2 ) ->
            let
                joined =
                    Dict.foldl
                        (\name v1Field accDict ->
                            case Dict.get name r2 of
                                Just v2Field ->
                                    case joinValueInfo v1Field v2Field of
                                        VI_Unknown ->
                                            accDict

                                        j ->
                                            Dict.insert name j accDict

                                Nothing ->
                                    accDict
                        )
                        Dict.empty
                        r1
            in
            if Dict.isEmpty joined then
                VI_Unknown

            else
                VI_Record joined

        _ ->
            VI_Unknown


{-| Check if an expected type is a fully concrete accessor signature.
Returns Just (recordType, fieldType) if the type is MFunction [MRecord fields] fieldType
where neither fields nor fieldType contain any MVar.
-}
maybeAccessorSigFromExpected : MonoType -> Maybe ( MonoType, MonoType )
maybeAccessorSigFromExpected expectedType =
    case expectedType of
        MFunction _ ((MRecord fields) :: []) fieldType ->
            if not (Mono.containsAnyMVar (MRecord fields)) && not (Mono.containsAnyMVar fieldType) then
                Just ( MRecord fields, fieldType )

            else
                Nothing

        _ ->
            Nothing


{-| Build a closure fallback from a fully concrete expected type.
-}
buildAccessorClosure : IO.Canonical -> Int -> String -> MonoType -> MonoType -> MonoType -> ( MonoExpr, Int )
buildAccessorClosure home counter fieldName recordType fieldType expectedType =
    let
        lambdaId =
            Mono.AnonymousLambda home counter

        closureInfo =
            { lambdaId = lambdaId
            , srcLambda = Nothing
            , captures = []
            , params = [ ( "record", recordType ) ]
            , closureKind = Nothing
            , captureAbi = Nothing
            }

        closureBody =
            MonoRecordAccess
                (MonoVarLocal "record" recordType)
                fieldName
                fieldType
    in
    ( MonoClosure closureInfo closureBody expectedType
    , counter + 1
    )


{-| Forward data-flow analysis with context-rooted closure fallback.
Threads IO.Canonical and lambda counter for closure generation.
-}
rewriteExpr : IO.Canonical -> Int -> Env -> Maybe MonoType -> MonoExpr -> ( MonoExpr, ValueInfo, Int )
rewriteExpr home counter env maybeExpected expr =
    case expr of
        MonoAccessorValue _ fieldName _ ->
            -- Tier 3: try context-rooted closure fallback
            case maybeExpected of
                Just expectedType ->
                    case maybeAccessorSigFromExpected expectedType of
                        Just ( recordType, fieldType ) ->
                            let
                                ( closure, newCounter ) =
                                    buildAccessorClosure home counter fieldName recordType fieldType expectedType
                            in
                            ( closure, VI_Accessor (AO_Field fieldName), newCounter )

                        Nothing ->
                            -- Expected type not a safe accessor sig; leave as-is
                            ( expr, VI_Accessor (AO_Field fieldName), counter )

                Nothing ->
                    ( expr, VI_Accessor (AO_Field fieldName), counter )

        MonoVarLocal name _ ->
            ( expr, Maybe.withDefault VI_Unknown (Dict.get name env), counter )

        MonoLiteral _ _ ->
            ( expr, VI_Unknown, counter )

        MonoVarGlobal _ _ _ ->
            ( expr, VI_Unknown, counter )

        MonoVarKernel _ _ _ _ _ ->
            ( expr, VI_Unknown, counter )

        MonoUnit ->
            ( expr, VI_Unknown, counter )

        MonoRecordCreate namedFields monoType ->
            let
                fieldTypes =
                    case monoType of
                        MRecord ft ->
                            ft

                        _ ->
                            Dict.empty

                ( newFieldsRev, fieldInfos, c1 ) =
                    List.foldl
                        (\( name, fieldExpr ) ( accFields, accInfos, c ) ->
                            let
                                fieldExpected =
                                    Dict.get name fieldTypes

                                ( fieldExpr1, fieldInfo, c2 ) =
                                    rewriteExpr home c env fieldExpected fieldExpr
                            in
                            ( ( name, fieldExpr1 ) :: accFields
                            , Dict.insert name fieldInfo accInfos
                            , c2
                            )
                        )
                        ( [], Dict.empty, counter )
                        namedFields
            in
            ( MonoRecordCreate (List.reverse newFieldsRev) monoType
            , VI_Record fieldInfos
            , c1
            )

        MonoRecordAccess recordExpr fieldName fieldType ->
            let
                ( recordExpr1, recordInfo, c1 ) =
                    rewriteExpr home counter env Nothing recordExpr

                valueInfo =
                    case recordInfo of
                        VI_Record fields ->
                            Maybe.withDefault VI_Unknown (Dict.get fieldName fields)

                        _ ->
                            VI_Unknown
            in
            ( MonoRecordAccess recordExpr1 fieldName fieldType
            , valueInfo
            , c1
            )

        MonoRecordUpdate recordExpr updates monoType ->
            let
                ( recordExpr1, _, c1 ) =
                    rewriteExpr home counter env Nothing recordExpr

                ( newUpdatesRev, c2 ) =
                    List.foldl
                        (\( n, e ) ( acc, c ) ->
                            let
                                ( e1, _, c3 ) =
                                    rewriteExpr home c env Nothing e
                            in
                            ( ( n, e1 ) :: acc, c3 )
                        )
                        ( [], c1 )
                        updates
            in
            ( MonoRecordUpdate recordExpr1 (List.reverse newUpdatesRev) monoType, VI_Unknown, c2 )

        MonoLet (MonoDef defName defExpr) body resultType ->
            let
                defExpected =
                    Just (Mono.typeOf defExpr)

                ( defExpr1, defInfo, c1 ) =
                    rewriteExpr home counter env defExpected defExpr

                envWithDef =
                    case defInfo of
                        VI_Unknown ->
                            env

                        _ ->
                            Dict.insert defName defInfo env

                ( body1, bodyInfo, c2 ) =
                    rewriteExpr home c1 envWithDef (Just resultType) body
            in
            ( MonoLet (MonoDef defName defExpr1) body1 resultType
            , bodyInfo
            , c2
            )

        MonoLet (MonoTailDef defName params defExpr) body resultType ->
            let
                ( defExpr1, _, c1 ) =
                    rewriteExpr home counter env Nothing defExpr

                ( body1, bodyInfo, c2 ) =
                    rewriteExpr home c1 env (Just resultType) body
            in
            ( MonoLet (MonoTailDef defName params defExpr1) body1 resultType
            , bodyInfo
            , c2
            )

        MonoCall region funcExpr argExprs resultType callInfo ->
            let
                ( funcExpr1, funcInfo, c1 ) =
                    rewriteExpr home counter env Nothing funcExpr

                ( newArgsRev, c2 ) =
                    List.foldl
                        (\a ( acc, c ) ->
                            let
                                ( a1, _, c3 ) =
                                    rewriteExpr home c env Nothing a
                            in
                            ( a1 :: acc, c3 )
                        )
                        ( [], c1 )
                        argExprs

                newArgs =
                    List.reverse newArgsRev
            in
            case ( funcInfo, newArgs ) of
                ( VI_Accessor (AO_Field fieldName), firstArg :: [] ) ->
                    case Mono.typeOf firstArg of
                        MRecord fields ->
                            let
                                fieldType =
                                    Maybe.withDefault resultType (Dict.get fieldName fields)
                            in
                            ( MonoRecordAccess firstArg fieldName fieldType
                            , VI_Unknown
                            , c2
                            )

                        _ ->
                            ( MonoCall region funcExpr1 newArgs resultType callInfo
                            , VI_Unknown
                            , c2
                            )

                ( VI_Accessor (AO_Field fieldName), firstArg :: restArgs ) ->
                    case Mono.typeOf firstArg of
                        MRecord fields ->
                            let
                                intermediateType =
                                    Maybe.withDefault
                                        (case Mono.typeOf funcExpr1 of
                                            MFunction _ _ rt ->
                                                rt

                                            _ ->
                                                resultType
                                        )
                                        (Dict.get fieldName fields)

                                accessResult =
                                    MonoRecordAccess firstArg fieldName intermediateType

                                innerCall =
                                    MonoCall region accessResult restArgs resultType callInfo
                            in
                            rewriteExpr home c2 env maybeExpected innerCall

                        _ ->
                            ( MonoCall region funcExpr1 newArgs resultType callInfo
                            , VI_Unknown
                            , c2
                            )

                _ ->
                    ( MonoCall region funcExpr1 newArgs resultType callInfo
                    , VI_Unknown
                    , c2
                    )

        MonoIf branches finalExpr resultType ->
            let
                branchExpected =
                    Just resultType

                ( newBranchesRev, branchInfos, c1 ) =
                    List.foldl
                        (\( cond, br ) ( accBranches, accInfos, c ) ->
                            let
                                ( cond1, _, c2 ) =
                                    rewriteExpr home c env Nothing cond

                                ( br1, brInfo, c3 ) =
                                    rewriteExpr home c2 env branchExpected br
                            in
                            ( ( cond1, br1 ) :: accBranches, brInfo :: accInfos, c3 )
                        )
                        ( [], [], counter )
                        branches

                ( finalExpr1, finalInfo, c4 ) =
                    rewriteExpr home c1 env branchExpected finalExpr

                combinedInfo =
                    List.foldl joinValueInfo finalInfo branchInfos
            in
            ( MonoIf (List.reverse newBranchesRev) finalExpr1 resultType
            , combinedInfo
            , c4
            )

        MonoCase label root decider jumps resultType ->
            let
                branchExpected =
                    Just resultType

                ( newDecider, c1 ) =
                    rewriteDecider home counter env branchExpected decider

                ( newJumpsRev, jumpInfos, c2 ) =
                    List.foldl
                        (\( tag, jumpExpr ) ( accJumps, accInfos, c ) ->
                            let
                                ( jumpExpr1, jumpInfo, c3 ) =
                                    rewriteExpr home c env branchExpected jumpExpr
                            in
                            ( ( tag, jumpExpr1 ) :: accJumps, jumpInfo :: accInfos, c3 )
                        )
                        ( [], [], c1 )
                        jumps

                combinedInfo =
                    List.foldl joinValueInfo VI_Unknown jumpInfos
            in
            ( MonoCase label root newDecider (List.reverse newJumpsRev) resultType
            , combinedInfo
            , c2
            )

        MonoClosure info body closureType ->
            let
                ( newCapturesRev, c1 ) =
                    List.foldl
                        (\( n, e, t ) ( acc, c ) ->
                            let
                                ( e1, _, c2 ) =
                                    rewriteExpr home c env Nothing e
                            in
                            ( ( n, e1, t ) :: acc, c2 )
                        )
                        ( [], counter )
                        info.captures

                bodyExpected =
                    case closureType of
                        MFunction _ _ rt ->
                            Just rt

                        _ ->
                            Nothing

                ( body1, _, c3 ) =
                    rewriteExpr home c1 env bodyExpected body
            in
            ( MonoClosure { info | captures = List.reverse newCapturesRev } body1 closureType
            , VI_Unknown
            , c3
            )

        MonoList region items t ->
            let
                ( newItemsRev, c1 ) =
                    List.foldl
                        (\e ( acc, c ) ->
                            let
                                ( e1, _, c2 ) =
                                    rewriteExpr home c env Nothing e
                            in
                            ( e1 :: acc, c2 )
                        )
                        ( [], counter )
                        items
            in
            ( MonoList region (List.reverse newItemsRev) t, VI_Unknown, c1 )

        MonoTupleCreate region elements t ->
            let
                elemExpectedTypes =
                    case t of
                        MTuple elemTypes ->
                            List.map Just elemTypes

                        _ ->
                            List.repeat (List.length elements) Nothing

                ( newElemsRev, c1 ) =
                    List.foldl
                        (\( elemExpected, e ) ( acc, c ) ->
                            let
                                ( e1, _, c2 ) =
                                    rewriteExpr home c env elemExpected e
                            in
                            ( e1 :: acc, c2 )
                        )
                        ( [], counter )
                        (zip elemExpectedTypes elements)
            in
            ( MonoTupleCreate region (List.reverse newElemsRev) t, VI_Unknown, c1 )

        MonoDestruct path inner t ->
            let
                ( inner1, _, c1 ) =
                    rewriteExpr home counter env Nothing inner
            in
            ( MonoDestruct path inner1 t, VI_Unknown, c1 )

        MonoTailCall name args t ->
            let
                ( newArgsRev, c1 ) =
                    List.foldl
                        (\( n, e ) ( acc, c ) ->
                            let
                                ( e1, _, c2 ) =
                                    rewriteExpr home c env Nothing e
                            in
                            ( ( n, e1 ) :: acc, c2 )
                        )
                        ( [], counter )
                        args
            in
            ( MonoTailCall name (List.reverse newArgsRev) t, VI_Unknown, c1 )


rewriteDecider : IO.Canonical -> Int -> Env -> Maybe MonoType -> Decider MonoChoice -> ( Decider MonoChoice, Int )
rewriteDecider home counter env maybeExpected decider =
    case decider of
        Leaf choice ->
            let
                ( newChoice, c1 ) =
                    rewriteChoice home counter env maybeExpected choice
            in
            ( Leaf newChoice, c1 )

        Chain test success failure ->
            let
                ( success1, c1 ) =
                    rewriteDecider home counter env maybeExpected success

                ( failure1, c2 ) =
                    rewriteDecider home c1 env maybeExpected failure
            in
            ( Chain test success1 failure1, c2 )

        FanOut path edges fallback ->
            let
                ( newEdgesRev, c1 ) =
                    List.foldl
                        (\( t, d ) ( acc, c ) ->
                            let
                                ( d1, c2 ) =
                                    rewriteDecider home c env maybeExpected d
                            in
                            ( ( t, d1 ) :: acc, c2 )
                        )
                        ( [], counter )
                        edges

                ( fallback1, c3 ) =
                    rewriteDecider home c1 env maybeExpected fallback
            in
            ( FanOut path (List.reverse newEdgesRev) fallback1, c3 )


rewriteChoice : IO.Canonical -> Int -> Env -> Maybe MonoType -> MonoChoice -> ( MonoChoice, Int )
rewriteChoice home counter env maybeExpected choice =
    case choice of
        Inline e ->
            let
                ( e1, _, c1 ) =
                    rewriteExpr home counter env maybeExpected e
            in
            ( Inline e1, c1 )

        Jump i ->
            ( Jump i, counter )


zip : List a -> List b -> List ( a, b )
zip xs ys =
    case ( xs, ys ) of
        ( x :: xRest, y :: yRest ) ->
            ( x, y ) :: zip xRest yRest

        _ ->
            []
