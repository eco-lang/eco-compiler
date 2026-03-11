module ReviewConfig exposing (config)

{-| Do not rename the ReviewConfig module or the config function, because
`elm-review` will look for these.

To add packages that contain rules, add them to this review project using

    `elm install author/packagename`

when inside the directory containing this file.

-}

import Docs.ReviewAtDocs
import EnforceBoundaries exposing (Layer(..), Stack(..))
import NoInconsistentAliases
import NoConfusingPrefixOperator
import NoDebug.Log
import NoDebug.TodoOrToString
import NoExposingEverything
import NoImportingEverything
import NoMissingTypeAnnotation
import NoMissingTypeAnnotationInLetIn
import NoMissingTypeExpose
import NoPrematureLetComputation
import NoSimpleLetBody
import NoUnused.CustomTypeConstructorArgs
import NoUnused.CustomTypeConstructors
import NoUnused.Dependencies
import NoUnused.Exports
import NoUnused.Parameters
import NoUnused.Patterns
import NoUnused.Variables
import Review.Rule as Rule exposing (Rule)
import Simplify


config : List Rule
config =
    [ NoConfusingPrefixOperator.rule
    , NoDebug.Log.rule
    , NoDebug.TodoOrToString.rule
        |> Rule.ignoreErrorsForDirectories [ "tests/" ]
        |> Rule.ignoreErrorsForFiles [ "src/Utils/Crash.elm", "src-xhr/Eco/Crash.elm" ]
    , NoExposingEverything.rule
    , NoImportingEverything.rule []
    , NoMissingTypeAnnotation.rule
    , NoMissingTypeExpose.rule
    , NoSimpleLetBody.rule
    , NoUnused.Dependencies.rule
    , NoUnused.Variables.rule
    , NoUnused.Patterns.rule
    , NoUnused.Exports.rule
        |> Rule.ignoreErrorsForDirectories [ "src-xhr/" ]
    , Simplify.rule Simplify.defaults
    , NoUnused.CustomTypeConstructors.rule []
        |> Rule.ignoreErrorsForFiles [ "src/Compiler/AST/Monomorphized.elm" ]
        |> Rule.ignoreErrorsForDirectories [ "src-xhr/" ]
    , Docs.ReviewAtDocs.rule

    --, NoUnused.CustomTypeConstructorArgs.rule
    , NoUnused.Parameters.rule
        |> Rule.ignoreErrorsForFiles [ "src/Utils/Crash.elm" ]
    , EnforceBoundaries.rule moduleLayerRule
    , NoInconsistentAliases.config
        [ ( "Builder.Deps.Diff", "Diff" )
        , ( "Compiler.AST.DecisionTree.Path", "Path" )
        , ( "Compiler.AST.DecisionTree.Test", "Test" )
        , ( "Compiler.AST.DecisionTree.TypedPath", "TypedPath" )
        , ( "Compiler.Data.Name", "Name" )
        , ( "Compiler.Elm.Compiler.Type", "CompType" )
        , ( "Compiler.Elm.Constraint", "Con" )
        , ( "Compiler.Elm.Kernel", "Kernel" )
        , ( "Compiler.Generate.JavaScript.Name", "JsName" )
        , ( "Compiler.Generate.MLIR.Context", "Ctx" )
        , ( "Compiler.Json.Decode", "Decode" )
        , ( "Compiler.Json.Encode", "Encode" )
        , ( "Compiler.Nitpick.PatternMatches", "PatMatch" )
        , ( "Compiler.Parse.Declaration", "Decl" )
        , ( "Compiler.Parse.Expression", "Expr" )
        , ( "Compiler.Parse.Keyword", "Keyword" )
        , ( "Compiler.Parse.Module", "Module" )
        , ( "Compiler.Parse.Space", "Space" )
        , ( "Compiler.Parse.Type", "Type" )
        , ( "Compiler.Parse.Variable", "Var" )
        , ( "Compiler.Reporting.Doc", "Doc" )
        , ( "Compiler.Reporting.Error", "Error" )
        , ( "Compiler.Reporting.Error.Canonicalize", "ErrorCanonicalize" )
        , ( "Compiler.Reporting.Error.Docs", "ErrorDocs" )
        , ( "Compiler.Reporting.Error.Main", "ErrorMain" )
        , ( "Compiler.Reporting.Error.Syntax", "Syntax" )
        , ( "Compiler.Reporting.Error.Type", "ErrorType" )
        , ( "Compiler.Reporting.Render.Type", "RenderType" )
        , ( "Compiler.Reporting.Render.Type.Localizer", "Localizer" )
        , ( "Compiler.Reporting.Warning", "Warning" )
        , ( "Compiler.Type.Error", "TypeError" )
        , ( "Data.Map", "AnyDict" )
        , ( "Dict", "Dict" )
        , ( "List.Extra", "List" )
        , ( "System.IO", "IO" )
        , ( "System.TypeCheck.IO", "IO" )
        , ( "Utils.Task.Extra", "TaskExtra" )
        ]
        |> NoInconsistentAliases.rule
    ]


moduleLayerRule : Stack
moduleLayerRule =
    LayerStack
        [ ast
        , parser
        , canonicalize
        , typecheck
        , nitpick
        , localopt
        , monomorphize
        , globalopt
        , generate
        ]


ast : Layer
ast =
    PrefixLayer
        [ [ "Compiler", "AST" ] ]


parser : Layer
parser =
    PrefixLayer
        [ [ "Compiler", "Parse" ] ]


canonicalize : Layer
canonicalize =
    PrefixLayer
        [ [ "Compiler", "Canonicalize" ] ]


typecheck : Layer
typecheck =
    PrefixLayer
        [ [ "Compiler", "Type" ] ]


nitpick : Layer
nitpick =
    PrefixLayer
        [ [ "Compiler", "Nitpick" ] ]


localopt : Layer
localopt =
    PrefixLayer
        [ [ "Compiler", "LocalOpt" ] ]


monomorphize : Layer
monomorphize =
    PrefixLayer
        [ [ "Compiler", "Monomorphize" ] ]


globalopt : Layer
globalopt =
    PrefixLayer
        [ [ "Compiler", "GlobalOpt" ] ]


generate : Layer
generate =
    PrefixLayer
        [ [ "Compiler", "Generate" ] ]
