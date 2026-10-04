module TestLogic.Type.PostSolve.PostSolveGroupBStructuralTypesTest exposing (suite)

{-| `Compiler.Type.PostSolve` overwrites the type the solver recorded for each
string, character and float literal and each unit with `String`, `Char`,
`Float` or `()`. These tests check, on the standard case programs, that such a
literal whose solver type is a bare type variable comes out of PostSolve with
the type its form implies, rather than the variable or some other type.

The terms are those of `Compiler.Type.PostSolve`. A _Group B_ node is one whose
recorded type is a _synthetic placeholder_: a fresh type variable that
constraint generation allocates for the node and constrains to the type its
context expects. Placeholders are allocated for `Str`, `Chr`, `Float`, `Unit`
and `Shader` nodes and for variable references.
`TestLogic.Type.PostSolve.CompileThroughPostSolve.compileToPostSolveDetailed`
returns the ids of those nodes, together with every node's type before
PostSolve, its _pre-type_, and after, its _post-type_.

The fixture is every program of the case modules that
`SourceIR.Suite.StandardTestSuites.expectSuite` gathers, each checked by
`expectGroupBStructuralTypes`:

  - The program must canonicalize and type check; an error fails the test.
  - Of the placeholder ids, only the nodes that
    `PostSolveInvariantHelpers.isGroupBExprNode` accepts are kept, which
    leaves the `Str`, `Chr`, `Float` and `Unit` nodes.
  - A kept node is checked only when its pre-type is a bare `TVar`. Its
    post-type must then exist and match `String`, `Char`, `Float` or `()`, by
    the node's form, under `alphaEq`.

The pre-type condition narrows the check. Constraint generation equates each
of these placeholders with the literal's own type, so in a program that type
checks the pre-type is expected to be that type already rather than a variable,
and such a node is skipped. When no kept node has a bare variable as its
pre-type, the test passes whenever the program compiles.

Much of the file is expected-type logic for lists, tuples, records,
lambdas, accessors and `let` forms (`isAccessorType`, `expectedLambdaType` and
arms of `computeExpectedType`). No placeholder is allocated for those forms, so
no node reaches that logic.

Among what is not tested:

  - `Shader` nodes and variable references, which have placeholders but are
    filtered out.
  - The post-type of a literal whose pre-type is not a bare variable.
  - Type variable names: `alphaEq` treats any two type variables as equal.

-}

import Array
import Compiler.AST.Canonical as Can
import Compiler.AST.Source as Src
import Compiler.Data.Name as Name exposing (Name)
import Compiler.Elm.ModuleName as ModuleName
import Compiler.Reporting.Annotation as A
import Compiler.Type.PostSolve as PostSolve
import Data.Map as DataMap
import Data.Set as EverySet
import Dict
import Expect
import SourceIR.Suite.StandardTestSuites as StandardTestSuites
import Test exposing (Test)
import TestLogic.Type.PostSolve.CompileThroughPostSolve as Compile
import TestLogic.Type.PostSolve.PostSolveInvariantHelpers as Helpers


{-| One node that failed the check, with what is needed to report it.

`exprKind` is the node's form as `exprKindToString` names it, or "Unknown"
for a node missing from the walk. Where a type could not be read, a stand-in
takes its place: `preType` and `postType` are `Can.TUnit` for a node missing
from the walk, and `postType` is `Can.TUnit` for a node with no post-type. `expectedType` is `Nothing` when no expected type was
computed.

-}
type alias Violation =
    { nodeId : Int
    , exprKind : String
    , preType : Can.Type Name
    , postType : Can.Type Name
    , expectedType : Maybe (Can.Type Name)
    , details : String
    }


{-| The test group that runs `expectGroupBStructuralTypes` over every standard
case program.
-}
suite : Test
suite =
    Test.describe "POST_001: Group B Structural Types"
        [ StandardTestSuites.expectSuite expectGroupBStructuralTypes "group-b-structural"
        ]


