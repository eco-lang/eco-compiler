module Compiler.Generate.CodeGen exposing
    ( CodeGen
    , Mains
    , Output(..)
    , SourceMaps(..)
    , TypedCodeGen
    , TypedMains
    , outputToString
    )

import Compiler.AST.Canonical as Can
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
