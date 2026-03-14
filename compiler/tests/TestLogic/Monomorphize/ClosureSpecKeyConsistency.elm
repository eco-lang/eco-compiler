module TestLogic.Monomorphize.ClosureSpecKeyConsistency exposing (expectClosureSpecKeyConsistency, Violation)

{-| Test logic for MONO\_025: Closure MonoType matches specialization key.

For every reachable MonoClosure or MonoTailFunc node implementing a user-defined
function or lambda specialization, the closure's stored MonoType must be
consistent with its specialization key.

This is verified by flattening the specialization key MonoType into a list of
parameter types and a result type, then comparing the closure's parameter types
against the corresponding prefix of the flattened key parameters.

When the closure is fully saturated (same number of params as the flattened key),
the result type must also match. When the closure returns a function (fewer params
than the flattened key), the result type must be an MFunction whose flattening
covers the remaining key parameter types and result type.

@docs expectClosureSpecKeyConsistency, Violation

-}

import Array
import Compiler.AST.Monomorphized as Mono
import Compiler.AST.Source as Src
import Dict
import Expect exposing (Expectation)
import TestLogic.TestPipeline as Pipeline


{-| Violation record for reporting MONO\_025 issues.
-}
type alias Violation =
    { context : String
    , message : String
    }


{-| MONO\_025: Verify closure MonoTypes match specialization keys.
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


{-| Check closure/function nodes for consistency with their specialization keys.
-}
checkClosureSpecKeyConsistency : Mono.MonoGraph -> List Violation
checkClosureSpecKeyConsistency (Mono.MonoGraph data) =
    Array.toIndexedList data.registry.reverseMapping
        |> List.foldl
            (\( specId, maybeEntry ) acc ->
                case maybeEntry of
                    Nothing ->
                        -- Pruned slot (MONO_022), skip
                        acc

                    Just ( global, keyMonoType, _ ) ->
                        case Array.get specId data.nodes |> Maybe.andThen identity of
                            Nothing ->
                                -- No node (caught by MONO_017)
                                acc

                            Just node ->
                                acc ++ checkNodeAgainstKey specId global keyMonoType node
            )
            []


{-| Check a single node's closure/function types against the specialization key.
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
                    -- Non-closure define: not a function specialization, skip
                    []

        Mono.MonoTailFunc params body _ ->
            checkClosureParams ctx keyMonoType params (Mono.typeOf body)

        -- Non-closure nodes: skip
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

        Mono.MonoCycle _ _ ->
            []


{-| Compare closure parameter types against the flattened specialization key.
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
        -- Key is not a function type; not a closure specialization
        []

    else if closureParamCount > keyParamCount then
        -- Closure has more params than key -- this would be very wrong
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
            -- Compare closure params against the prefix of key params
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

            -- Check result type consistency
            resultMismatches =
                if closureParamCount == keyParamCount then
                    -- Fully saturated: body type should match key result type
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
                    -- Closure returns a function (nested lambda). The body type
                    -- should be an MFunction covering the remaining key params.
                    let
                        remainingKeyParams =
                            List.drop closureParamCount keyParamTypes

                        expectedBodyType =
                            Mono.MFunction remainingKeyParams keyResultType

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


{-| Flatten an MFunction type by recursively peeling MFunction layers.

    flattenMFunction (MFunction [ a, b ] (MFunction [ c ] d))
        == ( [ a, b, c ], d )

    flattenMFunction MInt
        == ( [], MInt )

-}
flattenMFunction : Mono.MonoType -> ( List Mono.MonoType, Mono.MonoType )
flattenMFunction monoType =
    case monoType of
        Mono.MFunction params result ->
            let
                ( restParams, finalResult ) =
                    flattenMFunction result
            in
            ( params ++ restParams, finalResult )

        _ ->
            ( [], monoType )


{-| Structural equality for MonoTypes.
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

        ( Mono.MList a1, Mono.MList b1 ) ->
            monoTypeEq a1 b1

        ( Mono.MFunction aParams aResult, Mono.MFunction bParams bResult ) ->
            listEq monoTypeEq aParams bParams && monoTypeEq aResult bResult

        ( Mono.MTuple aElems, Mono.MTuple bElems ) ->
            listEq monoTypeEq aElems bElems

        ( Mono.MRecord aFields, Mono.MRecord bFields ) ->
            dictEq monoTypeEq aFields bFields

        ( Mono.MCustom aHome aName aArgs, Mono.MCustom bHome bName bArgs ) ->
            aHome == bHome && aName == bName && listEq monoTypeEq aArgs bArgs

        ( Mono.MVar aName _, Mono.MVar bName _ ) ->
            -- MVar equality: same name (constraint may differ)
            aName == bName

        _ ->
            False


{-| Compare two lists elementwise using a custom equality function.
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


{-| Compare two Dicts by checking same keys and equal values.
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


{-| Format violations as a readable string.
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


{-| Convert a Global to a readable string.
-}
globalToString : Mono.Global -> String
globalToString global =
    case global of
        Mono.Global _ name ->
            name

        Mono.Accessor name ->
            "." ++ name


{-| Convert a MonoType to a string for error messages.
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

        Mono.MList elementType ->
            "List " ++ monoTypeToString elementType

        Mono.MTuple elements ->
            "(" ++ String.join ", " (List.map monoTypeToString elements) ++ ")"

        Mono.MRecord fields ->
            let
                fieldStrs =
                    Dict.foldl
                        (\name ty acc -> (name ++ " : " ++ monoTypeToString ty) :: acc)
                        []
                        fields
            in
            "{ " ++ String.join ", " fieldStrs ++ " }"

        Mono.MCustom _ name _ ->
            name

        Mono.MFunction params result ->
            let
                paramStr =
                    case params of
                        [ single ] ->
                            monoTypeToString single

                        multiple ->
                            "(" ++ String.join ", " (List.map monoTypeToString multiple) ++ ")"
            in
            paramStr ++ " -> " ++ monoTypeToString result

        Mono.MVar name _ ->
            name
