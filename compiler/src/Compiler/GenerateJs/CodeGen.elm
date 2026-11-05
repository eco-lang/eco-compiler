module Compiler.GenerateJs.CodeGen exposing
    ( Output(..), outputToString
    , SourceMaps(..)
    , Mains
    , CodeGen
    )

{-| The contract between the builder and the JavaScript code generator: the
builder drives the backend through one function.

A backend is a `CodeGen` value: a function from the optimized program graph,
the `Mains` to start from and whether to emit `SourceMaps`, to the generated
`Output`.

The MLIR backend does not implement this interface; it streams its output
through its own entry points in `Compiler.GenerateMlir.Backend`.


# Output Types

@docs Output, outputToString


# Source Maps

@docs SourceMaps


# Main Entry Points

@docs Mains


# Backend Interfaces

@docs CodeGen

-}

import Compiler.Elm.ModuleName as ModuleName
import Compiler.GenerateJs.Mode as Mode
import Compiler.IR.Optimized as Opt
import Data.Map exposing (Dict)



-- ====== OUTPUT ======


{-| What a backend produces. `TextOutput` is the only kind, and carries the
generated code as one string.
-}
type Output
    = TextOutput String


{-| Returns the generated code held by `output`.
-}
outputToString : Output -> String
outputToString output =
    case output of
        TextOutput s ->
            s


{-| A code generator: produces a whole program that starts from `mains`.

`leadingLines` is the number of lines the caller will place before the
generated code; it is added to every generated line number in the source map,
and is unused when `sourceMaps` is `NoSourceMaps`.

-}
type alias CodeGen =
    { sourceMaps : SourceMaps
    , leadingLines : Int
    , mode : Mode.Mode
    , graph : Opt.GlobalGraph
    , mains : Mains
    }
    -> Output



-- ====== MAINS ======


{-| The program's entry points: the `main` of each root module that defines one,
keyed by module name.
-}
type alias Mains =
    Dict String ModuleName.Canonical Opt.Main



-- ====== SOURCE MAPS ======


{-| Whether to append a source map to generated JavaScript.

`SourceMaps` carries the source text of each module, keyed by module name,
which is embedded in the map.

-}
type SourceMaps
    = NoSourceMaps
    | SourceMaps (Dict String ModuleName.Canonical String)
