module Compiler.GenerateJs exposing (backend)

{-| The JavaScript code generator, packaged as the `CodeGen` function a builder
calls, so that a builder can produce JavaScript without depending on
`Compiler.GenerateJs.Generate` directly.

The generation itself is done in `Compiler.GenerateJs.Generate`, whose
`generate` takes its inputs as positional arguments. `backend` passes it each
field of the configuration record that `Compiler.GenerateJs.CodeGen` defines,
and wraps the JavaScript it returns in `TextOutput`.


# Backend

@docs backend

-}

import Compiler.GenerateJs.CodeGen as CodeGen
import Compiler.GenerateJs.Generate as JS


{-| The JavaScript code generator as a `CodeGen`: `Compiler.GenerateJs.Generate`'s
`generate`, with its result wrapped in `TextOutput`.
-}
backend : CodeGen.CodeGen
backend config =
    CodeGen.TextOutput <|
        JS.generate
            config.sourceMaps
            config.leadingLines
            config.mode
            config.graph
            config.mains
