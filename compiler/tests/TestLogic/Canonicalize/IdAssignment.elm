module TestLogic.Canonicalize.IdAssignment exposing
    ( expectUniqueIds
    , expectUniqueIdsCanonical
    )

{-| Checks that canonicalization gives each expression and pattern node of a
module an id of its own. Later phases attach information, such as an inferred
type, to a node by its id, so two nodes given the same id would have that
information mixed up.

A _node id_ is the `id` in the `{ id, node }` record that wraps every
expression and pattern in `Compiler.AST.Canonical`. `Compiler.Canonicalize.Ids`
describes how ids are handed out. What matters here is that expressions and
patterns draw from one counter, so an expression and a pattern should not share
an id either, and that the counter starts at 0, so no id canonicalization
gives is negative.

The module to check comes from the caller. `expectUniqueIds` takes a source
module and canonicalizes it as a module of the package `eco/example` against
the stand-in interfaces of `Compiler.Elm.Interface.Basic.testIfaces`.
`expectUniqueIdsCanonical` takes a canonical module that is already built.

The ids checked are those of every expression and every pattern in the
module's top-level declarations: definition arguments (top-level and
`let`-bound), lambda arguments, `case` branch patterns and `let`
destructuring patterns, nested patterns included. Each repeat is kept, so that
a duplicate can be found.

  - `expectUniqueIds` fails if canonicalization reports any error. Otherwise it
    applies the checks below to the canonical module it produced.
  - `expectUniqueIdsCanonical` applies the same checks to the module it is
    given.

The checks run in this order, and only the first that fails is reported: no
id is negative; no expression id occurs twice; no pattern id occurs twice; no
id is both an expression id and a pattern id.

Among what is not tested:

  - Anything outside the module's top-level declarations, such as its ports.
  - That ids start at 0 or have no gaps. Only negative ids are rejected.

-}

import Compiler.AST.Canonical as Can
import Compiler.AST.Source as Src
import Compiler.Canonicalize.Module as Canonicalize
import Compiler.Data.OneOrMore as OneOrMore
import Compiler.Elm.Interface.Basic as Basic
import Compiler.Reporting.Annotation as A
import Compiler.Reporting.Error.Canonicalize as CanError
import Compiler.Reporting.Result as Result
import Data.Map as DMap
import Dict
import Expect
import Set



-- ============================================================================
-- TEST INFRASTRUCTURE
-- ============================================================================


{-| Canonicalizes `modul` as a module of the package `eco/example` against
`Compiler.Elm.Interface.Basic.testIfaces`, and passes when the node ids of the
result pass the checks the module docstring lists.

If canonicalization reports errors, the expectation fails with their number
and a short description of the first one in the error list.

-}
expectUniqueIds : Src.Module -> Expect.Expectation
expectUniqueIds modul =
    let
        result =
            Canonicalize.canonicalize ( "eco", "example" ) Basic.testIfaces modul
    in
    case Result.run result of
        ( _, Err errors ) ->
            let
                errorList =
                    OneOrMore.destruct (::) errors

                errorCount =
                    List.length errorList

                firstError =
                    List.head errorList
                        |> Maybe.map errorToString
                        |> Maybe.withDefault "unknown"
            in
            Expect.fail
                ("Canonicalization failed with "
                    ++ String.fromInt errorCount
                    ++ " error(s): "
                    ++ firstError
                )

        ( _, Ok canModule ) ->
            expectUniqueIdsCanonical canModule


{-| Returns each value that occurs more than once in `ids`, listed once, in
descending order.
-}
findDuplicates : List Int -> List Int
findDuplicates ids =
    let
        countOccurrences =
            List.foldl
                (\id acc ->
                    Dict.update
                        id
                        (\maybeCount ->
                            case maybeCount of
                                Nothing ->
                                    Just 1

                                Just n ->
                                    Just (n + 1)
                        )
                        acc
                )
                Dict.empty

        counts =
            countOccurrences ids
    in
    Dict.foldl
        (\id count acc ->
            if count > 1 then
                id :: acc

            else
                acc
        )
        []
        counts


{-| Returns a one-line description of a canonicalization error for a failure
message. For `NotFoundVar`, `NotFoundBinop`, `RecursiveLet`, `NotFoundType`,
`NotFoundVariant` and `Shadowing` it is the constructor's name and the name the
error concerns, qualified where the error carries a module qualifier. Every
other kind of error gives `"Other error"`.
-}
errorToString : CanError.Error -> String
errorToString error =
    case error of
        CanError.NotFoundVar _ maybeModule name _ ->
            "NotFoundVar: "
                ++ (maybeModule |> Maybe.map (\m -> m ++ ".") |> Maybe.withDefault "")
                ++ name

        CanError.NotFoundBinop _ name _ ->
            "NotFoundBinop: " ++ name

        CanError.RecursiveLet (A.At _ name) _ ->
            "RecursiveLet: " ++ name

        CanError.NotFoundType _ maybeModule name _ ->
            "NotFoundType: "
                ++ (maybeModule |> Maybe.map (\m -> m ++ ".") |> Maybe.withDefault "")
                ++ name

        CanError.NotFoundVariant _ maybeModule name _ ->
            "NotFoundVariant: "
                ++ (maybeModule |> Maybe.map (\m -> m ++ ".") |> Maybe.withDefault "")
                ++ name

        CanError.Shadowing name _ _ ->
            "Shadowing: " ++ name

        _ ->
            "Other error"


