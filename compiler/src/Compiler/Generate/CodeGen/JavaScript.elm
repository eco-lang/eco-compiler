module Compiler.Generate.CodeGen.JavaScript exposing (backend)

import Compiler.Generate.CodeGen as CodeGen
import Compiler.Generate.JavaScript as JS


backend : CodeGen.CodeGen
backend =
    { generate =
        \config ->
            CodeGen.TextOutput <|
                JS.generate
                    config.sourceMaps
                    config.leadingLines
                    config.mode
                    config.graph
                    config.mains
    , generateForRepl =
        \config ->
            CodeGen.TextOutput <|
                JS.generateForRepl
                    config.ansi
                    config.localizer
                    config.graph
                    config.home
                    config.name
                    config.annotation
    , generateForReplEndpoint =
        \config ->
            CodeGen.TextOutput <|
                JS.generateForReplEndpoint
                    config.localizer
                    config.graph
                    config.home
                    config.maybeName
                    config.annotation
    }
