module TestLogic.Canonicalize.GlobalNames exposing
    ( expectGlobalNamesQualified
    , expectGlobalNamesQualifiedCanonical
    )

{-| Checks that the references in a canonical module carry a complete home, so
that a reference resolved to a module with a missing part fails a test rather
than going unnoticed into the later phases.

Each reference checked here carries a **home**, a `ModuleName.Canonical`: a
package author, a package project and a module name. Here a home is complete
when none of those three strings is empty. Nothing checks that the home names a
module that exists, or the right one.

Nothing in this module is a test. Its two exposed functions are expectations
for a test to apply to a module.

`expectGlobalNamesQualified` takes a source module, canonicalizes it as package
`eco/example` against `Compiler.Elm.Interface.Basic.testIfaces`, and fails if
canonicalization reports an error. Otherwise it checks the result as
`expectGlobalNamesQualifiedCanonical` does.

`expectGlobalNamesQualifiedCanonical` takes a canonical module, walks every
expression and pattern in its declarations, and fails, with one line per empty
part, when the home of a `VarTopLevel`, `VarForeign`, `VarCtor`, `VarDebug`,
`VarOperator`, `Binop` or `PCtor` node is not complete. A `VarKernel`, which
carries no `ModuleName.Canonical`, is checked instead for a kernel prefix of
`Elm` or `Eco` and a non-empty kernel module and name.

Among what is not checked:

  - `VarLocal` references, which carry no home;
  - the type annotations of definitions, and the module's unions, aliases,
    infix declarations and effects.

-}

import Compiler.AST.Canonical as Can
import Compiler.AST.Source as Src
import Compiler.Canonicalize.Module as Canonicalize
import Compiler.Data.OneOrMore as OneOrMore
import Compiler.Elm.Interface.Basic as Basic
import Compiler.Elm.ModuleName as ModuleName
import Compiler.Reporting.Annotation as A
import Compiler.Reporting.Error.Canonicalize as CanError
import Compiler.Reporting.Result as Result
import Data.Map as DMap
import Expect


{-| Canonicalizes `modul` as package `eco/example` against
`Compiler.Elm.Interface.Basic.testIfaces`, and passes when that succeeds and
every `VarTopLevel`, `VarForeign`, `VarCtor`, `VarDebug`, `VarOperator`, `Binop`
and `PCtor` node in the result has a home whose author, project and module name
are all non-empty.

A canonicalization failure fails the expectation with the number of errors and
a short description of the first.

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


{-| Passes when every `VarTopLevel`, `VarForeign`, `VarCtor`, `VarDebug`,
`VarOperator`, `Binop` and `PCtor` node in the declarations of `canModule` has a
home whose author, project and module name are all non-empty. Otherwise it fails
with one line for each empty part, naming the kind of node and, except for a
`Binop`, which is named only as `operator`, the name it refers to.
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


{-| Returns one message for each empty home part found in the module's
declarations. Only the declarations are walked.
-}
collectGlobalNameIssues : Can.Module -> List String
collectGlobalNameIssues (Can.Module { decls }) =
    collectDeclsIssues decls


{-| Returns the issues found in every definition of a declaration list,
including the definitions of recursive groups.
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


{-| Returns the issues found in a definition's argument patterns and body. A
`TypedDef`'s types are not inspected.
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


{-| Returns the issues found in an expression and everything inside it.
-}
collectExprIssues : Can.Expr -> List String
collectExprIssues (A.At _ { node }) =
    collectExprNodeIssues node


{-| Returns the issues found in an expression node and everything inside it.

The home of a `VarTopLevel`, `VarForeign`, `VarCtor`, `VarDebug`, `VarOperator`
or `Binop` is checked by `validateHome`; a `Binop`'s messages name it by its
operator. A `VarKernel` has no `ModuleName.Canonical` home; its kernel prefix,
kernel module and name are checked by `validateKernel`. `VarLocal` adds
nothing.

-}
collectExprNodeIssues : Can.Expr_ -> List String
collectExprNodeIssues node =
    case node of
        Can.VarLocal _ ->
            []

        Can.VarTopLevel home name ->
            validateHome "VarTopLevel" name home

        Can.VarKernel kernelPrefix kernelHome name ->
            validateKernel kernelPrefix kernelHome name

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

        Can.Binop op home _ _ left right ->
            validateHome "Binop" op home
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
                ++ DMap.foldl
                    (\_ (Can.FieldUpdate _ expr) acc ->
                        collectExprIssues expr ++ acc
                    )
                    []
                    fields

        Can.Record fields ->
            DMap.foldl
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


{-| Returns the issues found in a pattern and every pattern inside it.
-}
collectPatternIssues : Can.Pattern -> List String
collectPatternIssues (A.At _ { node }) =
    collectPatternNodeIssues node


{-| Returns the issues found in a pattern node and the patterns inside it. Only
a `PCtor` has a home to check.
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


{-| Returns one message for each of the author, project and module name of
`home` that is the empty string, each naming the kind of node, `context`, and
the name it refers to, `name`. An empty list means the home is complete.
-}
validateHome : String -> String -> ModuleName.Canonical -> List String
validateHome context name home =
    case home of
        ModuleName.Canonical ( author, project ) moduleName ->
            []
                |> addIssueIf (String.isEmpty author)
                    (context ++ " '" ++ name ++ "': empty package author")
                |> addIssueIf (String.isEmpty project)
                    (context ++ " '" ++ name ++ "': empty package project")
                |> addIssueIf (String.isEmpty moduleName)
                    (context ++ " '" ++ name ++ "': empty module name")


{-| Returns the issues of a `VarKernel` reference: a kernel prefix other than
`Elm` or `Eco` (the two `Name.getKernel` yields), or an empty kernel module or
function name.
-}
validateKernel : String -> String -> String -> List String
validateKernel kernelPrefix kernelHome name =
    []
        |> addIssueIf (kernelPrefix /= "Elm" && kernelPrefix /= "Eco")
            ("VarKernel '" ++ name ++ "': kernel prefix '" ++ kernelPrefix ++ "' is neither Elm nor Eco")
        |> addIssueIf (String.isEmpty kernelHome)
            ("VarKernel '" ++ name ++ "': empty kernel module")
        |> addIssueIf (String.isEmpty name)
            ("VarKernel in kernel module '" ++ kernelHome ++ "': empty name")


{-| Returns `issues` with `issue` added at the front when `condition` holds, and
`issues` unchanged otherwise.
-}
addIssueIf : Bool -> String -> List String -> List String
addIssueIf condition issue issues =
    if condition then
        issue :: issues

    else
        issues


{-| Returns a one-line description of a canonicalization error for a failure
message: the kind of error and the name it concerns, with its module qualifier
when the error carries one. Errors other than `NotFoundVar`, `NotFoundBinop`,
`RecursiveLet`, `NotFoundType`, `NotFoundVariant` and `Shadowing` are all
described as `Other error`.
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
