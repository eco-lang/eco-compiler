module TestLogic.Type.PostSolve.PostSolveLambdaStructuralTypesTest exposing (suite)

{-| Test suite for invariant POST\_007.

POST\_007: The PostSolve phase guarantees that every lambda expression in the
canonical module has a concrete structural function type. PostSolve computes
a TLambda chain from argument pattern types and body type when the solver did
not supply a non-TVar type. The stored type must be alpha-equivalent to the
recomputed structural type. Group B lambdas never remain as bare TVars or
non-function shapes.

-}

import Array
import Compiler.AST.Canonical as Can
import Compiler.AST.Source as Src
import Compiler.Reporting.Annotation as A
import Compiler.Type.PostSolve as PostSolve
import Dict
import Expect
import SourceIR.Suite.StandardTestSuites as StandardTestSuites
import Test exposing (Test)
import TestLogic.Type.PostSolve.CompileThroughPostSolve as Compile
import TestLogic.Type.PostSolve.PostSolveInvariantHelpers as Helpers


{-| A violation of POST\_007.
-}
type alias Violation =
    { nodeId : Int
    , details : String
    , postType : Maybe Can.Type
    , expectedType : Maybe Can.Type
    }


suite : Test
suite =
    Test.describe "POST_007: Lambda Structural Types"
        [ StandardTestSuites.expectSuite expectLambdaStructuralTypes "lambda-structural-types"
        ]


{-| Check that a module passes POST\_007.
-}
expectLambdaStructuralTypes : Src.Module -> Expect.Expectation
expectLambdaStructuralTypes srcModule =
    case Compile.compileToPostSolve srcModule of
        Err msg ->
            Expect.fail msg

        Ok artifacts ->
            let
                -- Walk AST to find all lambda expression nodes
                lambdaNodes =
                    Helpers.walkExprs artifacts.canonical
                        |> List.filter (\n -> isLambda n.node)

                violations =
                    List.filterMap
                        (\node -> checkLambdaStructuralType node artifacts.nodeTypesPost)
                        lambdaNodes
            in
            case violations of
                [] ->
                    Expect.pass

                vs ->
                    Expect.fail (formatViolations vs)


{-| Check if an expression node is a Lambda.
-}
isLambda : Can.Expr_ -> Bool
isLambda node =
    case node of
        Can.Lambda _ _ ->
            True

        _ ->
            False


{-| Check a single lambda expression for POST\_007 compliance.

A lambda must:

1.  Have a post-PostSolve type (not missing)
2.  Have a TLambda chain type (not a bare TVar or non-function shape)
3.  Be alpha-equivalent to the recomputed structural type from arg patterns and body

-}
checkLambdaStructuralType : Helpers.ExprNode -> PostSolve.NodeTypes -> Maybe Violation
checkLambdaStructuralType exprNode nodeTypes =
    case exprNode.node of
        Can.Lambda patterns (A.At _ bodyInfo) ->
            case Array.get exprNode.id nodeTypes |> Maybe.andThen identity of
                Nothing ->
                    Just
                        { nodeId = exprNode.id
                        , details = "Lambda has no post-PostSolve type (missing from nodeTypesPost)"
                        , postType = Nothing
                        , expectedType = Nothing
                        }

                Just postType ->
                    -- Check 1: Must be a TLambda (not bare TVar or non-function)
                    if not (isTLambda postType) then
                        Just
                            { nodeId = exprNode.id
                            , details = "Lambda post type is not a TLambda chain: " ++ typeToString postType
                            , postType = Just postType
                            , expectedType = Nothing
                            }

                    else
                        -- Check 2: Recompute and verify alpha-equivalence
                        case computeExpectedLambdaType exprNode.id patterns bodyInfo.id nodeTypes of
                            LambdaTypeError errorMsg ->
                                -- Can't verify structural match, report the error
                                Just
                                    { nodeId = exprNode.id
                                    , details = "Cannot verify structural type: " ++ errorMsg
                                    , postType = Just postType
                                    , expectedType = Nothing
                                    }

                            LambdaTypeOk expectedType ->
                                case bijectiveAlphaEq postType expectedType of
                                    Ok _ ->
                                        Nothing

                                    Err reason ->
                                        Just
                                            { nodeId = exprNode.id
                                            , details = "Post type not alpha-equivalent to recomputed structural type: " ++ reason
                                            , postType = Just postType
                                            , expectedType = Just expectedType
                                            }

        _ ->
            -- Not a lambda, skip
            Nothing