{-| Returns the expression ids and the pattern ids collected from the module's
top-level declarations, as two lists that keep every repeat. Nothing else in
the module, such as its ports or effects, is looked at.
-}
collectModuleIdsAsList : Can.Module -> ( List Int, List Int )
collectModuleIdsAsList (Can.Module { decls }) =
    collectDeclsIdsAsList decls


{-| Returns the expression ids and the pattern ids of every definition in
`decls`, the members of recursive groups included.
-}
collectDeclsIdsAsList : Can.Decls -> ( List Int, List Int )
collectDeclsIdsAsList decls =
    case decls of
        Can.Declare def rest ->
            let
                ( exprIds, patternIds ) =
                    collectDefIdsAsList def

                ( restExprIds, restPatternIds ) =
                    collectDeclsIdsAsList rest
            in
            ( exprIds ++ restExprIds, patternIds ++ restPatternIds )

        Can.DeclareRec def defs rest ->
            let
                ( defExprIds, defPatternIds ) =
                    collectDefIdsAsList def

                defsIds =
                    List.foldl
                        (\d ( eAcc, pAcc ) ->
                            let
                                ( e, p ) =
                                    collectDefIdsAsList d
                            in
                            ( e ++ eAcc, p ++ pAcc )
                        )
                        ( defExprIds, defPatternIds )
                        defs

                ( restExprIds, restPatternIds ) =
                    collectDeclsIdsAsList rest
            in
            ( Tuple.first defsIds ++ restExprIds
            , Tuple.second defsIds ++ restPatternIds
            )

        Can.SaveTheEnvironment ->
            ( [], [] )


{-| Returns the ids of the expressions in a definition's body and the ids of
the patterns among its arguments and inside its body.
-}
collectDefIdsAsList : Can.Def -> ( List Int, List Int )
collectDefIdsAsList def =
    case def of
        Can.Def _ patterns expr ->
            withPatterns patterns (collectExprIdsAsList expr)

        Can.TypedDef _ _ patternsWithTypes expr _ ->
            withPatterns (List.map Tuple.first patternsWithTypes) (collectExprIdsAsList expr)


{-| Adds the ids of `patterns`, nested ones included, to the pattern ids of
`ids`.
-}
withPatterns : List Can.Pattern -> ( List Int, List Int ) -> ( List Int, List Int )
withPatterns patterns ( exprIds, patternIds ) =
    ( exprIds, List.concatMap collectPatternIdsAsList patterns ++ patternIds )


{-| Concatenates the expression ids and the pattern ids of several results.
-}
concatIds : List ( List Int, List Int ) -> ( List Int, List Int )
concatIds parts =
    ( List.concatMap Tuple.first parts, List.concatMap Tuple.second parts )


{-| Returns the ids of an expression and every expression nested in it, and the
ids of every pattern nested in it.
-}
collectExprIdsAsList : Can.Expr -> ( List Int, List Int )
collectExprIdsAsList (A.At _ { id, node }) =
    let
        ( exprIds, patternIds ) =
            collectExprNodeIdsAsList node
    in
    ( id :: exprIds, patternIds )


