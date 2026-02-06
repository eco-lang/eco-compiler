module ReviewConfig exposing (config)

{-| Do not rename the ReviewConfig module or the config function, because
`elm-review` will look for these.

To add packages that contain rules, add them to this review project using

    `elm install author/packagename`

when inside the directory containing this file.

-}

import Docs.ReviewAtDocs
import EnforceBoundaries exposing (Layer(..), Stack(..))
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
    , NoExposingEverything.rule
    , NoImportingEverything.rule []
    , NoMissingTypeAnnotation.rule
    , NoMissingTypeExpose.rule
    , NoSimpleLetBody.rule
    , NoUnused.Dependencies.rule
    , NoUnused.Variables.rule
    , NoUnused.Patterns.rule
    , NoUnused.Exports.rule
        |> Rule.ignoreErrorsForFiles [ "src/Compiler/Parse/Expression.elm" ]
    , Simplify.rule Simplify.defaults
    , NoUnused.CustomTypeConstructors.rule []
    , Docs.ReviewAtDocs.rule

    --, NoUnused.CustomTypeConstructorArgs.rule
    , NoUnused.Parameters.rule
        |> Rule.ignoreErrorsForFiles [ "src/Utils/Crash.elm" ]
    , EnforceBoundaries.rule moduleLayerRule
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
