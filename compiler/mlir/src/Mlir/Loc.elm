module Mlir.Loc exposing (Loc(..), Pos, unknown)

{-| Every MLIR operation and module the compiler builds has a location field,
which either names a place in the source or says that the place is unknown.
This module is the type of that field.

A location names a file and spans a range within it, from a start position to
an end position, each a row and a column. Nothing here says whether rows and
columns count from zero or from one.

`unknown` is the location to use when no source position is available. Its
file name is the string `"unknown"` and both positions are 0:0. It is an
ordinary value, not a separate constructor. `Mlir.Bytecode.AttrType` treats any
location named `"unknown"` that starts at 0:0 as MLIR's unknown location.

@docs Loc, Pos, unknown

-}


{-| A place in the source: a range in a named file from `start` to `end`, or
the placeholder `unknown`.

The constructor is exposed, so any name and any positions can be given; nothing
checks that the file exists or that `start` comes before `end`.

-}
type Loc
    = Loc
        { name : String
        , start : Pos
        , end : Pos
        }


{-| A position in a source file, as a row and a column.
-}
type alias Pos =
    { row : Int
    , col : Int
    }


{-| The location given to an operation or module that has no source position.
-}
unknown : Loc
unknown =
    { name = "unknown"
    , start = { row = 0, col = 0 }
    , end = { row = 0, col = 0 }
    }
        |> Loc