{-| Check if a type is a TLambda chain.
-}
isTLambda : Can.Type -> Bool
isTLambda tipe =
    case tipe of
        Can.TLambda _ _ ->
            True

        _ ->
            False


{-| Result of computing expected lambda type.
-}
type LambdaTypeResult
    = LambdaTypeOk Can.Type
    | LambdaTypeError String


{-| Compute the expected structural type for a lambda expression.

Lambda `\p1 p2 -> body` has type `p1Type -> p2Type -> bodyType`.

-}
computeExpectedLambdaType : Int -> List Can.Pattern -> Int -> PostSolve.NodeTypes -> LambdaTypeResult
computeExpectedLambdaType lambdaId patterns bodyId nodeTypes =
    case Array.get bodyId nodeTypes |> Maybe.andThen identity of
        Nothing ->
            LambdaTypeError
                ("Lambda "
                    ++ String.fromInt lambdaId
                    ++ ": missing body type for id "
                    ++ String.fromInt bodyId
                )

        Just bodyType ->
            case collectPatternTypes lambdaId patterns nodeTypes of
                Err errorMsg ->
                    LambdaTypeError errorMsg

                Ok argTypes ->
                    LambdaTypeOk (List.foldr Can.TLambda bodyType argTypes)


{-| Collect all pattern types, failing on first error.
-}
collectPatternTypes : Int -> List Can.Pattern -> PostSolve.NodeTypes -> Result String (List Can.Type)
collectPatternTypes lambdaId patterns nodeTypes =
    patterns
        |> List.foldr
            (\(A.At _ patInfo) acc ->
                case acc of
                    Err _ ->
                        acc

                    Ok types ->
                        if patInfo.id < 0 then
                            Err
                                ("Lambda "
                                    ++ String.fromInt lambdaId
                                    ++ ": pattern has negative id "
                                    ++ String.fromInt patInfo.id
                                )

                        else
                            case Array.get patInfo.id nodeTypes |> Maybe.andThen identity of
                                Just t ->
                                    Ok (t :: types)

                                Nothing ->
                                    Err
                                        ("Lambda "
                                            ++ String.fromInt lambdaId
                                            ++ ": missing type for pattern id "
                                            ++ String.fromInt patInfo.id
                                        )
            )
            (Ok [])



-- ============================================================================
-- BIJECTIVE ALPHA EQUIVALENCE
-- ============================================================================


{-| A bijective renaming map: tracks both forward (left->right) and reverse
(right->left) mappings to ensure the TVar correspondence is injective.
-}
type alias Renaming =
    { forward : Dict.Dict String String -- left name -> right name
    , reverse : Dict.Dict String String -- right name -> left name
    }


emptyRenaming : Renaming
emptyRenaming =
    { forward = Dict.empty, reverse = Dict.empty }


{-| Check bijective alpha-equivalence: TVars must form a consistent 1-to-1
mapping between the two types. Returns Ok with the final renaming on success,
or Err with a description of the inconsistency.
-}
bijectiveAlphaEq : Can.Type -> Can.Type -> Result String Renaming
bijectiveAlphaEq a b =
    bijectiveAlphaEqHelp emptyRenaming a b


