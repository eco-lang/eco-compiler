module TestLogic.Monomorphize.ClosureSpecKeyConsistency exposing (expectClosureSpecKeyConsistency, Violation)

{-| A check that the function a specialization implements has the types its
registry entry says it has. Under the substitution engine the registry's type
for a SpecId is normally the node's own type, written back after the node is
built, so the check mostly catches a node whose declared function type
disagrees with its closure's parameter types and body type.

Monomorphization numbers each specialization with a SpecId, and the
specialization registry's `reverseMapping` records, for each SpecId, a global
and a MonoType. That MonoType is called the _key type_ here. Monomorphization
keeps function types curried (`Compiler.Monomorphize.TypeSubst` owns that
rule), so the key type of a two-argument function is a function of one argument
returning a function of one argument, while the closure implementing it may
take both parameters at once. The check therefore compares in flattened form: a
function type is flattened by collecting the parameters of each nested
`MFunction` in order, down to the first result that is not a function.

`expectClosureSpecKeyConsistency` monomorphizes a source module with
`TestLogic.TestPipeline.runToMono`, which uses the substitution engine, not the
solver engine, and checks every SpecId whose registry entry is present and
whose node exists. Only two kinds of node are checked: a `MonoDefine` whose
body is a `MonoClosure`, and a `MonoTailFunc`. For each, when the key type
flattens to at least one parameter:

  - the closure may not have more parameters than the flattened key type;
  - each closure parameter's type must equal the key parameter at the same
    position;
  - when the closure takes every key parameter, the type of its body must equal
    the flattened key result;
  - when it takes fewer, the body's type must flatten to exactly the remaining
    key parameters and the key result, however its stages are grouped.

Types are compared structurally, ignoring the hash field of composite types and
the lambda-set annotation of function types, and comparing type variables by id
alone, without their constraint.

Among what is not checked: closures nested inside a body; a `MonoDefine` whose
body is not a closure literal; the MonoType stored on the closure itself, as
opposed to its parameters and body; and any node whose key type is not a
function, even if the node is a closure with parameters. The node's own type is
not read directly, though under the substitution engine it is normally what the
key type is.

@docs expectClosureSpecKeyConsistency, Violation

-}

import Array
import Compiler.AST.Monomorphized as Mono
import Compiler.AST.Source as Src
import Compiler.Data.Id as Id
import Dict
import Expect exposing (Expectation)
import TestLogic.TestPipeline as Pipeline


{-| One disagreement between a checked node and its key type.

`context` names the SpecId and its global, followed by `param=<name>` for a
parameter mismatch, by `result` or `result (returns function)` for a result
mismatch, and by nothing when the closure has too many parameters. `message`
gives the detail over several lines, with the types it compares printed.

-}
type alias Violation =
    { context : String
    , message : String
    }


{-| Returns an expectation that passes when `srcModule` monomorphizes and no
checked node disagrees with its key type, as the module docstring describes.

It fails with the pipeline's message when `runToMono` returns an error, and
otherwise with one message listing every violation found.

-}
expectClosureSpecKeyConsistency : Src.Module -> Expectation
expectClosureSpecKeyConsistency srcModule =
    case Pipeline.runToMono srcModule of
        Err msg ->
            Expect.fail ("Compilation failed: " ++ msg)

        Ok { monoGraph } ->
            let
                violations =
                    checkClosureSpecKeyConsistency monoGraph
            in
            if List.isEmpty violations then
                Expect.pass

            else
                Expect.fail (formatViolations violations)


{-| Returns the violations of every node in the graph, in SpecId order.

A SpecId whose registry entry is `Nothing`, or whose node is missing, is
skipped.

-}
checkClosureSpecKeyConsistency : Mono.MonoGraph -> List Violation
checkClosureSpecKeyConsistency (Mono.MonoGraph data) =
    Array.toIndexedList data.registry.reverseMapping
        |> List.foldl
            (\( specId, maybeEntry ) acc ->
                case maybeEntry of
                    Nothing ->
                        -- A pruned specialization leaves its slot empty.
                        acc

                    Just ( global, keyMonoType ) ->
                        case Array.get specId data.nodes |> Maybe.andThen identity of
                            Nothing ->
                                acc

                            Just node ->
                                acc ++ checkNodeAgainstKey specId global keyMonoType node
            )
            []


{-| Returns the violations of one node against `keyMonoType`, its key type.

Only a `MonoDefine` whose body is a `MonoClosure`, and a `MonoTailFunc`, are
compared; every other node gives no violations. `specId` and `global` only
label the violations.

-}
checkNodeAgainstKey : Int -> Mono.Global -> Mono.MonoType -> Mono.MonoNode -> List Violation
checkNodeAgainstKey specId global keyMonoType node =
    let
        ctx =
            "SpecId " ++ String.fromInt specId ++ " (" ++ globalToString global ++ ")"
    in
    case node of
        Mono.MonoDefine expr _ ->
            case expr of
                Mono.MonoClosure info body _ ->
                    checkClosureParams ctx keyMonoType info.params (Mono.typeOf body)

                _ ->
                    []

        Mono.MonoTailFunc params body _ ->
            checkClosureParams ctx keyMonoType params (Mono.typeOf body)

        Mono.MonoCtor _ _ ->
            []

        Mono.MonoEnum _ _ ->
            []

        Mono.MonoExtern _ ->
            []

        Mono.MonoManagerLeaf _ _ ->
            []

        Mono.MonoPortIncoming _ _ ->
            []

        Mono.MonoPortOutgoing _ _ ->
            []


