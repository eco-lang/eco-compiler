module TestLogic.Generate.JavaScript.InfiniteFloatLiteralTest exposing (suite)

{-| An infinite Float literal (`1e400`) in Elm source reaches the JavaScript
backend as an infinite `Opt.Float`, and
`Compiler.Generate.JavaScript.Expression` emits it as `Infinity.0`, which is
not JavaScript: `eco make --output=main.js` on such a program writes a file
that node rejects with "SyntaxError: Unexpected number"
(`var $author$project$Main$big = Infinity.0;`).

Also covered by the unit test
compiler/tests/Compiler/Generate/JavaScript/ExpressionTest.elm, which builds
the `Opt.Float` by hand; here the input is source text, parsed, canonicalized,
type checked and optimized by the erased path the JS build uses
(`Compiler.LocalOpt.Erased.Module.optimize`), and every definition is
generated with `Expression.generate`.

EXPECTED TO FAIL until fixed.

-}

import Compiler.AST.Optimized as Opt
import Compiler.AST.Source as Src
import Compiler.AST.SourceBuilder exposing (makeModule, unitExpr)
import Compiler.Elm.ModuleName as ModuleName
import Compiler.Elm.Package as Pkg
import Compiler.Generate.JavaScript.Builder as JS
import Compiler.Generate.JavaScript.Expression as Expr
import Compiler.Generate.Mode as Mode
import Compiler.LocalOpt.Erased.Module as ErasedOptimize
import Compiler.Parse.Module as M
import Compiler.Reporting.Result as RResult
import Data.Map
import Expect
import Test exposing (Test)
import TestLogic.TestPipeline as Pipeline


suite : Test
suite =
    Test.describe "JS backend: infinite Float literal from source"
        [ Test.test "1e400 and -1e400 are not emitted as Infinity.0" <|
            \_ ->
                case generatedDefinitions source of
                    Err msg ->
                        Expect.fail msg

                    Ok js ->
                        List.filter (String.contains "Infinity.0") js
                            |> Expect.equal []
        ]


source : String
source =
    """module Test exposing (..)


big : Float
big =
    1e400


small : Float
small =
    -1e400
"""


parse : String -> Result String Src.Module
parse src =
    case M.fromByteString M.Application src of
        Ok (Src.Module m) ->
            let
                (Src.Module template) =
                    makeModule "unused" unitExpr
            in
            Ok (Src.Module { m | imports = template.imports })

        Err _ ->
            Err "fixture failed to parse"


{-| The JavaScript of every `Define` node of the optimized module.
-}
generatedDefinitions : String -> Result String (List String)
generatedDefinitions src =
    parse src
        |> Result.andThen Pipeline.runToTypeCheck
        |> Result.andThen
            (\{ canonical, annotations } ->
                case RResult.run (ErasedOptimize.optimize annotations canonical) of
                    ( _, Ok (Opt.LocalGraph _ nodes _) ) ->
                        Ok (List.filterMap renderNode (Data.Map.values nodes))

                    ( _, Err _ ) ->
                        Err "optimization failed"
            )


renderNode : Opt.Node -> Maybe String
renderNode node =
    case node of
        Opt.Define expr _ ->
            Just (render expr)

        Opt.TrackedDefine _ expr _ ->
            Just (render expr)

        _ ->
            Nothing


render : Opt.Expr -> String
render expr =
    let
        (JS.Builder b) =
            JS.exprToBuilder (Expr.codeToExpr (Expr.generate (Mode.Dev Nothing) home expr)) (JS.emptyBuilder 1)
    in
    b.revBuilders


home : ModuleName.Canonical
home =
    ModuleName.Canonical Pkg.dummyName "Test"
