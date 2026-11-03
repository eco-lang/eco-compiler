module Compiler.GenerateJs exposing (backend)

{-| The JavaScript code generator, packaged as the `CodeGen` record a builder
calls, so that a builder can produce JavaScript without depending on
`Compiler.GenerateJs.Generate` directly.

The generation itself is done in `Compiler.GenerateJs.Generate`, whose
functions take their inputs as positional arguments. `backend` passes each
field of the configuration record `Compiler.GenerateJs.CodeGen` defines to the
matching function, and wraps the JavaScript it returns in `TextOutput`.


# Backend

@docs backend

-}

import Compiler.GenerateJs.CodeGen as CodeGen
import Compiler.GenerateJs.Generate as JS


{-| The JavaScript code generator as a `CodeGen`: its whole-program, terminal
REPL and browser REPL functions are `Compiler.GenerateJs.Generate`'s
`generate`, `generateForRepl` and `generateForReplEndpoint`, each with its
result wrapped in `TextOutput`.
-}
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
