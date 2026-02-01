module TestLogic.Canonicalize.GlobalNames exposing
    ( expectGlobalNamesQualified
    , expectGlobalNamesQualifiedCanonical
    )

{-| Test logic for invariant CANON\_001: Global names are fully qualified.

For every non-local variable reference (VarForeign, VarKernel, VarCtor, VarOperator,
VarTopLevel, VarDebug), assert its `home` is an `IO.Canonical` referring to a valid
module structure; assert local variables are always `VarLocal` and never carry `home`.

-}

import Compiler.AST.Canonical as Can
import Compiler.AST.Source as Src
import Compiler.Canonicalize.Module as Canonicalize
import Compiler.Data.OneOrMore as OneOrMore
import Compiler.Elm.Interface.Basic as Basic
import Compiler.Reporting.Annotation as A
import Compiler.Reporting.Error.Canonicalize as CanError
import Compiler.Reporting.Result as Result
import Data.Map as Dict
import Expect
import System.TypeCheck.IO as IO


{-| Main test expectation: canonicalize the module and verify all global names are qualified.
-}
expectGlobalNamesQualified : Src.Module -> Expect.Expectation
expectGlobalNamesQualified modul =
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
            expectGlobalNamesQualifiedCanonical canModule


{-| Verify global names are qualified in a pre-constructed canonical module.
-}
expectGlobalNamesQualifiedCanonical : Can.Module -> Expect.Expectation
expectGlobalNamesQualifiedCanonical canModule =
    let
        issues =
            collectGlobalNameIssues canModule
    in
    if List.isEmpty issues then
        Expect.pass

    else
        Expect.fail
            ("Global name qualification issues found:\n"
                ++ String.join "\n" issues
            )


{-| Collect all global name qualification issues from a canonical module.
-}
collectGlobalNameIssues : Can.Module -> List String
collectGlobalNameIssues (Can.Module { decls }) =
    collectDeclsIssues decls


{-| Collect issues from declarations.
-}
collectDeclsIssues : Can.Decls -> List String
collectDeclsIssues decls =
    case decls of
        Can.Declare def rest ->
            collectDefIssues def ++ collectDeclsIssues rest

        Can.DeclareRec def defs rest ->
            collectDefIssues def
                ++ List.concatMap collectDefIssues defs
                ++ collectDeclsIssues rest

        Can.SaveTheEnvironment ->
            []


{-| Collect issues from a definition.
-}
collectDefIssues : Can.Def -> List String
collectDefIssues def =
    case def of
        Can.Def _ patterns expr ->
            List.concatMap collectPatternIssues patterns
                ++ collectExprIssues expr

        Can.TypedDef _ _ patternsWithTypes expr _ ->
            List.concatMap (\( p, _ ) -> collectPatternIssues p) patternsWithTypes
                ++ collectExprIssues expr


{-| Collect issues from an expression.
-}
collectExprIssues : Can.Expr -> List String
collectExprIssues (A.At _ { node }) =
    collectExprNodeIssues node


