module TestLogic.Generate.DebugPolymorphism exposing (expectDebugPolymorphismResolved)

{-| A `Debug` kernel function such as `Debug.log` or `Debug.toString` accepts a
value of any type. MONO\_009 says monomorphization keeps such a kernel
polymorphic: the type of a `Debug` kernel reference is derived from its
canonical type with an empty substitution, its type variables kept as
`CEcoValue` variables (always-boxed values) that do not affect the calling
convention.

`expectDebugPolymorphismResolved` runs a test program to the monomorphized
graph with `TestLogic.TestPipeline.runToMono` and visits every expression of
every node that has one, at any depth (including the branches held inline in a
`case` decision tree, through `MonoTraverse.foldExpr`). At each call whose
function is a `Debug` kernel reference it pairs the parameter types of the
reference's type (all stages, in order) with the call's arguments, and reports
a parameter that does not agree with the argument's type, where a `CEcoValue`
variable, at any depth of the parameter's type, agrees with anything and every
other part must be what is actually passed.

A violation is what a `number` variable kept at a `Debug` reference turns into:
`Compiler.Monomorphize.Prune` closes every variable whose id is a number
variable to `MInt`, so in a specialization at `Float` the reference would claim
an `Int` parameter while a `Float` is passed.

Among what is not checked: `Debug` references that are not called directly
(passed as a function value), whose parameters meet no argument here; and the
values `Debug` functions print or return, since nothing is run.

-}

import Array
import Compiler.AST.Monomorphized as Mono
import Compiler.AST.Source as Src
import Compiler.Monomorphize.MonoTraverse as MonoTraverse
import Dict
import Expect
import TestLogic.TestPipeline as Pipeline


{-| Checks that, in the monomorphized graph of `srcModule`, every call of a
`Debug` kernel agrees with the kernel reference's type, as the module
documentation describes.

It fails with the pipeline's message if `runToMono` fails. Otherwise it passes
when every call agrees, and fails with one line per disagreeing parameter,
naming the node's `SpecId`, the `Debug` function, the parameter and both types.

-}
expectDebugPolymorphismResolved : Src.Module -> Expect.Expectation
expectDebugPolymorphismResolved srcModule =
    case Pipeline.runToMono srcModule of
        Err msg ->
            Expect.fail msg

        Ok { monoGraph } ->
            let
                issues =
                    collectDebugPolymorphismIssues monoGraph
            in
            if List.isEmpty issues then
                Expect.pass

            else
                Expect.fail (String.join "\n" issues)



-- ============================================================================
-- DEBUG POLYMORPHISM VERIFICATION
-- ============================================================================


{-| Returns the problem lines for every node of the graph, labelling each node
with its index in the node array, which is its `SpecId`.
-}
collectDebugPolymorphismIssues : Mono.MonoGraph -> List String
collectDebugPolymorphismIssues (Mono.MonoGraph data) =
    Array.toIndexedList data.nodes
        |> List.concatMap
            (\( specId, maybeNode ) ->
                case maybeNode |> Maybe.andThen nodeBody of
                    Just body ->
                        MonoTraverse.foldExpr (checkExpr ("SpecId " ++ String.fromInt specId)) [] body

                    Nothing ->
                        []
            )


{-| Returns the expression of a node that has one: a define, a tail-recursive
function or a port.
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


{-| Adds the problem lines for `expr` when it is a call of a `Debug` kernel
reference: one for each parameter that does not agree with the type of the
argument passed for it, as `agrees` decides.
-}
checkExpr : String -> Mono.MonoExpr -> List String -> List String
checkExpr context expr acc =
    case expr of
        Mono.MonoCall _ (Mono.MonoVarKernel _ _ "Debug" name monoType) args _ _ ->
            List.map2 Tuple.pair (flattenParams monoType) args
                |> List.indexedMap
                    (\idx ( paramType, arg ) ->
                        if agrees paramType (Mono.typeOf arg) then
                            Nothing

                        else
                            Just
                                (context
                                    ++ ": Debug."
                                    ++ name
                                    ++ " param "
                                    ++ String.fromInt idx
                                    ++ " has type "
                                    ++ typeLabel paramType
                                    ++ " but the argument passed is "
                                    ++ typeLabel (Mono.typeOf arg)
                                    ++ " (MONO_009: a Debug kernel's variables must stay CEcoValue)"
                                )
                    )
                |> List.filterMap identity
                |> (\issues -> issues ++ acc)

        _ ->
            acc


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


{-| Returns whether the parameter type `param` agrees with the argument type
`arg`: a `CEcoValue` variable in `param` agrees with any type, and otherwise
the two must have the same constructors with agreeing parts. Packed hashes and
lambda-set annotations are not compared.
-}
agrees : Mono.MonoType -> Mono.MonoType -> Bool
agrees param arg =
    case ( param, arg ) of
        ( Mono.MVar _ Mono.CEcoValue, _ ) ->
            True

        ( Mono.MList _ p, Mono.MList _ a ) ->
            agrees p a

        ( Mono.MTuple _ ps, Mono.MTuple _ as_ ) ->
            List.length ps == List.length as_ && List.all identity (List.map2 agrees ps as_)

        ( Mono.MRecord _ ps, Mono.MRecord _ as_ ) ->
            Dict.keys ps
                == Dict.keys as_
                && List.all identity (List.map2 agrees (Dict.values ps) (Dict.values as_))

        ( Mono.MCustom _ ph pn ps, Mono.MCustom _ ah an as_ ) ->
            ph == ah && pn == an && List.length ps == List.length as_ && List.all identity (List.map2 agrees ps as_)

        ( Mono.MFunction _ _ ps pr, Mono.MFunction _ _ as_ ar ) ->
            List.length ps == List.length as_ && List.all identity (List.map2 agrees ps as_) && agrees pr ar

        _ ->
            param == arg


{-| Returns a short rendering of a type for a problem message.
-}
typeLabel : Mono.MonoType -> String
typeLabel monoType =
    case monoType of
        Mono.MInt ->
            "Int"

        Mono.MFloat ->
            "Float"

        Mono.MBool ->
            "Bool"

        Mono.MChar ->
            "Char"

        Mono.MString ->
            "String"

        Mono.MUnit ->
            "()"

        Mono.MList _ elemType ->
            "List (" ++ typeLabel elemType ++ ")"

        Mono.MTuple _ elemTypes ->
            "( " ++ String.join ", " (List.map typeLabel elemTypes) ++ " )"

        Mono.MRecord _ fields ->
            "{ " ++ String.join ", " (List.map (\( n, t ) -> n ++ " : " ++ typeLabel t) (Dict.toList fields)) ++ " }"

        Mono.MCustom _ _ name typeArgs ->
            String.join " " (name :: List.map (\t -> "(" ++ typeLabel t ++ ")") typeArgs)

        Mono.MFunction _ _ paramTypes returnType ->
            "(" ++ String.join ", " (List.map typeLabel paramTypes) ++ ") -> " ++ typeLabel returnType

        Mono.MVar _ Mono.CEcoValue ->
            "a"

        Mono.MVar _ Mono.CNumber ->
            "number"