{-| Returns the ids of every expression and pattern nested in one expression
node, not counting the node itself.
-}
collectExprNodeIdsAsList : Can.Expr_ -> ( List Int, List Int )
collectExprNodeIdsAsList node =
    case node of
        Can.List exprs ->
            concatIds (List.map collectExprIdsAsList exprs)

        Can.Negate expr ->
            collectExprIdsAsList expr

        Can.Binop _ _ _ _ left right ->
            concatIds [ collectExprIdsAsList left, collectExprIdsAsList right ]

        Can.Lambda patterns body ->
            withPatterns patterns (collectExprIdsAsList body)

        Can.Call func args ->
            concatIds (List.map collectExprIdsAsList (func :: args))

        Can.If branches final ->
            concatIds (List.map collectExprIdsAsList (final :: List.concatMap (\( c, t ) -> [ c, t ]) branches))

        Can.Let def body ->
            concatIds [ collectDefIdsAsList def, collectExprIdsAsList body ]

        Can.LetRec defs body ->
            concatIds (collectExprIdsAsList body :: List.map collectDefIdsAsList defs)

        Can.LetDestruct pattern expr body ->
            withPatterns [ pattern ] (concatIds [ collectExprIdsAsList expr, collectExprIdsAsList body ])

        Can.Case subject branches ->
            concatIds
                (collectExprIdsAsList subject
                    :: List.map (\(Can.CaseBranch pattern branchBody) -> withPatterns [ pattern ] (collectExprIdsAsList branchBody)) branches
                )

        Can.Access record _ ->
            collectExprIdsAsList record

        Can.Update record fields ->
            concatIds
                (collectExprIdsAsList record
                    :: DMap.foldl (\_ (Can.FieldUpdate _ expr) acc -> collectExprIdsAsList expr :: acc) [] fields
                )

        Can.Record fields ->
            concatIds (DMap.foldl (\_ expr acc -> collectExprIdsAsList expr :: acc) [] fields)

        Can.Tuple a b rest ->
            concatIds (List.map collectExprIdsAsList (a :: b :: rest))

        Can.VarLocal _ ->
            ( [], [] )

        Can.VarTopLevel _ _ ->
            ( [], [] )

        Can.VarKernel _ _ _ ->
            ( [], [] )

        Can.VarForeign _ _ _ ->
            ( [], [] )

        Can.VarCtor _ _ _ _ _ ->
            ( [], [] )

        Can.VarDebug _ _ _ ->
            ( [], [] )

        Can.VarOperator _ _ _ _ ->
            ( [], [] )

        Can.Chr _ ->
            ( [], [] )

        Can.Str _ ->
            ( [], [] )

        Can.Int _ ->
            ( [], [] )

        Can.Float _ ->
            ( [], [] )

        Can.Accessor _ ->
            ( [], [] )

        Can.Unit ->
            ( [], [] )

        Can.Shader _ _ ->
            ( [], [] )


{-| Returns the id of a pattern followed by the ids of every pattern nested in
it.
-}
collectPatternIdsAsList : Can.Pattern -> List Int
collectPatternIdsAsList (A.At _ { id, node }) =
    id :: collectPatternNodeIdsAsList node


{-| Returns the ids of every pattern nested in one pattern node, not counting
the node itself: the subpatterns of an alias, a tuple, a list, a cons and a
constructor's arguments.
-}
collectPatternNodeIdsAsList : Can.Pattern_ -> List Int
collectPatternNodeIdsAsList node =
    case node of
        Can.PAnything ->
            []

        Can.PVar _ ->
            []

        Can.PRecord _ ->
            []

        Can.PAlias pattern _ ->
            collectPatternIdsAsList pattern

        Can.PUnit ->
            []

        Can.PTuple a b rest ->
            collectPatternIdsAsList a
                ++ collectPatternIdsAsList b
                ++ List.concatMap collectPatternIdsAsList rest

        Can.PList patterns ->
            List.concatMap collectPatternIdsAsList patterns

        Can.PCons head tail ->
            collectPatternIdsAsList head ++ collectPatternIdsAsList tail

        Can.PBool _ _ ->
            []

        Can.PChr _ ->
            []

        Can.PStr _ _ ->
            []

        Can.PInt _ ->
            []

        Can.PCtor { args } ->
            List.concatMap (\(Can.PatternCtorArg _ _ p) -> collectPatternIdsAsList p) args



-- ============================================================================
-- CANONICAL MODULE TESTING (for pre-constructed canonical AST)
-- ============================================================================


{-| Passes when the node ids of `canModule`, taken as given, pass the checks
the module docstring lists. This is for a module built directly as canonical
AST rather than canonicalized from source.
-}
expectUniqueIdsCanonical : Can.Module -> Expect.Expectation
expectUniqueIdsCanonical canModule =
    let
        ( exprIdsList, patternIdsList ) =
            collectModuleIdsAsList canModule

        allIdsList =
            exprIdsList ++ patternIdsList

        exprDuplicates =
            findDuplicates exprIdsList

        patternDuplicates =
            findDuplicates patternIdsList

        overlap =
            Set.toList (Set.intersect (Set.fromList exprIdsList) (Set.fromList patternIdsList))

        negativeIds =
            List.filter (\id -> id < 0) allIdsList
    in
    if not (List.isEmpty negativeIds) then
        Expect.fail
            ("Found negative IDs: "
                ++ String.join ", " (List.map String.fromInt negativeIds)
            )

    else if not (List.isEmpty exprDuplicates) then
        Expect.fail
            ("Duplicate expression IDs found: "
                ++ String.join ", " (List.map String.fromInt exprDuplicates)
            )

    else if not (List.isEmpty patternDuplicates) then
        Expect.fail
            ("Duplicate pattern IDs found: "
                ++ String.join ", " (List.map String.fromInt patternDuplicates)
            )

    else if not (List.isEmpty overlap) then
        Expect.fail
            ("Expression and pattern IDs overlap: "
                ++ String.join ", " (List.map String.fromInt overlap)
            )

    else
        Expect.pass
