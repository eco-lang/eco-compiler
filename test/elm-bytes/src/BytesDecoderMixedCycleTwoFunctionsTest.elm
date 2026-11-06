module BytesDecoderMixedCycleTwoFunctionsTest exposing (main)

{-| A recursive cycle of one top-level decoder value and two top-level decoder functions decodes a tagged list of bytes correctly.

Each definition refers to the next, and the last refers back to the first:
`listDecoder` (a value, taking no arguments) uses `decideDispatch`, which uses
`continueList`, which uses `listDecoder`.

In the encoding each element is preceded by the tag byte `1` and the list ends
with the tag byte `0`. The input `1 3 1 5 1 7 0` decodes to `Just [3,5,7]`.

-}

-- CHECK: decoded: Just [3,5,7]

import Bytes.Decode as D
import Bytes.Encode as E
import Html exposing (text)


{-| A decoder that reads a tag byte and hands it to `decideDispatch`.
-}
listDecoder : D.Decoder (List Int)
listDecoder =
    D.unsignedInt8
        |> D.andThen decideDispatch


{-| Produces an empty-list decoder for tag `0`, and otherwise `continueList`.
-}
decideDispatch : Int -> D.Decoder (List Int)
decideDispatch flag =
    if flag == 0 then
        D.succeed []

    else
        continueList flag


{-| Produces a decoder that reads one element byte and conses it onto the rest
of the list, read by `listDecoder`. The tag argument is ignored.
-}
continueList : Int -> D.Decoder (List Int)
continueList _ =
    D.unsignedInt8
        |> D.andThen
            (\v ->
                listDecoder
                    |> D.map (\rest -> v :: rest)
            )


main =
    let
        bytes =
            E.encode
                (E.sequence
                    [ E.unsignedInt8 1
                    , E.unsignedInt8 3
                    , E.unsignedInt8 1
                    , E.unsignedInt8 5
                    , E.unsignedInt8 1
                    , E.unsignedInt8 7
                    , E.unsignedInt8 0
                    ]
                )

        result =
            D.decode listDecoder bytes

        _ =
            Debug.log "decoded" result
    in
    text "done"
