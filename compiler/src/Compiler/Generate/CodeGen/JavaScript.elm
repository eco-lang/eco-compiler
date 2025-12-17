module Compiler.Generate.CodeGen.JavaScript exposing (backend)

{-| JavaScript code generation backend.

This module provides the JavaScript backend implementation that conforms to the CodeGen
interface. It generates optimized JavaScript code from the optimized AST, with support
for full program compilation, REPL evaluation, and browser-based REPL endpoints.

The backend delegates to the Compiler.Generate.JavaScript module for the actual code
generation logic.


# Backend

@docs backend

-}

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
