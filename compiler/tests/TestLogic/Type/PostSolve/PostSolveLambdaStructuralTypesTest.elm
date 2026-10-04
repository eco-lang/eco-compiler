module TestLogic.Type.PostSolve.PostSolveLambdaStructuralTypesTest exposing (suite)

{-| Without these tests, a lambda whose recorded type after PostSolve is a bare
type variable, a non-function type, or a function type of the wrong shape would
reach later phases unnoticed. They check invariant POST\_007: after PostSolve,
the type recorded for every lambda is a function type that agrees with the
lambda's parameters and body.

The solver records the types of expression and pattern nodes in a
`NodeTypes` array indexed by node id, as `Compiler.Type.PostSolve` describes. A
lambda is a Group A node there, which records the solver variable for its own
result, and PostSolve keeps Group A entries as they are, so the type checked
here is the one the solver gave the lambda.

The _structural type_ of a lambda `\p1 p2 -> body` is the curried function type
`t1 -> t2 -> tb` built from the post-PostSolve types of its parameter patterns
and of its body. The lambda's own type must be _alpha-equivalent_ to it: the
two types are identical except that type variables may be renamed, and the
renaming must be one-to-one and the same throughout the type. Record extension
variables are renamed in the same one-to-one map as ordinary type variables.
Most of the file is this comparison, `bijectiveAlphaEq`.

Apart from the renaming the comparison is exact. A named type matches only one
with the same home module and name. An alias matches only an alias with the
same home module and name whose arguments and body match, so an alias never
matches its own expansion. The arrow slot of a function type and the field
positions of a record type are ignored.

The programs are the standard test catalogue of
`SourceIR.Suite.StandardTestSuites`, each compiled through PostSolve by
`TestLogic.Type.PostSolve.CompileThroughPostSolve.compileToPostSolve`. A
program that fails to compile fails the check.

What the tests establish:

  - `suite` applies `expectLambdaStructuralTypes` to each program. For every
    `Can.Lambda` node that `TestLogic.Type.PostSolve.PostSolveInvariantHelpers.walkExprs`
    lists, it checks that the lambda has a post-PostSolve type; that the type
    is a `TLambda` at the top, so a bare variable or an alias of a function
    type fails; that every parameter pattern has a non-negative id and a type,
    and the body has a type; and that the lambda's type is alpha-equivalent to
    its structural type. Every violation in a program is listed in one failure
    message.

Among what is not tested:

  - Functions defined with parameters, such as `f x = ...` at the top level or
    in a `let`. These are definitions, not lambda nodes.
  - Whether PostSolve changes a lambda's type. Only the post-PostSolve array is
    read, and the structural type is built from that same array.
  - Arrow slots and record field positions.

-}

import Array
import Compiler.AST.Canonical as Can
import Compiler.AST.Source as Src
import Compiler.Data.Name exposing (Name)
import Compiler.Reporting.Annotation as A
import Compiler.Type.PostSolve as PostSolve
import Dict
import Expect
import SourceIR.Suite.StandardTestSuites as StandardTestSuites
import Test exposing (Test)
import TestLogic.Type.PostSolve.CompileThroughPostSolve as Compile
import TestLogic.Type.PostSolve.PostSolveInvariantHelpers as Helpers


{-| One lambda that fails POST\_007, with the reason in `details`.

`postType` is `Nothing` when the lambda has no post-PostSolve type, and
`expectedType` is the structural type, `Nothing` unless the failure is that
the two types are not alpha-equivalent.

-}
type alias Violation =
    { nodeId : Int
    , details : String
    , postType : Maybe (Can.Type Name)
    , expectedType : Maybe (Can.Type Name)
    }


{-| The POST\_007 check, `expectLambdaStructuralTypes`, applied to every program
of the standard test catalogue.
-}
suite : Test
suite =
    Test.describe "POST_007: Lambda Structural Types"
        [ StandardTestSuites.expectSuite expectLambdaStructuralTypes "lambda-structural-types"
        ]


{-| Compiles `srcModule` through PostSolve and passes when every lambda in it
passes `checkLambdaStructuralType`.

It fails with the compiler's message when the program does not compile, and
otherwise with every violation found, listed together.

-}
expectLambdaStructuralTypes : Src.Module -> Expect.Expectation
expectLambdaStructuralTypes srcModule =
    case Compile.compileToPostSolve srcModule of
        Err msg ->
            Expect.fail msg

        Ok artifacts ->
            let
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


{-| Returns whether an expression is a `Can.Lambda`.
-}
isLambda : Can.Expr_ -> Bool
isLambda node =
    case node of
        Can.Lambda _ _ ->
            True

        _ ->
            False


