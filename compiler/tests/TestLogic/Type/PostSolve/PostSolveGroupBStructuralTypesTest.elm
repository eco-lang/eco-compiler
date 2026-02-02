module TestLogic.Type.PostSolve.PostSolveGroupBStructuralTypesTest exposing (suite)

{-| Test suite for invariant POST\_001.

POST\_001: For Group B expressions whose solver output still contains a synthetic
placeholder (TVar), PostSolve must replace that placeholder with the structural
type implied by the AST + children's types.

Group B expressions are: Str, Chr, Float, Unit, List, Tuple, Record, Lambda,
Accessor, Let, LetRec, LetDestruct.

-}

import Compiler.AST.Canonical as Can
import Compiler.AST.Source as Src
import Compiler.Data.Name as Name
import Compiler.Elm.ModuleName as ModuleName
import Compiler.Reporting.Annotation as A
import Compiler.Type.PostSolve as PostSolve
import Data.Map as Dict
import Data.Set as EverySet
import Expect
import SourceIR.Suite.StandardTestSuites as StandardTestSuites
import Test exposing (Test)
import TestLogic.Type.PostSolve.CompileThroughPostSolve as Compile
import TestLogic.Type.PostSolve.PostSolveInvariantHelpers as Helpers


{-| A violation of POST\_001.
-}
type alias Violation =
    { nodeId : Int
    , exprKind : String
    , preType : Can.Type
    , postType : Can.Type
    , expectedType : Maybe Can.Type
    , details : String
    }


suite : Test
suite =
    Test.describe "POST_001: Group B Structural Types"
        [ StandardTestSuites.expectSuite expectGroupBStructuralTypes "group-b-structural"
        ]


{-| Check that a module passes POST\_001.
-}
expectGroupBStructuralTypes : Src.Module -> Expect.Expectation
expectGroupBStructuralTypes srcModule =
    case Compile.compileToPostSolveDetailed srcModule of
        Err msg ->
            Expect.fail msg

        Ok artifacts ->
            let
                -- Build a map from expression ID to expression node
                exprNodes =
                    Helpers.walkExprs artifacts.canonical
                        |> List.map (\n -> ( n.id, n ))
                        |> Dict.fromList identity

                -- Filter to only Group B expressions that were synthetic
                syntheticGroupBIds =
                    artifacts.syntheticExprIds
                        |> EverySet.toList compare
                        |> List.filter
                            (\exprId ->
                                case Dict.get identity exprId exprNodes of
                                    Just exprNode ->
                                        Helpers.isGroupBExprNode exprNode.node

                                    Nothing ->
                                        False
                            )

                violations =
                    List.filterMap
                        (\exprId -> checkGroupBExpr exprId exprNodes artifacts)
                        syntheticGroupBIds
            in
            case violations of
                [] ->
                    Expect.pass

                vs ->
                    Expect.fail (formatViolations vs)


{-| Check a single Group B expression.

Returns a violation if:

1.  The pre-type was a bare TVar (placeholder)
2.  The post-type doesn't match the expected structural type

-}
checkGroupBExpr :
    Int
    -> Dict.Dict Int Int Helpers.ExprNode
    -> Compile.DetailedArtifacts
    -> Maybe Violation
