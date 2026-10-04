module Compiler.Monomorphize.ResolveAccessorValues exposing (accessorTypeNeedsDefer, rewriteNode)

{-| A record accessor such as `.name`, used as a value rather than applied
directly, cannot always be specialized when it is reached: its record type may
not yet be known, or the field it reads may itself be a function.
Specialization then leaves a placeholder, an _accessor value_
(`MonoAccessorValue`), and this module replaces such placeholders once the
surrounding types say what record they read.

`accessorTypeNeedsDefer` is the test that decides whether an accessor becomes
a placeholder in the first place. `rewriteNode` is the rewrite, applied to the
body of one specialized node.

The rewrite is a single forward pass over an expression. Alongside it, the pass
records for each local which accessor it is believed to be, or that it is a
record some of whose fields are accessors. Where branches join, a branch about
which nothing is known does not count against the other. That knowledge
allows two replacements:

  - A call whose callee is known to be `.field` and whose first argument has a
    record type becomes a direct `MonoRecordAccess` of that argument. Any
    further arguments become a call on the field's value.

  - A placeholder whose expected type, the type its context demands, is a
    one-parameter function from a record to a field type, with no type
    variable in either, becomes a fresh closure `\record -> record.field`.
    Each such closure takes a new `AnonymousLambda` id in the module being
    rewritten (`home`), numbered from a counter that the caller passes in
    and gets back.

A placeholder that fits neither case is left in place. Many positions are
rewritten with no expected type at all, among them call arguments, list
elements, record update values and closure captures, so a placeholder can
survive this pass.

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
import Compiler.Elm.ModuleName as ModuleName
import Dict exposing (Dict)



-- ============================================================================
-- ====== PUBLIC API ======
-- ============================================================================


{-| Returns whether an accessor with the given specialized type must be left
as an accessor value rather than made into an accessor global at once.

It returns `False` only for a function type whose first parameter is a record
and whose result is not itself a function. A non-record first parameter means
the record is not yet known. A function result means the field read is itself a
function, and an accessor global is built as a function of one parameter, so
its arity would not match the type.

-}
accessorTypeNeedsDefer : MonoType -> Bool
accessorTypeNeedsDefer monoType =
    case monoType of
        MFunction _ _ ((MRecord _ _) :: _) resultType ->
            case resultType of
                MFunction _ _ _ _ ->
                    True

                _ ->
                    False

        _ ->
            True


{-| Rewrites one node body, starting with no known locals, and returns it with
the advanced lambda counter.
-}
rewriteExprBody : ModuleName.Canonical -> Int -> Maybe MonoType -> MonoExpr -> ( MonoExpr, Int )
rewriteExprBody home lambdaCounter maybeExpectedType expr =
    let
        ( afterDataFlow, _, finalCounter ) =
            rewriteExpr home lambdaCounter Dict.empty maybeExpectedType expr
    in
    ( afterDataFlow, finalCounter )


{-| Rewrites the body of `node` as the module docstring describes, and returns
it with the lambda counter advanced past any closures made.

The expected type of a body is the node's type, except for a `MonoTailFunc`,
whose body is expected to have the type left after every stage of the
function's type is applied. A node with no body (a constructor, an enum, an
extern, a manager leaf) is returned unchanged.

-}
rewriteNode : ModuleName.Canonical -> Int -> Mono.MonoNode -> ( Mono.MonoNode, Int )
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
-- ====== DATA-FLOW REWRITE ======
-- ============================================================================


{-| Which accessor a value is known to be: `AO_Field` names the field it reads.
-}
type AccessorOrigin
    = AO_Field String


{-| What the pass knows about the value of an expression.

`VI_Unknown` means nothing is known. `VI_Accessor` means the value is the
accessor for a field. `VI_Record` means the value is a record, and holds what is
known about some of its fields; a field missing from the dictionary is unknown.

-}
type ValueInfo
    = VI_Unknown
    | VI_Accessor AccessorOrigin
    | VI_Record (Dict String ValueInfo)


