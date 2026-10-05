module TestLogic.Generate.MonoNumericResolution exposing
    ( expectNoNumericPolymorphism
    , expectNumericTypesResolved
    )

{-| A `number` type variable stands for either `Int` or `Float`, and the two
are represented differently in generated code. The checks here look for a
number type that monomorphization left unresolved, or resolved differently on
the two sides of a call.

  - `expectNoNumericPolymorphism` (MONO\_002) runs a source module through
    `TestLogic.TestPipeline.runToGlobalOpt`, the graph `runToMlir` hands to
    MLIR generation, and fails if any type stored in it, at any position
    `MonoTraverse.anyNodeType` reaches (node, expression, parameter, capture
    and call-metadata types, case branches held inline included) and at any
    depth (inside lists, tuples, records, custom type arguments and
    functions), is an `MVar _ CNumber`. The substitution engine's
    `Compiler.Monomorphize.Prune` closes such variables before the
    post-monomorphization inliner and the global optimizer run, so this
    guards those later passes: nothing after the prune would catch a number
    variable they introduce.
  - `expectNumericTypesResolved` (MONO\_008) runs a source module through
    `TestLogic.TestPipeline.runToMono` and, at every call in the graph (any
    depth, case branches held inline included), pairs the callee's parameter
    types (the parameters of all its stages, in order) with the arguments'
    types, and fails where one says `Int` and the other `Float` at the same
    position, at any depth of the two types. Prune closes a residual number
    variable to `Int` wherever it occurs, so a variable that stood for the
    `Float` an argument has would show up here as an `Int` parameter.

A pipeline failure fails the check with the pipeline's message. Each check
reports every problem found, one per line, with the SpecId of its node.

Among what is not tested: tail calls (`MonoTailCall` carries no callee type),
and the solver engine (see `TestLogic.Generate.MonoTypeShape`).

-}

import Array
import Compiler.AST.Monomorphized as Mono
import Compiler.AST.Source as Src
import Compiler.Monomorphize.MonoTraverse as MonoTraverse
import Dict
import Expect
import TestLogic.TestPipeline as Pipeline


{-| Checks that the globally optimized graph of `srcModule` holds no
`MVar _ CNumber` anywhere, as the module documentation describes.
-}
expectNoNumericPolymorphism : Src.Module -> Expect.Expectation
expectNoNumericPolymorphism srcModule =
    case Pipeline.runToGlobalOpt srcModule of
        Err msg ->
            Expect.fail msg

        Ok { optimizedMonoGraph } ->
            expectNoIssues (numberVarIssues optimizedMonoGraph)


{-| Checks that no call in the monomorphized graph of `srcModule` passes an
`Int` where its callee's type says `Float`, or the reverse.
-}
expectNumericTypesResolved : Src.Module -> Expect.Expectation
expectNumericTypesResolved srcModule =
    case Pipeline.runToMono srcModule of
        Err msg ->
            Expect.fail msg

        Ok { monoGraph } ->
            expectNoIssues (callSiteIssues monoGraph)


expectNoIssues : List String -> Expect.Expectation
expectNoIssues issues =
    if List.isEmpty issues then
        Expect.pass

    else
        Expect.fail (String.join "\n" issues)



-- ============================================================================
-- NO NUMBER VARIABLES (MONO_002)
-- ============================================================================


{-| One line per node of the graph holding a number variable in some type.
-}
numberVarIssues : Mono.MonoGraph -> List String
numberVarIssues (Mono.MonoGraph data) =
    Array.toIndexedList data.nodes
        |> List.filterMap
            (\( specId, maybeNode ) ->
                case maybeNode of
                    Just node ->
                        if MonoTraverse.anyNodeType hasNumberVar node then
                            Just ("SpecId " ++ String.fromInt specId ++ ": a type holds an MVar with CNumber constraint (MONO_002)")

                        else
                            Nothing

                    Nothing ->
                        Nothing
            )


{-| Returns whether `monoType` holds an `MVar _ CNumber` at any depth.
-}
hasNumberVar : Mono.MonoType -> Bool
hasNumberVar monoType =
    case monoType of
        Mono.MVar _ Mono.CNumber ->
            True

        Mono.MList _ elemType ->
            hasNumberVar elemType

        Mono.MTuple _ elemTypes ->
            List.any hasNumberVar elemTypes

        Mono.MRecord _ fields ->
            List.any hasNumberVar (Dict.values fields)

        Mono.MCustom _ _ _ typeArgs ->
            List.any hasNumberVar typeArgs

        Mono.MFunction _ _ paramTypes returnType ->
            List.any hasNumberVar paramTypes || hasNumberVar returnType

        _ ->
            False