bijectiveAlphaEqHelp : Renaming -> Can.Type -> Can.Type -> Result String Renaming
bijectiveAlphaEqHelp renaming a b =
    case ( a, b ) of
        ( Can.TVar nameA, Can.TVar nameB ) ->
            case Dict.get nameA renaming.forward of
                Just mappedTo ->
                    if mappedTo == nameB then
                        Ok renaming

                    else
                        Err
                            ("TVar \""
                                ++ nameA
                                ++ "\" already mapped to \""
                                ++ mappedTo
                                ++ "\" but found paired with \""
                                ++ nameB
                                ++ "\""
                            )

                Nothing ->
                    -- nameA not yet mapped; check reverse
                    case Dict.get nameB renaming.reverse of
                        Just mappedFrom ->
                            Err
                                ("TVar \""
                                    ++ nameB
                                    ++ "\" already mapped from \""
                                    ++ mappedFrom
                                    ++ "\" but found paired with \""
                                    ++ nameA
                                    ++ "\" (not injective)"
                                )

                        Nothing ->
                            -- Fresh pairing
                            Ok
                                { forward = Dict.insert nameA nameB renaming.forward
                                , reverse = Dict.insert nameB nameA renaming.reverse
                                }

        ( Can.TType h1 n1 as1, Can.TType h2 n2 as2 ) ->
            if h1 == h2 && n1 == n2 then
                bijectiveAlphaEqList renaming as1 as2

            else
                Err ("TType mismatch: " ++ n1 ++ " vs " ++ n2)

        ( Can.TLambda a1 r1, Can.TLambda a2 r2 ) ->
            case bijectiveAlphaEqHelp renaming a1 a2 of
                Err e ->
                    Err e

                Ok renaming1 ->
                    bijectiveAlphaEqHelp renaming1 r1 r2

        ( Can.TRecord fields1 ext1, Can.TRecord fields2 ext2 ) ->
            case bijectiveAlphaEqExt renaming ext1 ext2 of
                Err e ->
                    Err e

                Ok renaming1 ->
                    bijectiveAlphaEqFields renaming1 fields1 fields2

        ( Can.TUnit, Can.TUnit ) ->
            Ok renaming

        ( Can.TTuple a1 b1 cs1, Can.TTuple a2 b2 cs2 ) ->
            case bijectiveAlphaEqHelp renaming a1 a2 of
                Err e ->
                    Err e

                Ok r1 ->
                    case bijectiveAlphaEqHelp r1 b1 b2 of
                        Err e ->
                            Err e

                        Ok r2 ->
                            bijectiveAlphaEqList r2 cs1 cs2

        ( Can.TAlias h1 n1 args1 at1, Can.TAlias h2 n2 args2 at2 ) ->
            if h1 == h2 && n1 == n2 then
                case bijectiveAlphaEqArgs renaming args1 args2 of
                    Err e ->
                        Err e

                    Ok r1 ->
                        bijectiveAlphaEqAlias r1 at1 at2

            else
                Err ("TAlias mismatch: " ++ n1 ++ " vs " ++ n2)

        _ ->
            Err "Type constructor mismatch"


bijectiveAlphaEqList : Renaming -> List Can.Type -> List Can.Type -> Result String Renaming
bijectiveAlphaEqList renaming xs ys =
    case ( xs, ys ) of
        ( [], [] ) ->
            Ok renaming

        ( x :: xr, y :: yr ) ->
            case bijectiveAlphaEqHelp renaming x y of
                Err e ->
                    Err e

                Ok r1 ->
                    bijectiveAlphaEqList r1 xr yr

        _ ->
            Err "Type argument list length mismatch"


bijectiveAlphaEqExt : Renaming -> Maybe String -> Maybe String -> Result String Renaming
bijectiveAlphaEqExt renaming ext1 ext2 =
    case ( ext1, ext2 ) of
        ( Nothing, Nothing ) ->
            Ok renaming

        ( Just e1, Just e2 ) ->
            -- Record extension vars are type variables; check bijection
            bijectiveAlphaEqHelp renaming (Can.TVar e1) (Can.TVar e2)

        _ ->
            Err "Record extension mismatch"


