module BytesDecoderSelfRecursiveMinimalTest exposing (main)

{-| A top-level decoder value that refers to itself inside `Bytes.Decode.andThen` decodes a small tree correctly.

`tDecoder` takes no arguments; it reads a tag byte and, for tag `1`, uses
itself twice to read the two subtrees of a `TPair`. Tag `0` is `TLeaf`.

The input `1 0 0` decodes to `Just (TPair TLeaf TLeaf)`.

-}

-- CHECK: decoded: Just (TPair TLeaf TLeaf)

import Bytes.Decode as D
import Bytes.Encode as E
import Html exposing (text)


type T
    = TLeaf
    | TPair T T


tDecoder : D.Decoder T
tDecoder =
    D.unsignedInt8
        |> D.andThen
            (\b ->
                case b of
                    0 ->
                        D.succeed TLeaf

                    1 ->
                        D.map2 TPair tDecoder tDecoder

                    _ ->
                        D.fail
            )


main =
    let
        bytes =
            E.encode
                (E.sequence
                    [ E.unsignedInt8 1
                    , E.unsignedInt8 0
                    , E.unsignedInt8 0
                    ]
                )

        result =
            D.decode tDecoder bytes

        _ =
            Debug.log "decoded" result
    in
    text "done"