{-| Returns the violations of a closure with parameters `closureParams` and body
type `bodyType` against the key type `keyMonoType`, labelled with `ctx`.

A key type that flattens to no parameters gives no violations, whatever the
closure takes. A closure with more parameters than the flattened key gives one
violation and nothing else is compared. Otherwise each parameter is compared
with the key parameter at its position, and the body type with the flattened
key result when the closure takes every key parameter, or, when it takes fewer,
with a function of the remaining key parameters returning that result, both
sides flattened.

-}
checkClosureParams : String -> Mono.MonoType -> List ( String, Mono.MonoType ) -> Mono.MonoType -> List Violation
checkClosureParams ctx keyMonoType closureParams bodyType =
    let
        ( keyParamTypes, keyResultType ) =
            flattenMFunction keyMonoType

        closureParamTypes =
            List.map Tuple.second closureParams

        closureParamCount =
            List.length closureParamTypes

        keyParamCount =
            List.length keyParamTypes
    in
    if keyParamCount == 0 then
        []

    else if closureParamCount > keyParamCount then
        [ { context = ctx
          , message =
                "MONO_025 violation: closure has more params than key function type\n"
                    ++ "  key type: "
                    ++ monoTypeToString keyMonoType
                    ++ "\n"
                    ++ "  key param count: "
                    ++ String.fromInt keyParamCount
                    ++ "\n"
                    ++ "  closure param count: "
                    ++ String.fromInt closureParamCount
          }
        ]

    else
        let
            keyPrefix =
                List.take closureParamCount keyParamTypes

            paramMismatches =
                List.map2
                    (\( closureParamName, closureParamType ) keyParamType ->
                        if monoTypeEq closureParamType keyParamType then
                            Nothing

                        else
                            Just
                                { context = ctx ++ " param=" ++ closureParamName
                                , message =
                                    "MONO_025 violation: closure param type != key param type\n"
                                        ++ "  param: "
                                        ++ closureParamName
                                        ++ "\n"
                                        ++ "  closure param type: "
                                        ++ monoTypeToString closureParamType
                                        ++ "\n"
                                        ++ "  key param type:    "
                                        ++ monoTypeToString keyParamType
                                }
                    )
                    closureParams
                    keyPrefix
                    |> List.filterMap identity

            resultMismatches =
                if closureParamCount == keyParamCount then
                    if monoTypeEq bodyType keyResultType then
                        []

                    else
                        [ { context = ctx ++ " result"
                          , message =
                                "MONO_025 violation: closure result type != key result type\n"
                                    ++ "  closure body type: "
                                    ++ monoTypeToString bodyType
                                    ++ "\n"
                                    ++ "  key result type:   "
                                    ++ monoTypeToString keyResultType
                          }
                        ]

                else
                    let
                        remainingKeyParams =
                            List.drop closureParamCount keyParamTypes

                        -- The annotation is arbitrary: monoTypeEq ignores annotations.
                        expectedBodyType =
                            Mono.mFunction Mono.topLegacy remainingKeyParams keyResultType

                        ( bodyParamTypes, bodyResultType ) =
                            flattenMFunction bodyType

                        ( expectedParamTypes, expectedResultType ) =
                            flattenMFunction expectedBodyType
                    in
                    if
                        listEq monoTypeEq bodyParamTypes expectedParamTypes
                            && monoTypeEq bodyResultType expectedResultType
                    then
                        []

                    else
                        [ { context = ctx ++ " result (returns function)"
                          , message =
                                "MONO_025 violation: closure result type doesn't match remaining key structure\n"
                                    ++ "  closure body type: "
                                    ++ monoTypeToString bodyType
                                    ++ "\n"
                                    ++ "  expected (from key): "
                                    ++ monoTypeToString expectedBodyType
                          }
                        ]
        in
        paramMismatches ++ resultMismatches



-- ============================================================================
-- MONOTYPE HELPERS
-- ============================================================================


{-| Returns the parameters of `monoType` and of every function it returns, in
order, paired with the first result that is not a function. A type that is not
a function gives no parameters and itself.

    -- with f = Mono.mFunction anno
    flattenMFunction (f [ a, b ] (f [ c ] d))
        == ( [ a, b, c ], d )

    flattenMFunction Mono.MInt
        == ( [], Mono.MInt )

-}
flattenMFunction : Mono.MonoType -> ( List Mono.MonoType, Mono.MonoType )
flattenMFunction monoType =
    case monoType of
        Mono.MFunction _ _ params result ->
            let
                ( restParams, finalResult ) =
                    flattenMFunction result
            in
            ( params ++ restParams, finalResult )

        _ ->
            ( [], monoType )