{-| Collect issues from an expression node.

Checks:

  - VarLocal: Should not have a home (correct by construction)
  - VarTopLevel: home must be valid IO.Canonical
  - VarKernel: Uses kernel module naming (no IO.Canonical home)
  - VarForeign: home must be valid IO.Canonical
  - VarCtor: home must be valid IO.Canonical
  - VarDebug: home must be valid IO.Canonical
  - VarOperator: home must be valid IO.Canonical

-}
collectExprNodeIssues : Can.Expr_ -> List String
collectExprNodeIssues node =
    case node of
        Can.VarLocal _ ->
            -- VarLocal has no home - this is correct by construction
            []

        Can.VarTopLevel home name ->
            validateHome "VarTopLevel" name home

        Can.VarKernel _ _ ->
            -- VarKernel uses kernel module naming, no IO.Canonical home to validate
            []

        Can.VarForeign home name _ ->
            validateHome "VarForeign" name home

        Can.VarCtor _ home name _ _ ->
            validateHome "VarCtor" name home

        Can.VarDebug home name _ ->
            validateHome "VarDebug" name home

        Can.VarOperator _ home name _ ->
            validateHome "VarOperator" name home

        Can.Chr _ ->
            []

        Can.Str _ ->
            []

        Can.Int _ ->
            []

        Can.Float _ ->
            []

        Can.List exprs ->
            List.concatMap collectExprIssues exprs

        Can.Negate expr ->
            collectExprIssues expr

        Can.Binop _ home _ _ left right ->
            validateHome "Binop" "operator" home
                ++ collectExprIssues left
                ++ collectExprIssues right

        Can.Lambda patterns body ->
            List.concatMap collectPatternIssues patterns
                ++ collectExprIssues body

        Can.Call func args ->
            collectExprIssues func
                ++ List.concatMap collectExprIssues args

        Can.If branches final ->
            List.concatMap
                (\( cond, then_ ) ->
                    collectExprIssues cond ++ collectExprIssues then_
                )
                branches
                ++ collectExprIssues final

        Can.Let def body ->
            collectDefIssues def ++ collectExprIssues body

        Can.LetRec defs body ->
            List.concatMap collectDefIssues defs
                ++ collectExprIssues body

        Can.LetDestruct pattern expr body ->
            collectPatternIssues pattern
                ++ collectExprIssues expr
                ++ collectExprIssues body

        Can.Case subject branches ->
            collectExprIssues subject
                ++ List.concatMap
                    (\(Can.CaseBranch pattern branchBody) ->
                        collectPatternIssues pattern
                            ++ collectExprIssues branchBody
                    )
                    branches

        Can.Accessor _ ->
            []

        Can.Access record _ ->
            collectExprIssues record

        Can.Update record fields ->
            collectExprIssues record
                ++ Dict.foldl A.compareLocated
                    (\_ (Can.FieldUpdate _ expr) acc ->
                        collectExprIssues expr ++ acc
                    )
                    []
                    fields

        Can.Record fields ->
            Dict.foldl A.compareLocated
                (\_ expr acc -> collectExprIssues expr ++ acc)
                []
                fields

        Can.Unit ->
            []

        Can.Tuple a b rest ->
            collectExprIssues a
                ++ collectExprIssues b
                ++ List.concatMap collectExprIssues rest

        Can.Shader _ _ ->
            []


{-| Collect issues from a pattern.
-}
collectPatternIssues : Can.Pattern -> List String
collectPatternIssues (A.At _ { node }) =
    collectPatternNodeIssues node


{-| Collect issues from a pattern node.
-}
collectPatternNodeIssues : Can.Pattern_ -> List String
collectPatternNodeIssues node =
    case node of
        Can.PAnything ->
            []

        Can.PVar _ ->
            []

        Can.PRecord _ ->
            []

        Can.PAlias pattern _ ->
            collectPatternIssues pattern

        Can.PUnit ->
            []

        Can.PTuple a b rest ->
            collectPatternIssues a
                ++ collectPatternIssues b
                ++ List.concatMap collectPatternIssues rest

        Can.PList patterns ->
            List.concatMap collectPatternIssues patterns

        Can.PCons head tail ->
            collectPatternIssues head ++ collectPatternIssues tail

        Can.PBool _ _ ->
            []

        Can.PChr _ ->
            []

        Can.PStr _ _ ->
            []

        Can.PInt _ ->
            []

        Can.PCtor { home, name, args } ->
            validateHome "PCtor" name home
                ++ List.concatMap
                    (\(Can.PatternCtorArg _ _ p) -> collectPatternIssues p)
                    args


{-| Validate that an IO.Canonical home is properly structured.

A valid IO.Canonical has:

  - A package tuple (author, project) with non-empty strings
  - A non-empty module name

-}
validateHome : String -> String -> IO.Canonical -> List String
validateHome context name home =
    case home of
        IO.Canonical ( author, project ) moduleName ->
            []
                |> addIssueIf (String.isEmpty author)
                    (context ++ " '" ++ name ++ "': empty package author")
                |> addIssueIf (String.isEmpty project)
                    (context ++ " '" ++ name ++ "': empty package project")
                |> addIssueIf (String.isEmpty moduleName)
                    (context ++ " '" ++ name ++ "': empty module name")


{-| Helper to conditionally add an issue.
-}
addIssueIf : Bool -> String -> List String -> List String
addIssueIf condition issue issues =
    if condition then
        issue :: issues

    else
        issues


{-| Convert a canonicalization error to a string for debugging.
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