{-| Returns the violation for one lambda node, or `Nothing` when it passes or
the node is not a lambda.

The checks stop at the first that fails, in this order: the lambda has a type
in `nodeTypes`; that type is a `TLambda` at the top; its structural type can be
built, as `computeExpectedLambdaType` does; and the two are alpha-equivalent.

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
                    if not (isTLambda postType) then
                        Just
                            { nodeId = exprNode.id
                            , details = "Lambda post type is not a TLambda chain: " ++ typeToString postType
                            , postType = Just postType
                            , expectedType = Nothing
                            }

                    else
                        case computeExpectedLambdaType exprNode.id patterns bodyInfo.id nodeTypes of
                            LambdaTypeError errorMsg ->
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
            Nothing


{-| Returns whether a type is a `TLambda` at the top. An alias of a function
type is not.
-}
isTLambda : Can.Type Name -> Bool
isTLambda tipe =
    case tipe of
        Can.TLambda _ _ _ ->
            True

        _ ->
            False


{-| The outcome of building a lambda's structural type.

`LambdaTypeOk` carries the structural type. `LambdaTypeError` carries a message
naming the lambda and the body or parameter at fault.

-}
type LambdaTypeResult
    = LambdaTypeOk (Can.Type Name)
    | LambdaTypeError String


{-| Builds the structural type of lambda `lambdaId` from the types `nodeTypes`
holds for its parameter `patterns` and its body `bodyId`: for `\p1 p2 -> body`,
the type `t1 -> t2 -> tb`.

A missing body type, or a parameter error from `collectPatternTypes`, gives
`LambdaTypeError`. The arrows are built with no identity in their arrow slot.

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
                    LambdaTypeOk (List.foldr Can.tLambda bodyType argTypes)


{-| Returns the types `nodeTypes` holds for `patterns`, in order, or an error
when a pattern has a negative id or no type.

The patterns are folded from the last, and the first error found is kept, so
when several patterns fail the message names the last of them. `lambdaId` is
used only in the message.

-}
collectPatternTypes : Int -> List Can.Pattern -> PostSolve.NodeTypes -> Result String (List (Can.Type Name))
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


{-| The pairing of type variable names built up while comparing a left type
with a right one.

It is kept in both directions so that a pairing can be refused from either
side: a left name already paired with a different right name, or a right name
already paired with a different left name. Record extension variables are
paired in the same maps as ordinary type variables.

-}
type alias Renaming =
    { forward : Dict.Dict String String -- left name -> right name
    , reverse : Dict.Dict String String -- right name -> left name
    }


{-| The renaming with no pairs, from which a comparison starts.
-}
emptyRenaming : Renaming
emptyRenaming =
    { forward = Dict.empty, reverse = Dict.empty }


{-| Returns whether `a` and `b` are alpha-equivalent, in the exact sense the
module documentation gives: `Ok` with the pairing of their type variables, or
`Err` describing the first difference found.

A type variable matches only a type variable, never another type.

-}
bijectiveAlphaEq : Can.Type Name -> Can.Type Name -> Result String Renaming
bijectiveAlphaEq a b =
    bijectiveAlphaEqHelp emptyRenaming a b


{-| Compares `a` with `b` as `bijectiveAlphaEq` does, extending `renaming` with
the type variables paired along the way.

Parts are compared in turn, with the renaming from each part carried into the
next, so a variable must be paired the same way everywhere in the type.

-}
bijectiveAlphaEqHelp : Renaming -> Can.Type Name -> Can.Type Name -> Result String Renaming
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
                            Ok
                                { forward = Dict.insert nameA nameB renaming.forward
                                , reverse = Dict.insert nameB nameA renaming.reverse
                                }

        ( Can.TType h1 n1 as1, Can.TType h2 n2 as2 ) ->
            if h1 == h2 && n1 == n2 then
                bijectiveAlphaEqList renaming as1 as2

            else
                Err ("TType mismatch: " ++ n1 ++ " vs " ++ n2)

        ( Can.TLambda _ a1 r1, Can.TLambda _ a2 r2 ) ->
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


{-| Compares two lists of types pairwise, in order, threading the renaming. Lists
of different lengths do not match.
-}
bijectiveAlphaEqList : Renaming -> List (Can.Type Name) -> List (Can.Type Name) -> Result String Renaming
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


{-| Compares the extension variables of two record types. Both must be absent,
or both present and paired as type variables in the same renaming as the rest
of the type.
-}
bijectiveAlphaEqExt : Renaming -> Maybe String -> Maybe String -> Result String Renaming
bijectiveAlphaEqExt renaming ext1 ext2 =
    case ( ext1, ext2 ) of
        ( Nothing, Nothing ) ->
            Ok renaming

        ( Just e1, Just e2 ) ->
            bijectiveAlphaEqHelp renaming (Can.TVar e1) (Can.TVar e2)

        _ ->
            Err "Record extension mismatch"


{-| Compares the fields of two record types. The two must have the same field
names, and the types of same-named fields must match; each field's position is
ignored.
-}
bijectiveAlphaEqFields :
    Renaming
    -> Dict.Dict String (Can.FieldType Name)
    -> Dict.Dict String (Can.FieldType Name)
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


{-| Compares the arguments of two aliases pairwise, in order, by their types
only; the parameter names they are given for are ignored. Lists of different
lengths do not match.
-}
bijectiveAlphaEqArgs : Renaming -> List ( String, Can.Type Name ) -> List ( String, Can.Type Name ) -> Result String Renaming
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


{-| Compares the bodies of two aliases. A `Holey` body matches only a `Holey`
one and a `Filled` body only a `Filled` one.
-}
bijectiveAlphaEqAlias : Renaming -> Can.AliasType Name -> Can.AliasType Name -> Result String Renaming
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


{-| Builds the failure message for a program: a count of the violations, then
each one as `formatViolation` gives it.
-}
formatViolations : List Violation -> String
formatViolations violations =
    let
        header =
            "POST_007 violations: "
                ++ String.fromInt (List.length violations)
                ++ " lambda(s) without proper structural types\n\n"
    in
    header ++ (violations |> List.map formatViolation |> String.join "\n\n")


{-| Renders one violation as a few lines: its node id, the lambda's type, the
structural type and the reason.
-}
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


{-| Renders a type as `typeToString` does, or `(none)` for `Nothing`.
-}
maybeTypeToString : Maybe (Can.Type Name) -> String
maybeTypeToString mt =
    case mt of
        Just t ->
            typeToString t

        Nothing ->
            "(none)"


{-| Renders a type for a failure message, naming each constructor.

The rendering is partial: a record shows only its extension variable, not its
fields, and an alias only its name, not its arguments or body. Named types and
aliases show their name without the home module.

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
