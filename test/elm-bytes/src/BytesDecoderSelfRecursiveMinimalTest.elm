module BytesDecoderSelfRecursiveMinimalTest exposing (main)

{-| Minimal self-recursive Bytes.Decode.Decoder.

    Mirrors the structure of Compiler.AST.Canonical.typeDecoder: a zero-arity
    top-level binding whose RHS is `unsignedInt8 |> andThen (... decoder ...)`
    where one branch references the decoder itself.

    The encoded bytes are: [0, 1, 1] representing TPair TLeaf TLeaf.

    Expected: prints "decoded: Just (TPair TLeaf TLeaf)" without crashing.
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