{-| Expects `srcModule` to compile through PostSolve and every kept placeholder
node with a bare type variable as its pre-type to get the post-type its form
implies, as the module docstring sets out.

A compile error fails with its message; violations fail with all of them
formatted, in increasing node id order.

-}
expectGroupBStructuralTypes : Src.Module -> Expect.Expectation
expectGroupBStructuralTypes srcModule =
    case Compile.compileToPostSolveDetailed srcModule of
        Err msg ->
            Expect.fail msg

        Ok artifacts ->
            let
                exprNodes =
                    Helpers.walkExprs artifacts.canonical
                        |> List.map (\n -> ( n.id, n ))
                        |> DataMap.fromList identity

                -- isGroupBExprNode rejects Shader and variable references, so only Str, Chr, Float and Unit remain.
                syntheticGroupBIds =
                    artifacts.syntheticExprIds
                        |> EverySet.toList compare
                        |> List.filter
                            (\exprId ->
                                case DataMap.get identity exprId exprNodes of
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


{-| Returns the violation, if any, for the node `exprId`.

A node with no pre-type, or whose pre-type is anything but a bare `TVar`, gives
`Nothing`. A bare `TVar` hands the node to `checkSyntheticPlaceholder`. A node
missing from `exprNodes` is itself a violation.

-}
checkGroupBExpr :
    Int
    -> DataMap.Dict Int Int Helpers.ExprNode
    -> Compile.DetailedArtifacts
    -> Maybe Violation
checkGroupBExpr exprId exprNodes artifacts =
    case DataMap.get identity exprId exprNodes of
        Nothing ->
            -- Unreachable from expectGroupBStructuralTypes, which keeps only ids found in exprNodes.
            Just
                { nodeId = exprId
                , exprKind = "Unknown"
                , preType = Can.TUnit
                , postType = Can.TUnit
                , expectedType = Nothing
                , details = "Expression node not found in AST"
                }

        Just exprNode ->
            case Array.get exprId artifacts.nodeTypesPre |> Maybe.andThen identity of
                Nothing ->
                    Nothing

                Just preType ->
                    case preType of
                        Can.TVar _ ->
                            checkSyntheticPlaceholder exprId exprNode preType exprNodes artifacts

                        _ ->
                            Nothing


{-| Returns the violation, if any, for a node whose pre-type `preType` is a bare
type variable, by comparing its post-type with the type its form implies.

A missing post-type is a violation. An `Accessor` must pass `isAccessorType`.
A `Lambda` must match `expectedLambdaType` under `alphaEq`, and a failure to
build that type is a violation. Any other form must match
`computeExpectedType` under `alphaEq`; where that gives `Nothing`, the node
passes.

-}
checkSyntheticPlaceholder :
    Int
    -> Helpers.ExprNode
    -> Can.Type Name
    -> DataMap.Dict Int Int Helpers.ExprNode
    -> Compile.DetailedArtifacts
    -> Maybe Violation
checkSyntheticPlaceholder exprId exprNode preType exprNodes artifacts =
    case Array.get exprId artifacts.nodeTypesPost |> Maybe.andThen identity of
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
            case exprNode.node of
                Can.Accessor fieldName ->
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
                    let
                        maybeExpected =
                            computeExpectedType exprNode.node artifacts.nodeTypesPost exprNodes
                    in
                    case maybeExpected of
                        Nothing ->
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


{-| Returns the type the expression form `expr` implies, reading the types of
its children from `nodeTypes`, or `Nothing` where it gives none.

A literal or unit gives its fixed type. An empty list gives `List a`, a
non-empty list `List` of its first element's type, a tuple the types of its
parts, a record a closed record of its fields' types, each at position 0, and a
`let` form its body's type; each gives `Nothing` when a type it reads is
missing. A lambda, an accessor and any other form give `Nothing`. The third
argument is not used.

-}
computeExpectedType :
    Can.Expr_
    -> PostSolve.NodeTypes
    -> DataMap.Dict Int Int Helpers.ExprNode
    -> Maybe (Can.Type Name)
computeExpectedType expr nodeTypes _ =
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
            Just (Can.TType ModuleName.list Name.list [ Can.TVar "a" ])

        Can.List ((A.At _ firstInfo) :: _) ->
            case Array.get firstInfo.id nodeTypes |> Maybe.andThen identity of
                Just elemType ->
                    Just (Can.TType ModuleName.list Name.list [ elemType ])

                Nothing ->
                    Nothing

        Can.Tuple (A.At _ aInfo) (A.At _ bInfo) cs ->
            let
                maybeA =
                    Array.get aInfo.id nodeTypes |> Maybe.andThen identity

                maybeB =
                    Array.get bInfo.id nodeTypes |> Maybe.andThen identity

                maybeCs =
                    List.foldr
                        (\(A.At _ cInfo) acc ->
                            case acc of
                                Nothing ->
                                    Nothing

                                Just cTypes ->
                                    case Array.get cInfo.id nodeTypes |> Maybe.andThen identity of
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
                    DataMap.foldl A.compareLocated
                        (\(A.At _ fieldName) (A.At _ fieldExprInfo) acc ->
                            case acc of
                                Nothing ->
                                    Nothing

                                Just fieldDict ->
                                    case Array.get fieldExprInfo.id nodeTypes |> Maybe.andThen identity of
                                        Just fieldType ->
                                            Just
                                                (Dict.insert
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

        Can.Lambda _ (A.At _ bodyInfo) ->
            case Array.get bodyInfo.id nodeTypes |> Maybe.andThen identity of
                Just _ ->
                    Nothing

                Nothing ->
                    Nothing

        Can.Accessor _ ->
            Nothing

        Can.Let _ (A.At _ bodyInfo) ->
            Array.get bodyInfo.id nodeTypes |> Maybe.andThen identity

        Can.LetRec _ (A.At _ bodyInfo) ->
            Array.get bodyInfo.id nodeTypes |> Maybe.andThen identity

        Can.LetDestruct _ _ (A.At _ bodyInfo) ->
            Array.get bodyInfo.id nodeTypes |> Maybe.andThen identity

        _ ->
            Nothing



-- ============================================================================
-- ACCESSOR TYPE CHECKING
-- ============================================================================


{-| Returns whether `tipe` has the shape of the accessor `.fieldName`'s type,
`{ ext | fieldName : a } -> a`.

The argument must be a record with an extension variable and a field
`fieldName` whose type is a `TVar`, and the result must be a `TVar` with the
same name. Other fields of the record are not looked at. Unlike `alphaEq`, this
requires the two variables to be the same one.

-}
isAccessorType : Name.Name -> Can.Type Name -> Bool
isAccessorType fieldName tipe =
    case tipe of
        Can.TLambda _ recordType retType ->
            case ( recordType, retType ) of
                ( Can.TRecord fields maybeExt, Can.TVar retVar ) ->
                    case maybeExt of
                        Nothing ->
                            False

                        Just _ ->
                            case Dict.get fieldName fields of
                                Just (Can.FieldType _ fieldTipe) ->
                                    case fieldTipe of
                                        Can.TVar fieldVar ->
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


{-| What looking up a lambda parameter's type in the node types found.

`PatternTypeFound` carries the type. `PatternTypeNegativeId` carries the
pattern's id when it is negative, and `PatternTypeMissing` its id when the
node types hold no type for it.

-}
type PatternTypeLookup
    = PatternTypeFound (Can.Type Name)
    | PatternTypeNegativeId Int
    | PatternTypeMissing Int


{-| Looks up the type of a parameter pattern in `nodeTypes` by the pattern's
id, saying which way the lookup failed when it does.
-}
lookupPatternType : Can.Pattern -> PostSolve.NodeTypes -> PatternTypeLookup
lookupPatternType (A.At _ patInfo) nodeTypes =
    if patInfo.id < 0 then
        PatternTypeNegativeId patInfo.id

    else
        case Array.get patInfo.id nodeTypes |> Maybe.andThen identity of
            Just t ->
                PatternTypeFound t

            Nothing ->
                PatternTypeMissing patInfo.id


{-| The type a lambda is expected to have, or why it could not be built.

`LambdaTypeOk` carries the expected type. `LambdaTypeError` carries a message
naming the lambda and the missing or negative id that stopped it.

-}
type LambdaTypeResult
    = LambdaTypeOk (Can.Type Name)
    | LambdaTypeError String


{-| Returns the type the lambda `lambdaExprId` is expected to have, given its
parameter `patterns` and the id of its body.

For `\p1 p2 -> body` that is `p1Type -> p2Type -> bodyType`, with each type
read from `nodeTypes`. A missing body type, or a parameter with a negative id
or no type, gives `LambdaTypeError` instead.

-}
expectedLambdaType : Int -> List Can.Pattern -> Int -> PostSolve.NodeTypes -> LambdaTypeResult
expectedLambdaType lambdaExprId patterns bodyId nodeTypes =
    case Array.get bodyId nodeTypes |> Maybe.andThen identity of
        Nothing ->
            LambdaTypeError
                ("Lambda " ++ String.fromInt lambdaExprId ++ ": missing body type for id " ++ String.fromInt bodyId)

        Just bodyType ->
            case collectPatternTypes lambdaExprId patterns nodeTypes of
                Err errorMsg ->
                    LambdaTypeError errorMsg

                Ok argTypes ->
                    LambdaTypeOk (buildCurriedFunctionType argTypes bodyType)


{-| Returns the types of `patterns`, in order, read from `nodeTypes`, or a
message for the last pattern in the list whose lookup failed.
-}
collectPatternTypes : Int -> List Can.Pattern -> PostSolve.NodeTypes -> Result String (List (Can.Type Name))
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


{-| Returns the curried function type from `argTypes` to `bodyType`.

    buildCurriedFunctionType [ a, b, c ] ret == a -> b -> c -> ret

-}
buildCurriedFunctionType : List (Can.Type Name) -> Can.Type Name -> Can.Type Name
buildCurriedFunctionType argTypes bodyType =
    List.foldr Can.tLambda bodyType argTypes



-- ============================================================================
-- ALPHA EQUIVALENCE (simplified)
-- ============================================================================


{-| Returns whether two types have the same structure, with every type variable
matching every other.

This is looser than alpha-equivalence: no consistent renaming is checked, so
`a -> a` matches `a -> b`, and any two record extension variables match. Type
constructors and aliases must agree on module and name. Arrow slots, record
field positions and alias parameter names are ignored, and an alias matches
only another alias, never its expansion.

-}
alphaEq : Can.Type Name -> Can.Type Name -> Bool
alphaEq a b =
    case ( a, b ) of
        ( Can.TVar _, Can.TVar _ ) ->
            True

        ( Can.TType h1 n1 as1, Can.TType h2 n2 as2 ) ->
            h1 == h2 && n1 == n2 && alphaEqList as1 as2

        ( Can.TLambda _ a1 r1, Can.TLambda _ a2 r2 ) ->
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


{-| Returns whether two lists of types have the same length and match pairwise
under `alphaEq`.
-}
alphaEqList : List (Can.Type Name) -> List (Can.Type Name) -> Bool
alphaEqList xs ys =
    case ( xs, ys ) of
        ( [], [] ) ->
            True

        ( x :: xr, y :: yr ) ->
            alphaEq x y && alphaEqList xr yr

        _ ->
            False


{-| Returns whether two record extensions are both absent or both present,
whatever the variables' names.
-}
alphaEqExt : Maybe Name.Name -> Maybe Name.Name -> Bool
alphaEqExt ext1 ext2 =
    case ( ext1, ext2 ) of
        ( Nothing, Nothing ) ->
            True

        ( Just _, Just _ ) ->
            True

        _ ->
            False


{-| Returns whether two records have the same field names and each field's
types match under `alphaEq`, ignoring field positions.
-}
alphaEqFields :
    Dict.Dict Name.Name (Can.FieldType Name)
    -> Dict.Dict Name.Name (Can.FieldType Name)
    -> Bool
alphaEqFields fields1 fields2 =
    let
        list1 =
            Dict.toList fields1

        list2 =
            Dict.toList fields2
    in
    if List.length list1 /= List.length list2 then
        False

    else
        List.all
            (\( ( k1, Can.FieldType _ t1 ), ( k2, Can.FieldType _ t2 ) ) ->
                k1 == k2 && alphaEq t1 t2
            )
            (List.map2 Tuple.pair list1 list2)


{-| Returns whether two alias argument lists have the same length and their
types match pairwise under `alphaEq`, ignoring the parameter names.
-}
alphaEqArgs : List ( Name.Name, Can.Type Name ) -> List ( Name.Name, Can.Type Name ) -> Bool
alphaEqArgs args1 args2 =
    case ( args1, args2 ) of
        ( [], [] ) ->
            True

        ( ( _, t1 ) :: r1, ( _, t2 ) :: r2 ) ->
            alphaEq t1 t2 && alphaEqArgs r1 r2

        _ ->
            False


{-| Returns whether two alias bodies are both `Holey` or both `Filled` and
match under `alphaEq`.
-}
alphaEqAlias : Can.AliasType Name -> Can.AliasType Name -> Bool
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


{-| Returns the report for `violations`, each formatted by `formatViolation`,
separated by blank lines.
-}
formatViolations : List Violation -> String
formatViolations violations =
    violations
        |> List.map formatViolation
        |> String.join "\n\n"


{-| Returns a multi-line report of one violation: its node id and form, then
its pre-type, post-type, expected type (or "(not computed)") and details.
-}
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


{-| Returns a short debugging rendering of a type.

It names type constructors and aliases without their module and leaves out
alias arguments and record fields, so two different types can render the same.

-}
typeToString : Can.Type Name -> String
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

        Can.TLambda _ a b ->
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


{-| Returns the constructor name of an expression form, for the twelve forms
`isGroupBExprNode` accepts, and "Other" for the rest.
-}
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
