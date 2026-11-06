module BytesIssue15BytesEqualityTest exposing (main)

{-| `==` on two `Bytes` values is always True.

<https://github.com/elm/bytes/issues/15>

Elm 0.19.1 (elm/bytes 1.0.8) compares the underlying DataViews structurally; they have no
enumerable fields, so an empty `Bytes` equals a 32-byte one. Values with different contents (and
different widths) must not be equal.

-}

-- CHECK: empty == two bytes: False
-- CHECK: [1] == [2]: False

import Bytes exposing (Bytes)
import Bytes.Encode as E
import Html exposing (text)


fromList : List Int -> Bytes
fromList xs =
    E.encode (E.sequence (List.map E.unsignedInt8 xs))


main =
    let
        _ =
            Debug.log "empty == two bytes" (fromList [] == fromList [ 125, 211 ])

        _ =
            Debug.log "[1] == [2]" (fromList [ 1 ] == fromList [ 2 ])
    in
    text "done"