bijectiveAlphaEqFields :
    Renaming
    -> Dict.Dict String Can.FieldType
    -> Dict.Dict String Can.FieldType
    -> Result String Renaming
bijectiveAlphaEqFields renaming fields1 fields2 =
    let
        list1 =
            Dict.toList fields1

        list2 =
            Dict.toList fields2
    in
    if List.length list1 /= List.length list2 then
        Err "Record field count mismatch"

    else
        List.foldl
            (\( ( k1, Can.FieldType _ t1 ), ( k2, Can.FieldType _ t2 ) ) acc ->
                case acc of
                    Err e ->
                        Err e

                    Ok r ->
                        if k1 /= k2 then
                            Err ("Record field name mismatch: " ++ k1 ++ " vs " ++ k2)

                        else
                            bijectiveAlphaEqHelp r t1 t2
            )
            (Ok renaming)
            (List.map2 Tuple.pair list1 list2)


bijectiveAlphaEqArgs : Renaming -> List ( String, Can.Type ) -> List ( String, Can.Type ) -> Result String Renaming
bijectiveAlphaEqArgs renaming args1 args2 =
    case ( args1, args2 ) of
        ( [], [] ) ->
            Ok renaming

        ( ( _, t1 ) :: r1, ( _, t2 ) :: r2 ) ->
            case bijectiveAlphaEqHelp renaming t1 t2 of
                Err e ->
                    Err e

                Ok r ->
                    bijectiveAlphaEqArgs r r1 r2

        _ ->
            Err "Alias argument list length mismatch"


bijectiveAlphaEqAlias : Renaming -> Can.AliasType -> Can.AliasType -> Result String Renaming
bijectiveAlphaEqAlias renaming at1 at2 =
    case ( at1, at2 ) of
        ( Can.Holey t1, Can.Holey t2 ) ->
            bijectiveAlphaEqHelp renaming t1 t2

        ( Can.Filled t1, Can.Filled t2 ) ->
            bijectiveAlphaEqHelp renaming t1 t2

        _ ->
            Err "Alias type variant mismatch"



-- ============================================================================
-- FORMATTING
-- ============================================================================


formatViolations : List Violation -> String
formatViolations violations =
    let
        header =
            "POST_007 violations: "
                ++ String.fromInt (List.length violations)
                ++ " lambda(s) without proper structural types\n\n"
    in
    header ++ (violations |> List.map formatViolation |> String.join "\n\n")


formatViolation : Violation -> String
formatViolation v =
    "POST_007 violation at nodeId "
        ++ String.fromInt v.nodeId
        ++ ":\n  postType:     "
        ++ maybeTypeToString v.postType
        ++ "\n  expectedType: "
        ++ maybeTypeToString v.expectedType
        ++ "\n  details:      "
        ++ v.details


maybeTypeToString : Maybe Can.Type -> String
maybeTypeToString mt =
    case mt of
        Just t ->
            typeToString t

        Nothing ->
            "(none)"


typeToString : Can.Type -> String
typeToString tipe =
    case tipe of
        Can.TVar name ->
            "TVar \"" ++ name ++ "\""

        Can.TType _ name args ->
            "TType ("
                ++ name
                ++ ") ["
                ++ String.join ", " (List.map typeToString args)
                ++ "]"

        Can.TLambda a b ->
            "TLambda (" ++ typeToString a ++ " -> " ++ typeToString b ++ ")"

        Can.TRecord _ ext ->
            case ext of
                Nothing ->
                    "TRecord {...}"

                Just extName ->
                    "TRecord { " ++ extName ++ " | ... }"

        Can.TUnit ->
            "TUnit"

        Can.TTuple a b cs ->
            "TTuple ("
                ++ String.join ", " (List.map typeToString (a :: b :: cs))
                ++ ")"

        Can.TAlias _ name _ _ ->
            "TAlias " ++ name
