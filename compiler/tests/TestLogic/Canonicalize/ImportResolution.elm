module TestLogic.Canonicalize.ImportResolution exposing (expectImportsResolved)

{-| A test expectation for the rule that every name a module takes from another
module resolves to a definition that module's interface provides, with the
interface's type.

Canonicalization is the compiler stage that resolves each name in a module to
the module that defines it, using the interfaces of the modules it imports. A
name an import lists in its `exposing` clause that the imported module does not
export, and a reference, qualified or not, to a name that nothing in scope
provides, are canonicalization errors.

`expectImportsResolved` runs a module through `TestLogic.TestPipeline.runToPostSolve`
(canonicalization, type checking and PostSolve, against the mock interfaces of
`Compiler.Elm.Interface.Basic.testIfaces`) and fails if canonicalization or
type checking fails. After a success it walks every expression in the
top-level definitions of the canonical module and checks each reference to
another module against that module's interface in `testIfaces`:

  - a `VarForeign` must name a value of the interface, carry its annotation,
    and carry the interface's package in its home;
  - a `VarCtor` whose home is another module must name a constructor of one of
    the interface's custom types, at that constructor's index, or a record type
    alias of the interface;
  - a `VarOperator` or `Binop` must name an operator of the interface, and the
    function it carries must be the one that operator stands for.

Not checked: patterns (`PCtor` homes), type annotations, `VarDebug` and
`VarKernel` references, and whether the reference is to the definition the
programmer meant.

An import of a module that has no interface crashes the canonicalizer when
that import is reached, rather than failing the expectation.

-}

import Compiler.AST.Canonical as Can
import Compiler.AST.Source as Src
import Compiler.Data.Index as Index
import Compiler.Elm.Interface as I
import Compiler.Elm.Interface.Basic as Basic
import Compiler.Elm.ModuleName as ModuleName
import Compiler.Reporting.Annotation as A
import Data.Map as DMap
import Dict
import Expect
import TestLogic.TestPipeline as Pipeline


{-| Passes when `srcModule` gets through canonicalization, type checking and
PostSolve and every reference to another module resolves as the module
docstring describes. Fails with the pipeline's message when a stage fails, and
with one line per unresolved reference otherwise.
-}
expectImportsResolved : Src.Module -> Expect.Expectation
expectImportsResolved srcModule =
    case Pipeline.runToPostSolve srcModule of
        Err msg ->
            Expect.fail msg

        Ok result ->
            let
                issues =
                    collectImportIssues result.canonical
            in
            if List.isEmpty issues then
                Expect.pass

            else
                Expect.fail (String.join "\n" issues)



-- ============================================================================
-- REFERENCE WALK
-- ============================================================================


{-| Returns a message for each unresolved reference to another module in the
top-level definitions of a canonical module.
-}
collectImportIssues : Can.Module -> List String
collectImportIssues (Can.Module moduleData) =
    collectDefsImportIssues moduleData.name moduleData.decls


{-| Returns the problems found in every definition of a declaration list,
including each definition of a recursive group.
-}
collectDefsImportIssues : ModuleName.Canonical -> Can.Decls -> List String
collectDefsImportIssues self decls =
    case decls of
        Can.Declare def rest ->
            collectDefImportIssues self def
                ++ collectDefsImportIssues self rest

        Can.DeclareRec def defs rest ->
            List.concatMap (collectDefImportIssues self) (def :: defs)
                ++ collectDefsImportIssues self rest

        Can.SaveTheEnvironment ->
            []


{-| Returns the problems found in the body of a definition.
-}
collectDefImportIssues : ModuleName.Canonical -> Can.Def -> List String
collectDefImportIssues self def =
    case def of
        Can.Def _ _ expr ->
            collectExprImportIssues self expr

        Can.TypedDef _ _ _ expr _ ->
            collectExprImportIssues self expr