-- ============================================================================
-- CALL-SITE NUMERIC AGREEMENT (MONO_008)
-- ============================================================================


{-| One line per call argument whose type disagrees with its parameter on
`Int` versus `Float`.
-}
callSiteIssues : Mono.MonoGraph -> List String
callSiteIssues (Mono.MonoGraph data) =
    Array.toIndexedList data.nodes
        |> List.concatMap
            (\( specId, maybeNode ) ->
                case maybeNode |> Maybe.andThen nodeBody of
                    Just body ->
                        MonoTraverse.foldExpr (checkCall ("SpecId " ++ String.fromInt specId)) [] body

                    Nothing ->
                        []
            )


{-| Returns the expression of a node that has one.
-}
nodeBody : Mono.MonoNode -> Maybe Mono.MonoExpr
nodeBody node =
    case node of
        Mono.MonoDefine expr _ ->
            Just expr

        Mono.MonoTailFunc _ expr _ ->
            Just expr

        Mono.MonoPortIncoming expr _ ->
            Just expr

        Mono.MonoPortOutgoing expr _ ->
            Just expr

        _ ->
            Nothing


{-| Adds a line for each argument of a call whose type disagrees with the
callee's parameter type on `Int` versus `Float`.
-}
checkCall : String -> Mono.MonoExpr -> List String -> List String
checkCall context expr acc =
    case expr of
        Mono.MonoCall _ fnExpr args _ _ ->
            List.map2 Tuple.pair (flattenParams (Mono.typeOf fnExpr)) args
                |> List.indexedMap
                    (\idx ( paramType, arg ) ->
                        if numericConflict paramType (Mono.typeOf arg) then
                            Just
                                (context
                                    ++ ": call argument "
                                    ++ String.fromInt idx
                                    ++ " of "
                                    ++ calleeLabel fnExpr
                                    ++ " disagrees with its parameter on Int versus Float (MONO_008)"
                                )

                        else
                            Nothing
                    )
                |> List.filterMap identity
                |> (\issues -> issues ++ acc)

        _ ->
            acc


{-| Names a callee for a problem line.
-}
calleeLabel : Mono.MonoExpr -> String
calleeLabel fnExpr =
    case fnExpr of
        Mono.MonoVarGlobal _ specId _ ->
            "SpecId " ++ String.fromInt specId

        Mono.MonoVarLocal name _ ->
            name

        Mono.MonoVarKernel _ _ home name _ ->
            home ++ "." ++ name

        _ ->
            "a computed function"


{-| Returns the parameter types of every stage of a function type, outermost
first.
-}
flattenParams : Mono.MonoType -> List Mono.MonoType
flattenParams monoType =
    case monoType of
        Mono.MFunction _ _ paramTypes resultType ->
            paramTypes ++ flattenParams resultType

        _ ->
            []


{-| Returns whether two types, walked in parallel through the constructors
they share, have `Int` on one side and `Float` on the other somewhere.
Where their shapes differ otherwise (a type variable, say), nothing is
compared below that point.
-}
numericConflict : Mono.MonoType -> Mono.MonoType -> Bool
numericConflict a b =
    case ( a, b ) of
        ( Mono.MInt, Mono.MFloat ) ->
            True

        ( Mono.MFloat, Mono.MInt ) ->
            True

        ( Mono.MList _ x, Mono.MList _ y ) ->
            numericConflict x y

        ( Mono.MTuple _ xs, Mono.MTuple _ ys ) ->
            List.any identity (List.map2 numericConflict xs ys)

        ( Mono.MRecord _ xs, Mono.MRecord _ ys ) ->
            Dict.foldl
                (\name x found ->
                    found
                        || (case Dict.get name ys of
                                Just y ->
                                    numericConflict x y

                                Nothing ->
                                    False
                           )
                )
                False
                xs

        ( Mono.MCustom _ _ _ xs, Mono.MCustom _ _ _ ys ) ->
            List.any identity (List.map2 numericConflict xs ys)

        ( Mono.MFunction _ _ xs x, Mono.MFunction _ _ ys y ) ->
            List.any identity (List.map2 numericConflict xs ys) || numericConflict x y

        _ ->
            False
