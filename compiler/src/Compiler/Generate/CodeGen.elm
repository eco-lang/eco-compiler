module Compiler.Generate.CodeGen exposing
    ( Output(..), outputToString
    , SourceMaps(..)
    , Mains, TypedMains
    , CodeGen, TypedCodeGen, MonoCodeGen
    )

{-| Backend interface definitions for code generation.

This module defines the abstract interface that all compiler backends must implement.
It supports three different backend types based on the level of type information needed:

1.  CodeGen - Standard backends working with optimized AST (JavaScript)
2.  TypedCodeGen - Backends needing full type information (MLIR with type-directed optimizations)
3.  MonoCodeGen - Backends working with fully monomorphized IR (MLIR production)


# Output Types

@docs Output, outputToString


# Source Maps

@docs SourceMaps


# Main Entry Points

@docs Mains, TypedMains


# Backend Interfaces

@docs CodeGen, TypedCodeGen, MonoCodeGen

-}

import Compiler.AST.Canonical as Can
import Compiler.AST.Monomorphized as Mono
import Compiler.AST.Optimized as Opt
import Compiler.AST.TypedOptimized as TOpt
import Compiler.Data.Name as Name
import Compiler.Generate.Mode as Mode
import Compiler.Reporting.Render.Type.Localizer as L
import Data.Map exposing (Dict)
import System.TypeCheck.IO as IO



-- OUTPUT


{-| Output from code generation - either a string or binary data
-}
type Output
    = TextOutput String


{-| Extract the string content from an Output value
-}
outputToString : Output -> String
outputToString output =
    case output of
        TextOutput s ->
            s


{-| The CodeGen interface - a record of functions that any backend must implement.

Each backend provides implementations for:

  - Full program generation
  - REPL expression evaluation
  - REPL endpoint generation (for browser REPL)

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
        , home : IO.Canonical
        , name : Name.Name
        , annotation : Can.Annotation
        }
        -> Output

    -- Generate code for browser-based REPL endpoint
    , generateForReplEndpoint :
        { localizer : L.Localizer
        , graph : Opt.GlobalGraph
        , home : IO.Canonical
        , maybeName : Maybe Name.Name
        , annotation : Can.Annotation
        }
        -> Output
    }



-- MAINS


type alias Mains =
    Dict (List String) IO.Canonical Opt.Main


type alias TypedMains =
    Dict (List String) IO.Canonical TOpt.Main



-- SOURCE MAPS


type SourceMaps
    = NoSourceMaps
    | SourceMaps (Dict (List String) IO.Canonical String)



-- TYPED CODE GEN
-- Interface for backends that need full type information (e.g., MLIR)


{-| The TypedCodeGen interface for backends that need type information.

This is used by backends like MLIR that need types for monomorphization.

-}
type alias TypedCodeGen =
    { -- Generate a complete program from the typed optimized global graph
      generate :
        { sourceMaps : SourceMaps
        , leadingLines : Int
        , mode : Mode.Mode
        , graph : TOpt.GlobalGraph
        , mains : TypedMains
        }
        -> Output
    }



-- MONO CODE GEN
-- Interface for backends that work with fully monomorphized IR


{-| The MonoCodeGen interface for backends that work with monomorphized IR.

This is used by backends that need fully specialized, monomorphic code
with no polymorphism remaining.

-}
type alias MonoCodeGen =
    { -- Generate a complete program from the monomorphized graph
      generate :
        { sourceMaps : SourceMaps
        , leadingLines : Int
        , mode : Mode.Mode
        , graph : Mono.MonoGraph
        }
        -> Output
    }
