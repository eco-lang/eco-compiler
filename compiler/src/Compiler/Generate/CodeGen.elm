module Compiler.Generate.CodeGen exposing
    ( Output(..), outputToString
    , SourceMaps(..)
    , Mains
    , CodeGen
    )

{-| The contract between the builder and the JavaScript code generator: the
builder drives the backend through a record of functions.

A backend is a `CodeGen` value: a record of three functions, each taking the
optimized program graph and returning `Output`. One generates a whole program,
one generates the code that evaluates and prints a single value for the
terminal REPL, and one generates code that sends a value to a browser REPL. The
remaining types describe what the whole-program function is given: the `Mains`
to start from and whether to emit `SourceMaps`.

The MLIR backend does not implement this interface; it streams its output
through its own entry points in `Compiler.Generate.MLIR.Backend`.


# Output Types

@docs Output, outputToString


# Source Maps

@docs SourceMaps


# Main Entry Points

@docs Mains


# Backend Interfaces

@docs CodeGen

-}

import Compiler.AST.Canonical as Can
import Compiler.AST.Optimized as Opt
import Compiler.Data.Name as Name exposing (Name)
import Compiler.Elm.ModuleName as ModuleName
import Compiler.Generate.Mode as Mode
import Compiler.Reporting.Render.Type.Localizer as L
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


{-| A code generator, as the three functions a builder calls on it.

`generate` produces a whole program that starts from `mains`. Its
`leadingLines` is the number of lines the caller will place before the
generated code; it is added to every generated line number in the source map,
and is unused when `sourceMaps` is `NoSourceMaps`.

`generateForRepl` produces code for the terminal REPL that evaluates `name` in
module `home` and prints it, with type `annotation`; `ansi` asks for coloured
output.

`generateForReplEndpoint` produces code for a REPL running in a browser that
sends the value's name, rendered value and type with `self.postMessage`.
When `maybeName` is `Nothing`, the value posted is the one the REPL binds to
`Name.replValueToPrint` and the message's name is null.

-}
type alias CodeGen =
    { generate :
        { sourceMaps : SourceMaps
        , leadingLines : Int
        , mode : Mode.Mode
        , graph : Opt.GlobalGraph
        , mains : Mains
        }
        -> Output
    , generateForRepl :
        { ansi : Bool
        , localizer : L.Localizer
        , graph : Opt.GlobalGraph
        , home : ModuleName.Canonical
        , name : Name.Name
        , annotation : Can.Annotation Name
        }
        -> Output
    , generateForReplEndpoint :
        { localizer : L.Localizer
        , graph : Opt.GlobalGraph
        , home : ModuleName.Canonical
        , maybeName : Maybe Name.Name
        , annotation : Can.Annotation Name
        }
        -> Output
    }



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
