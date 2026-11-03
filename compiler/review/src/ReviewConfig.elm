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
import NoCrossBranchImports
import NoDebug.Log
import NoDebug.TodoOrToString
import NoExposingEverything
import NoImportingEverything
import NoInconsistentAliases
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
        |> Rule.ignoreErrorsForFiles [ "src/System/Crash.elm", "src-xhr/Eco/Crash.elm" ]
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

    -- , Simplify.rule Simplify.defaults
    , NoUnused.CustomTypeConstructors.rule []
        |> Rule.ignoreErrorsForFiles [ "src/Compiler/IR/Mono.elm" ]
        |> Rule.ignoreErrorsForDirectories [ "src-xhr/" ]
    , Docs.ReviewAtDocs.rule

    --, NoUnused.CustomTypeConstructorArgs.rule
    , NoUnused.Parameters.rule
        |> Rule.ignoreErrorsForFiles
            [ "src/System/Crash.elm"

            -- Stock-Elm twins of eco-kernel-cpp modules: their signatures must
            -- match the kernel versions, which do use these parameters.
            , "src-xhr/Eco/Console.elm"
            , "src-xhr/Eco/NativeDriver.elm"
            ]
    , EnforceBoundaries.rule moduleLayerRule
        |> Rule.ignoreErrorsForDirectories [ "tests/" ]
    , NoCrossBranchImports.rule branchSeparation
        |> Rule.ignoreErrorsForDirectories [ "tests/" ]

    --, NoInconsistentAliases.config
    --    [ ( "Builder.Deps.Diff", "Diff" )
    --    , ( "Compiler.IR.DecisionTree.Path", "Path" )
    --    , ( "Compiler.IR.DecisionTree.Test", "Test" )
    --    , ( "Compiler.IR.DecisionTree.TypedPath", "TypedPath" )
    --    , ( "Compiler.Core.Name", "Name" )
    --    , ( "Compiler.Docs.Type", "CompType" )
    --    , ( "Compiler.Elm.Constraint", "Con" )
    --    , ( "Compiler.Parse.Kernel", "Kernel" )
    --    , ( "Compiler.GenerateJs.Name", "JsName" )
    --    , ( "Compiler.GenerateMlir.Context", "Ctx" )
    --    , ( "Compiler.Json.Decode", "Decode" )
    --    , ( "Compiler.Json.Encode", "Encode" )
    --    , ( "Compiler.Nitpick.PatternMatches", "PatMatch" )
    --    , ( "Compiler.Parse.Declaration", "Decl" )
    --    , ( "Compiler.Parse.Expression", "Expr" )
    --    , ( "Compiler.Lexer.Keyword", "Keyword" )
    --    , ( "Compiler.Parse.Module", "Module" )
    --    , ( "Compiler.Parse.Space", "Space" )
    --    , ( "Compiler.Parse.Type", "Type" )
    --    , ( "Compiler.Parse.Variable", "Var" )
    --    , ( "Compiler.Reporting.Doc", "Doc" )
    --    , ( "Compiler.Error", "Error" )
    --    , ( "Compiler.Canonicalize.Error", "ErrorCanonicalize" )
    --    , ( "Compiler.Docs.Error", "ErrorDocs" )
    --    , ( "Compiler.LocalOpt.Error", "ErrorMain" )
    --    , ( "Compiler.Parse.Error", "Syntax" )
    --    , ( "Compiler.Type.Error", "ErrorType" )
    --    , ( "Compiler.Reporting.Render.Type", "RenderType" )
    --    , ( "Compiler.Reporting.Render.Type.Localizer", "Localizer" )
    --    , ( "Compiler.Reporting.Warning", "Warning" )
    --    , ( "Compiler.Type.ErrorType", "TypeError" )
    --    , ( "Data.Map", "AnyDict" )
    --    , ( "Dict", "Dict" )
    --    , ( "List.Extra", "List" )
    --    , ( "System.IO", "IO" )
    --    , ( "Compiler.Type.State.IO", "IO" )
    --    , ( "Utils.Task.Extra", "TaskExtra" )
    --    ]
    --    |> NoInconsistentAliases.rule
    ]


moduleLayerRule : Stack
moduleLayerRule =
    LayerStack
        [ libraries
        , compilerLayer "Core"
        , compilerLayer "Lexer"
        , compilerLayer "Json"
        , compilerLayer "Config"
        , compilerLayer "Elm"
        , compilerLayer "IR"
        , compilerLayer "Reporting"
        , compilerLayer "Parse"
        , compilerLayer "Docs"
        , compilerLayer "Canonicalize"
        , compilerLayer "Type"
        , compilerLayer "Nitpick"
        , compilerLayer "LocalOpt"
        , compilerLayer "GenerateJs"
        , compilerLayer "PreMono"
        , compilerLayer "Monomorphize"
        , compilerLayer "MonoOpt"
        , compilerLayer "GenerateMlir"
        , compilerLayer "Error"
        , compilerLayer "Compile"
        , compilerLayer "Pipeline"
        , driver
        ]


{-| The generic libraries, which know nothing of the compiler.
-}
libraries : Layer
libraries =
    PrefixLayer
        [ [ "Data" ]
        , [ "Utils" ]
        , [ "System" ]
        , [ "Text" ]
        , [ "Control" ]
        , [ "Prelude" ]
        , [ "Codec" ]
        , [ "Mlir" ]
        ]


{-| One top-level folder of `Compiler/`, a shared foundation or a pass.
-}
compilerLayer : String -> Layer
compilerLayer folder =
    PrefixLayer
        [ [ "Compiler", folder ] ]


{-| The build driver and the command line, which may use any part of the
compiler.
-}
driver : Layer
driver =
    PrefixLayer
        [ [ "Builder" ]
        , [ "API" ]
        , [ "Terminal" ]
        , [ "Common" ]
        ]


{-| The JavaScript back end and the typed branch (pre-mono, monomorphization,
mono-opt and MLIR generation) both follow `Compiler.LocalOpt`; neither may
import the other. The layer stack cannot say this, since it orders
`Compiler.GenerateJs` below the typed branch.
-}
branchSeparation : NoCrossBranchImports.Branches
branchSeparation =
    NoCrossBranchImports.Branches
        [ [ "Compiler", "GenerateJs" ] ]
        [ [ "Compiler", "PreMono" ]
        , [ "Compiler", "Monomorphize" ]
        , [ "Compiler", "MonoOpt" ]
        , [ "Compiler", "GenerateMlir" ]
        ]