{-| Returns the problems found in an expression and the expressions inside it.
-}
collectExprImportIssues : ModuleName.Canonical -> Can.Expr -> List String
collectExprImportIssues self (A.At _ exprInfo) =
    let
        go =
            collectExprImportIssues self
    in
    case exprInfo.node of
        Can.VarForeign home name annotation ->
            checkForeignValue home name annotation

        Can.VarCtor _ home name index _ ->
            if home == self then
                []

            else
                checkForeignCtor home name index

        Can.VarOperator op home name _ ->
            checkForeignBinop op home name

        Can.Binop op home name _ left right ->
            checkForeignBinop op home name
                ++ go left
                ++ go right

        Can.Lambda _ body ->
            go body

        Can.Call fn args ->
            List.concatMap go (fn :: args)

        Can.If branches else_ ->
            List.concatMap (\( cond, then_ ) -> go cond ++ go then_) branches
                ++ go else_

        Can.Let def body ->
            collectDefImportIssues self def
                ++ go body

        Can.LetRec defs body ->
            List.concatMap (collectDefImportIssues self) defs
                ++ go body

        Can.LetDestruct _ value body ->
            go value ++ go body

        Can.Case value branches ->
            go value
                ++ List.concatMap (\(Can.CaseBranch _ branchExpr) -> go branchExpr) branches

        Can.Access record _ ->
            go record

        Can.Update record fields ->
            go record
                ++ DMap.foldl (\_ (Can.FieldUpdate _ fieldExpr) acc -> go fieldExpr ++ acc) [] fields

        Can.Record fields ->
            DMap.foldl (\_ fieldExpr acc -> go fieldExpr ++ acc) [] fields

        Can.Tuple a b rest ->
            List.concatMap go (a :: b :: rest)

        Can.List exprs ->
            List.concatMap go exprs

        Can.Negate negatedExpr ->
            go negatedExpr

        _ ->
            []


{-| Looks up the interface of `home` in `Basic.testIfaces`, and passes it to
`check` when it is found and was built for the package `home` names.
-}
withInterface : String -> ModuleName.Canonical -> String -> (I.InterfaceData -> List String) -> List String
withInterface kind (ModuleName.Canonical pkg moduleName) name check =
    case Dict.get moduleName Basic.testIfaces of
        Nothing ->
            [ kind ++ " '" ++ moduleName ++ "." ++ name ++ "': no interface for module '" ++ moduleName ++ "'" ]

        Just (I.Interface data) ->
            if data.home /= pkg then
                [ kind ++ " '" ++ moduleName ++ "." ++ name ++ "': home package does not match the interface's" ]

            else
                check data


{-| Checks a `VarForeign` reference against its home's interface.
-}
checkForeignValue : ModuleName.Canonical -> String -> Can.Annotation String -> List String
checkForeignValue home name annotation =
    withInterface "VarForeign" home name <|
        \data ->
            case Dict.get name data.values of
                Nothing ->
                    [ "VarForeign '" ++ name ++ "': not a value of its home's interface" ]

                Just ifaceAnnotation ->
                    if ifaceAnnotation == annotation then
                        []

                    else
                        [ "VarForeign '" ++ name ++ "': annotation differs from its home's interface" ]


{-| Checks a `VarCtor` reference to another module against that module's
interface: a constructor of one of its custom types at the same index, or a
record type alias.
-}
checkForeignCtor : ModuleName.Canonical -> String -> Index.ZeroBased -> List String
checkForeignCtor home name index =
    withInterface "VarCtor" home name <|
        \data ->
            let
                unionCtor (Can.Union u) =
                    List.any (\(Can.Ctor c) -> c.name == name && c.index == index) u.alts

                inUnions =
                    Dict.values data.unions
                        |> List.any
                            (\u ->
                                case u of
                                    I.OpenUnion cu ->
                                        unionCtor cu

                                    I.ClosedUnion cu ->
                                        unionCtor cu

                                    I.PrivateUnion cu ->
                                        unionCtor cu
                            )
            in
            if inUnions || Dict.member name data.aliases then
                []

            else
                [ "VarCtor '" ++ name ++ "': not a constructor (at that index) or record alias of its home's interface" ]


{-| Checks an operator reference against its home's interface: the operator
exists and stands for the function `name`.
-}
checkForeignBinop : String -> ModuleName.Canonical -> String -> List String
checkForeignBinop op home name =
    withInterface "Operator" home op <|
        \data ->
            case Dict.get op data.binops of
                Nothing ->
                    [ "Operator '" ++ op ++ "': not an operator of its home's interface" ]

                Just (I.Binop binop) ->
                    if binop.name == name then
                        []

                    else
                        [ "Operator '" ++ op ++ "': carries function '" ++ name ++ "' but the interface maps it to '" ++ binop.name ++ "'" ]