{-| Returns whether two MonoTypes are the same type.

The comparison ignores the hash field of composite types and the lambda-set
annotation of function types, and treats two type variables as equal when their
ids are equal, whatever their constraints. A type variable never equals a
concrete type, so `MVar _ CNumber` does not equal `MInt`.

-}
monoTypeEq : Mono.MonoType -> Mono.MonoType -> Bool
monoTypeEq a b =
    case ( a, b ) of
        ( Mono.MInt, Mono.MInt ) ->
            True

        ( Mono.MFloat, Mono.MFloat ) ->
            True

        ( Mono.MBool, Mono.MBool ) ->
            True

        ( Mono.MChar, Mono.MChar ) ->
            True

        ( Mono.MString, Mono.MString ) ->
            True

        ( Mono.MUnit, Mono.MUnit ) ->
            True

        ( Mono.MList _ a1, Mono.MList _ b1 ) ->
            monoTypeEq a1 b1

        ( Mono.MFunction _ _ aParams aResult, Mono.MFunction _ _ bParams bResult ) ->
            listEq monoTypeEq aParams bParams && monoTypeEq aResult bResult

        ( Mono.MTuple _ aElems, Mono.MTuple _ bElems ) ->
            listEq monoTypeEq aElems bElems

        ( Mono.MRecord _ aFields, Mono.MRecord _ bFields ) ->
            dictEq monoTypeEq aFields bFields

        ( Mono.MCustom _ aHome aName aArgs, Mono.MCustom _ bHome bName bArgs ) ->
            aHome == bHome && aName == bName && listEq monoTypeEq aArgs bArgs

        ( Mono.MVar aId _, Mono.MVar bId _ ) ->
            Id.toComparable aId == Id.toComparable bId

        _ ->
            False


{-| Returns whether `xs` and `ys` have the same length and `eq` holds for each
pair of elements at the same position.
-}
listEq : (a -> a -> Bool) -> List a -> List a -> Bool
listEq eq xs ys =
    case ( xs, ys ) of
        ( [], [] ) ->
            True

        ( x :: xRest, y :: yRest ) ->
            eq x y && listEq eq xRest yRest

        _ ->
            False


{-| Returns whether `a` and `b` have the same keys and `eq` holds for the two
values under each key.
-}
dictEq : (v -> v -> Bool) -> Dict.Dict String v -> Dict.Dict String v -> Bool
dictEq eq a b =
    Dict.size a
        == Dict.size b
        && Dict.foldl
            (\key va acc ->
                acc
                    && (case Dict.get key b of
                            Just vb ->
                                eq va vb

                            Nothing ->
                                False
                       )
            )
            True
            a



-- ============================================================================
-- FORMATTING
-- ============================================================================


{-| Returns a failure message giving the number of violations, then each as
`context: message`, separated by blank lines.
-}
formatViolations : List Violation -> String
formatViolations violations =
    "MONO_025 violations found ("
        ++ String.fromInt (List.length violations)
        ++ "):\n\n"
        ++ (violations
                |> List.map (\v -> v.context ++ ": " ++ v.message)
                |> String.join "\n\n"
           )


{-| Returns the name of a global for a violation's context, without its
module; an accessor is written as `.field`.
-}
globalToString : Mono.Global -> String
globalToString global =
    case global of
        Mono.Global _ name ->
            name

        Mono.Accessor name ->
            "." ++ name


{-| Returns a short rendering of a MonoType for a violation message.

It is lossy: a custom type is shown by its name alone, without module or
arguments, a type variable by its id alone, and record fields in descending
name order.

-}
monoTypeToString : Mono.MonoType -> String
monoTypeToString monoType =
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

        Mono.MList _ elementType ->
            "List " ++ monoTypeToString elementType

        Mono.MTuple _ elements ->
            "(" ++ String.join ", " (List.map monoTypeToString elements) ++ ")"

        Mono.MRecord _ fields ->
            let
                fieldStrs =
                    Dict.foldl
                        (\name ty acc -> (name ++ " : " ++ monoTypeToString ty) :: acc)
                        []
                        fields
            in
            "{ " ++ String.join ", " fieldStrs ++ " }"

        Mono.MCustom _ _ name _ ->
            name

        Mono.MFunction _ _ params result ->
            let
                paramStr =
                    case params of
                        [ single ] ->
                            monoTypeToString single

                        multiple ->
                            "(" ++ String.join ", " (List.map monoTypeToString multiple) ++ ")"
            in
            paramStr ++ " -> " ++ monoTypeToString result

        Mono.MVar mvarId _ ->
            String.fromInt (Id.toComparable mvarId)