checkGroupBExpr exprId exprNodes artifacts =
    case Dict.get identity exprId exprNodes of
        Nothing ->
            -- Expression not found (shouldn't happen)
            Just
                { nodeId = exprId
                , exprKind = "Unknown"
                , preType = Can.TUnit
                , postType = Can.TUnit
                , expectedType = Nothing
                , details = "Expression node not found in AST"
                }

        Just exprNode ->
            case Dict.get identity exprId artifacts.nodeTypesPre of
                Nothing ->
                    -- No pre-type (shouldn't happen for synthetic expressions)
                    Nothing

                Just preType ->
                    case preType of
                        Can.TVar _ ->
                            -- Pre-type is a bare TVar placeholder, check post-type
                            checkSyntheticPlaceholder exprId exprNode preType exprNodes artifacts

                        _ ->
                            -- Pre-type is structured, PostSolve shouldn't rewrite it
                            -- (This is POST_005's domain, not POST_001)
                            Nothing


{-| Check that a synthetic placeholder was properly filled by PostSolve.
-}
checkSyntheticPlaceholder :
    Int
    -> Helpers.ExprNode
    -> Can.Type
    -> Dict.Dict Int Int Helpers.ExprNode
    -> Compile.DetailedArtifacts
    -> Maybe Violation
checkSyntheticPlaceholder exprId exprNode preType exprNodes artifacts =
    case Dict.get identity exprId artifacts.nodeTypesPost of
        Nothing ->
            Just
                { nodeId = exprId
                , exprKind = exprKindToString exprNode.node
                , preType = preType
                , postType = Can.TUnit
                , expectedType = Nothing
                , details = "Post-type not found (node disappeared from nodeTypesPost)"
                }

        Just postType ->
            -- Handle Accessor and Lambda specially with stricter checks
            case exprNode.node of
                Can.Accessor fieldName ->
                    -- Use strict structural check for Accessor
                    if isAccessorType fieldName postType then
                        Nothing

                    else
                        Just
                            { nodeId = exprId
                            , exprKind = "Accessor"
                            , preType = preType
                            , postType = postType
                            , expectedType = Nothing
                            , details = "Accessor type must be { ext | field : a } -> a (same TVar in both positions)"
                            }

                Can.Lambda patterns (A.At _ bodyInfo) ->
                    -- Use strict structural check for Lambda with explicit error handling
                    case expectedLambdaType exprId patterns bodyInfo.id artifacts.nodeTypesPost of
                        LambdaTypeError errorMsg ->
                            Just
                                { nodeId = exprId
                                , exprKind = "Lambda"
                                , preType = preType
                                , postType = postType
                                , expectedType = Nothing
                                , details = errorMsg
                                }

                        LambdaTypeOk expectedType ->
                            if alphaEq postType expectedType then
                                Nothing

                            else
                                Just
                                    { nodeId = exprId
                                    , exprKind = "Lambda"
                                    , preType = preType
                                    , postType = postType
                                    , expectedType = Just expectedType
                                    , details = "Post-type doesn't match expected structural type"
                                    }

                _ ->
                    -- Use existing alphaEq-based check for other Group B expressions
                    let
                        maybeExpected =
                            computeExpectedType exprNode.node artifacts.nodeTypesPost exprNodes
                    in
                    case maybeExpected of
                        Nothing ->
                            -- Could not compute expected type
                            -- This shouldn't happen for non-Lambda/Accessor Group B expressions
                            Nothing

                        Just expectedType ->
                            if alphaEq postType expectedType then
                                Nothing

                            else
                                Just
                                    { nodeId = exprId
                                    , exprKind = exprKindToString exprNode.node
                                    , preType = preType
                                    , postType = postType
                                    , expectedType = Just expectedType
                                    , details = "Post-type doesn't match expected structural type"
                                    }


{-| Compute the expected structural type for a Group B expression.

Based on the expression AST and children's types from nodeTypesPost.

-}
computeExpectedType :
    Can.Expr_
    -> PostSolve.NodeTypes
    -> Dict.Dict Int Int Helpers.ExprNode
    -> Maybe Can.Type
computeExpectedType expr nodeTypes exprNodes =
    case expr of
        Can.Str _ ->
            Just (Can.TType ModuleName.string Name.string [])

        Can.Chr _ ->
            Just (Can.TType ModuleName.char Name.char [])

        Can.Float _ ->
            Just (Can.TType ModuleName.basics Name.float [])

        Can.Unit ->
            Just Can.TUnit

        Can.List [] ->
            -- Empty list: should be List a (polymorphic)
            Just (Can.TType ModuleName.list Name.list [ Can.TVar "a" ])

        Can.List ((A.At _ firstInfo) :: _) ->
            -- Non-empty list: element type from first element
            case Dict.get identity firstInfo.id nodeTypes of
                Just elemType ->
                    Just (Can.TType ModuleName.list Name.list [ elemType ])

                Nothing ->
                    Nothing

        Can.Tuple (A.At _ aInfo) (A.At _ bInfo) cs ->
            let
                maybeA =
                    Dict.get identity aInfo.id nodeTypes

                maybeB =
                    Dict.get identity bInfo.id nodeTypes

                maybeCs =
                    List.foldr
                        (\(A.At _ cInfo) acc ->
                            case acc of
                                Nothing ->
                                    Nothing

                                Just cTypes ->
                                    case Dict.get identity cInfo.id nodeTypes of
                                        Just cType ->
                                            Just (cType :: cTypes)

                                        Nothing ->
                                            Nothing
                        )
                        (Just [])
                        cs
            in
            case ( maybeA, maybeB, maybeCs ) of
                ( Just aType, Just bType, Just csTypes ) ->
                    Just (Can.TTuple aType bType csTypes)

                _ ->
                    Nothing

        Can.Record fields ->
            let
                maybeFieldTypes =
                    Dict.foldl A.compareLocated
                        (\(A.At _ fieldName) (A.At _ fieldExprInfo) acc ->
                            case acc of
                                Nothing ->
                                    Nothing

                                Just fieldDict ->
                                    case Dict.get identity fieldExprInfo.id nodeTypes of
                                        Just fieldType ->
                                            Just
                                                (Dict.insert identity
                                                    fieldName
                                                    (Can.FieldType 0 fieldType)
                                                    fieldDict
                                                )

                                        Nothing ->
                                            Nothing
                        )
                        (Just Dict.empty)
                        fields
            in
            case maybeFieldTypes of
                Just fieldTypes ->
                    Just (Can.TRecord fieldTypes Nothing)

                Nothing ->
                    Nothing

        Can.Lambda patterns (A.At _ bodyInfo) ->
            -- Lambda: List.foldr TLambda bodyType argTypes
            -- Get body type
            case Dict.get identity bodyInfo.id nodeTypes of
                Just bodyType ->
                    -- For lambda, we need the pattern types as arg types
                    -- But patterns don't always have direct types in nodeTypes
                    -- Skip precise verification for now
                    Nothing

                Nothing ->
                    Nothing

        Can.Accessor _ ->
            -- Accessor: { ext | field : a } -> a
            -- Complex polymorphic type, skip precise verification
            Nothing

        Can.Let _ (A.At _ bodyInfo) ->
            Dict.get identity bodyInfo.id nodeTypes

        Can.LetRec _ (A.At _ bodyInfo) ->
            Dict.get identity bodyInfo.id nodeTypes

        Can.LetDestruct _ _ (A.At _ bodyInfo) ->
            Dict.get identity bodyInfo.id nodeTypes

        _ ->
            -- Not a Group B expression
            Nothing



-- ============================================================================
-- ACCESSOR TYPE CHECKING
-- ============================================================================


{-| Check if a type matches the exact Accessor structural shape.

Accessor `.field` must have type `{ ext | field : a } -> a` where:

  - The record has an extension variable (not closed)
  - The field type is a TVar
  - The return type is the SAME TVar as the field type

This is stricter than generic alpha-equivalence because we enforce
that the field type and return type are the same variable.

-}
isAccessorType : Name.Name -> Can.Type -> Bool
isAccessorType fieldName tipe =
    case tipe of
        Can.TLambda recordType retType ->
            case ( recordType, retType ) of
                ( Can.TRecord fields maybeExt, Can.TVar retVar ) ->
                    case maybeExt of
                        Nothing ->
                            -- Must have extension variable
                            False

                        Just _ ->
                            case Dict.get identity fieldName fields of
                                Just (Can.FieldType _ fieldTipe) ->
                                    case fieldTipe of
                                        Can.TVar fieldVar ->
                                            -- Critical invariant: same TVar in both positions
                                            fieldVar == retVar

                                        _ ->
                                            False

                                Nothing ->
                                    False

                _ ->
                    False

        _ ->
            False



-- ============================================================================
-- LAMBDA TYPE CHECKING
-- ============================================================================


{-| Result of looking up a pattern type, with explicit failure modes.
-}
type PatternTypeLookup
    = PatternTypeFound Can.Type
    | PatternTypeNegativeId Int
    | PatternTypeMissing Int


{-| Look up a pattern's type from nodeTypes with strict error handling.

Lambda parameters should have non-negative IDs and be present in nodeTypes.
Returns an explicit error if either condition is violated.

-}
lookupPatternType : Can.Pattern -> PostSolve.NodeTypes -> PatternTypeLookup
lookupPatternType (A.At _ patInfo) nodeTypes =
    if patInfo.id < 0 then
        PatternTypeNegativeId patInfo.id

    else
        case Dict.get identity patInfo.id nodeTypes of
            Just t ->
                PatternTypeFound t

            Nothing ->
                PatternTypeMissing patInfo.id


{-| Result of computing expected lambda type.
-}
type LambdaTypeResult
    = LambdaTypeOk Can.Type
    | LambdaTypeError String


{-| Compute the expected structural type for a lambda expression.

Lambda `\p1 p2 -> body` has type `p1Type -> p2Type -> bodyType`,
built as a curried chain of TLambda constructors.

Fails loudly if any pattern has a negative ID or missing type.

-}
expectedLambdaType : Int -> List Can.Pattern -> Int -> PostSolve.NodeTypes -> LambdaTypeResult
expectedLambdaType lambdaExprId patterns bodyId nodeTypes =
    case Dict.get identity bodyId nodeTypes of
        Nothing ->
            LambdaTypeError
                ("Lambda " ++ String.fromInt lambdaExprId ++ ": missing body type for id " ++ String.fromInt bodyId)

        Just bodyType ->
            case collectPatternTypes lambdaExprId patterns nodeTypes of
                Err errorMsg ->
                    LambdaTypeError errorMsg

                Ok argTypes ->
                    LambdaTypeOk (buildCurriedFunctionType argTypes bodyType)


{-| Collect all pattern types, failing on first error.
-}
collectPatternTypes : Int -> List Can.Pattern -> PostSolve.NodeTypes -> Result String (List Can.Type)
collectPatternTypes lambdaExprId patterns nodeTypes =
    patterns
        |> List.foldr
            (\pat acc ->
                case acc of
                    Err _ ->
                        acc

                    Ok types ->
                        case lookupPatternType pat nodeTypes of
                            PatternTypeFound t ->
                                Ok (t :: types)

                            PatternTypeNegativeId patId ->
                                Err
                                    ("Lambda "
                                        ++ String.fromInt lambdaExprId
                                        ++ ": parameter pattern has negative id "
                                        ++ String.fromInt patId
                                        ++ " (unexpected synthetic pattern as lambda param)"
                                    )

                            PatternTypeMissing patId ->
                                Err
                                    ("Lambda "
                                        ++ String.fromInt lambdaExprId
                                        ++ ": missing type for parameter pattern id "
                                        ++ String.fromInt patId
                                    )
            )
            (Ok [])


{-| Build a curried function type from argument types and body type.

    buildCurriedFunctionType [a, b, c] ret = a -> b -> c -> ret

-}
buildCurriedFunctionType : List Can.Type -> Can.Type -> Can.Type
buildCurriedFunctionType argTypes bodyType =
    List.foldr Can.TLambda bodyType argTypes



-- ============================================================================
-- ALPHA EQUIVALENCE (simplified)
-- ============================================================================


{-| Check if two types are alpha-equivalent.
-}
alphaEq : Can.Type -> Can.Type -> Bool
alphaEq a b =
    case ( a, b ) of
        ( Can.TVar _, Can.TVar _ ) ->
            True

        ( Can.TType h1 n1 as1, Can.TType h2 n2 as2 ) ->
            h1 == h2 && n1 == n2 && alphaEqList as1 as2

        ( Can.TLambda a1 r1, Can.TLambda a2 r2 ) ->
            alphaEq a1 a2 && alphaEq r1 r2

        ( Can.TRecord fields1 ext1, Can.TRecord fields2 ext2 ) ->
            alphaEqExt ext1 ext2 && alphaEqFields fields1 fields2

        ( Can.TUnit, Can.TUnit ) ->
            True

        ( Can.TTuple a1 b1 cs1, Can.TTuple a2 b2 cs2 ) ->
            alphaEq a1 a2 && alphaEq b1 b2 && alphaEqList cs1 cs2

        ( Can.TAlias h1 n1 args1 at1, Can.TAlias h2 n2 args2 at2 ) ->
            h1 == h2 && n1 == n2 && alphaEqArgs args1 args2 && alphaEqAlias at1 at2

        _ ->
            False


alphaEqList : List Can.Type -> List Can.Type -> Bool
alphaEqList xs ys =
    case ( xs, ys ) of
        ( [], [] ) ->
            True

        ( x :: xr, y :: yr ) ->
            alphaEq x y && alphaEqList xr yr

        _ ->
            False


alphaEqExt : Maybe Name.Name -> Maybe Name.Name -> Bool
alphaEqExt ext1 ext2 =
    case ( ext1, ext2 ) of
        ( Nothing, Nothing ) ->
            True

        ( Just _, Just _ ) ->
            True

        _ ->
            False


alphaEqFields :
    Dict.Dict String Name.Name Can.FieldType
    -> Dict.Dict String Name.Name Can.FieldType
    -> Bool
alphaEqFields fields1 fields2 =
    let
        list1 =
            Dict.toList compare fields1

        list2 =
            Dict.toList compare fields2
    in
    if List.length list1 /= List.length list2 then
        False

    else
        List.all
            (\( ( k1, Can.FieldType _ t1 ), ( k2, Can.FieldType _ t2 ) ) ->
                k1 == k2 && alphaEq t1 t2
            )
            (List.map2 Tuple.pair list1 list2)


alphaEqArgs : List ( Name.Name, Can.Type ) -> List ( Name.Name, Can.Type ) -> Bool
alphaEqArgs args1 args2 =
    case ( args1, args2 ) of
        ( [], [] ) ->
            True

        ( ( _, t1 ) :: r1, ( _, t2 ) :: r2 ) ->
            alphaEq t1 t2 && alphaEqArgs r1 r2

        _ ->
            False


alphaEqAlias : Can.AliasType -> Can.AliasType -> Bool
alphaEqAlias at1 at2 =
    case ( at1, at2 ) of
        ( Can.Holey t1, Can.Holey t2 ) ->
            alphaEq t1 t2

        ( Can.Filled t1, Can.Filled t2 ) ->
            alphaEq t1 t2

        _ ->
            False



-- ============================================================================
-- FORMATTING
-- ============================================================================


formatViolations : List Violation -> String
formatViolations violations =
    violations
        |> List.map formatViolation
        |> String.join "\n\n"


formatViolation : Violation -> String
formatViolation v =
    let
        expectedStr =
            case v.expectedType of
                Just t ->
                    typeToString t

                Nothing ->
                    "(not computed)"
    in
    "POST_001 violation at nodeId "
        ++ String.fromInt v.nodeId
        ++ " ("
        ++ v.exprKind
        ++ "):\n  preType:      "
        ++ typeToString v.preType
        ++ "\n  postType:     "
        ++ typeToString v.postType
        ++ "\n  expectedType: "
        ++ expectedStr
        ++ "\n  details:      "
        ++ v.details


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


exprKindToString : Can.Expr_ -> String
exprKindToString expr =
    case expr of
        Can.Str _ ->
            "Str"

        Can.Chr _ ->
            "Chr"

        Can.Float _ ->
            "Float"

        Can.Unit ->
            "Unit"

        Can.List _ ->
            "List"

        Can.Tuple _ _ _ ->
            "Tuple"

        Can.Record _ ->
            "Record"

        Can.Lambda _ _ ->
            "Lambda"

        Can.Accessor _ ->
            "Accessor"

        Can.Let _ _ ->
            "Let"

        Can.LetRec _ _ ->
            "LetRec"

        Can.LetDestruct _ _ _ ->
            "LetDestruct"

        _ ->
            "Other"
