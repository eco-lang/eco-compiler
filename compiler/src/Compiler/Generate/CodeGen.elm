module Compiler.Generate.CodeGen exposing
    ( Output(..), outputToString
    , SourceMaps(..)
    , Mains
    , CodeGen
    )

{-| Backend interface definitions for code generation.

This module defines the interface the JavaScript backend implements over the
optimized AST. The MLIR backend streams its output instead
(`Compiler.Generate.MLIR.Backend`).


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


{-| Output from code generation: currently always text (`TextOutput`).
-}
type Output
    = TextOutput String


{-| Extract the string content from an Output value.
-}
outputToString : Output -> String
outputToString output =
    case output of
        TextOutput s ->
            s


{-| The CodeGen interface that standard backends must implement for full program generation, REPL evaluation, and browser REPL endpoints.
-}
type alias CodeGen =
    { -- Generate a complete program from the optimized global graph
      generate :
        { sourceMaps : SourceMaps
        , leadingLines : Int
        , mode : Mode.Mode
        , graph : Opt.GlobalGraph
        , mains : Mains
        }
        -> Output

    -- Generate code for REPL evaluation
    , generateForRepl :
        { ansi : Bool
        , localizer : L.Localizer
        , graph : Opt.GlobalGraph
        , home : ModuleName.Canonical
        , name : Name.Name
        , annotation : Can.Annotation Name
        }
        -> Output

    -- Generate code for browser-based REPL endpoint
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


{-| Map from module names to their main entry points for standard optimized AST.
-}
type alias Mains =
    Dict String ModuleName.Canonical Opt.Main



-- ====== SOURCE MAPS ======


{-| Configuration for source map generation - either disabled or enabled with module source content.
-}
type SourceMaps
    = NoSourceMaps
    | SourceMaps (Dict String ModuleName.Canonical String)

