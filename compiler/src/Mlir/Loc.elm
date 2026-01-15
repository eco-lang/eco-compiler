module Mlir.Loc exposing (Loc(..), Pos, unknown)

{-| Source code locations with file name and start and end positions defined as column and row
within the file.

@docs Loc, Pos, unknown

-}


{-| A source code location within a named file with start and end positions defined as column and row.
-}
type Loc
    = Loc
        { name : String
        , start : Pos
        , end : Pos
        }


{-| A column and row position.
-}
type alias Pos =
    { row : Int
    , col : Int
    }


{-| The default unknown location, which is file "unknown" at (0, 0) to (0, 0)
-}
unknown : Loc
unknown =
    { name = "unknown"
    , start = { row = 0, col = 0 }
    , end = { row = 0, col = 0 }
    }
        |> Loc