{-| What is known about each local in scope, by name. A local with nothing
known is absent.
-}
type alias Env =
    Dict String ValueInfo


{-| Combines what is known about the values of two branches into what is known
about whichever one is taken.

Two different accessors, or an accessor and a record, combine to `VI_Unknown`,
and two records keep only the fields known alike in both. `VI_Unknown` combined
with anything gives the other side unchanged, so a branch about which nothing
is known does not weaken what the other branch says.

-}
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


{-| Returns the record type and field type of `expectedType` when it is a
function of exactly one record parameter and neither the record nor the result
contains a type variable, and `Nothing` otherwise.
-}
maybeAccessorSigFromExpected : MonoType -> Maybe ( MonoType, MonoType )
maybeAccessorSigFromExpected expectedType =
    case expectedType of
        MFunction _ _ ((MRecord _ fields) :: []) fieldType ->
            if not (Mono.containsAnyMVar (Mono.mRecord fields)) && not (Mono.containsAnyMVar fieldType) then
                Just ( Mono.mRecord fields, fieldType )

            else
                Nothing

        _ ->
            Nothing


{-| Builds the closure `\record -> record.field` for `fieldName`, with no
captures, typed `expectedType`, and returns it with `counter` advanced by one.
Its lambda id is `AnonymousLambda home counter`.
-}
buildAccessorClosure : ModuleName.Canonical -> Int -> String -> MonoType -> MonoType -> MonoType -> ( MonoExpr, Int )
buildAccessorClosure home counter fieldName recordType fieldType expectedType =
    let
        lambdaId =
            Mono.AnonymousLambda home counter

        closureInfo =
            { lambdaId = lambdaId
            , srcLambda = Nothing
            , lssMember = Nothing
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


{-| Rewrites `expr` given what `env` knows about the locals in scope and the
type its context expects, if any. Returns the rewritten expression, what is
known about its value, and the advanced lambda counter.

What is known about a value comes from a placeholder, a local, a record
creation, a field access on a known record, a `let` body, and the branches of
an `if`. A `case` reports only what its jump bodies say, not its inline leaves.
Every other expression, a closure included, reports `VI_Unknown`.

A placeholder reports the accessor it stands for, whether or not it was
replaced by a closure. A rewritten call on a known accessor with more than one
argument is rewritten again, so the call on the field's value is itself
examined.

-}
rewriteExpr : ModuleName.Canonical -> Int -> Env -> Maybe MonoType -> MonoExpr -> ( MonoExpr, ValueInfo, Int )
rewriteExpr home counter env maybeExpected expr =
    case expr of
        MonoAccessorValue _ fieldName _ ->
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
                        MRecord _ ft ->
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
                        MRecord _ fields ->
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
                        MRecord _ fields ->
                            let
                                intermediateType =
                                    Maybe.withDefault
                                        (case Mono.typeOf funcExpr1 of
                                            MFunction _ _ _ rt ->
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
                        MFunction _ _ _ rt ->
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
                        MTuple _ elemTypes ->
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


{-| Rewrites every inline leaf of a `case` decision tree, each with
`maybeExpected` as its expected type, and returns the tree with the advanced
lambda counter.
-}
rewriteDecider : ModuleName.Canonical -> Int -> Env -> Maybe MonoType -> Decider MonoChoice -> ( Decider MonoChoice, Int )
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


{-| Rewrites an inline leaf with `maybeExpected` as its expected type, and
returns a jump unchanged.
-}
rewriteChoice : ModuleName.Canonical -> Int -> Env -> Maybe MonoType -> MonoChoice -> ( MonoChoice, Int )
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


{-| Pairs the elements of two lists in order, stopping at the end of the shorter.
-}
zip : List a -> List b -> List ( a, b )
zip xs ys =
    case ( xs, ys ) of
        ( x :: xRest, y :: yRest ) ->
            ( x, y ) :: zip xRest yRest

        _ ->
            []
