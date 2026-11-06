module CharCaptureEscapedTailDefTest exposing (main)

{-| A tail-recursive local function that refers to a `Char` argument of its
enclosing function still works when it is returned inside a list and called
later.

`pickers c` defines `go`, which reports whether a `List Char` contains `c`, and
returns `[ go ]`. The test applies the first function from that list to a list
containing `'x'`, the same function built for `'q'` to the same list, and every
function built for `'z'` to `[ 'z' ]`.

-}

import Html exposing (text)

-- CHECK: hit: True
-- CHECK: miss: False
-- CHECK: both: True


pickers : Char -> List (List Char -> Bool)
pickers c =
    let
        go xs =
            case xs of
                [] ->
                    False

                y :: rest ->
                    if y == c then
                        True

                    else
                        go rest
    in
    [ go ]


runFirst : List (List Char -> Bool) -> List Char -> Bool
runFirst fs xs =
    case fs of
        f :: _ ->
            f xs

        [] ->
            False


main =
    let
        _ =
            Debug.log "hit" (runFirst (pickers 'x') [ 'a', 'b', 'x' ])

        _ =
            Debug.log "miss" (runFirst (pickers 'q') [ 'a', 'b', 'x' ])

        _ =
            Debug.log "both" (List.all (\f -> f [ 'z' ]) (pickers 'z'))
    in
    text "done"
