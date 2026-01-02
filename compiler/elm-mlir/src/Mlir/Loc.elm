module Mlir.Loc exposing (Loc(..), Pos, combine, unknown)

{-| Source code locations with file name and start and end positions defined as column and row
within the file.

@docs Loc, Pos, combine, unknown

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


{-| Combines two locations into one larger location that runs from the earliest start point to latest
end point of the two locations.

It is assumed that the two locations refer to the same named file, the actual file name returned will be
`a.name`.

-}
combine : Loc -> Loc -> Loc
combine (Loc a) (Loc b) =
    let
        before p1 p2 =
            (p1.row < p2.row)
                || (p1.row == p2.row && p1.col < p2.col)

        start =
            if before a.start b.start then
                a.start

            else
                b.start

        end =
            if before a.end b.end then
                b.end

            else
                a.end
    in
    Loc
        { name = a.name
        , start = start
        , end = end
        }
