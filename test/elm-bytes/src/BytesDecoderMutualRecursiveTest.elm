module BytesDecoderMutualRecursiveTest exposing (main)

{-| A self-recursive top-level decoder that also delegates to a second top-level decoder decodes a small expression tree correctly.

`exprDecoder` refers to itself for both operands of `Add`, and to `atomDecoder`
for a literal. `atomDecoder` does not refer back, so despite the module name the
two decoders are not mutually recursive.

The encoding is `0 n` for `Lit n` and `1 left right` for `Add left right`. The
input `1 0 10 0 20` decodes to `Just (Add (Lit 10) (Lit 20))`.

-}

-- CHECK: decoded: Just (Add (Lit 10) (Lit 20))

import Bytes.Decode as D
import Bytes.Encode as E
import Html exposing (text)


type Expr
    = Lit Int
    | Add Expr Expr


exprDecoder : D.Decoder Expr
exprDecoder =
    D.unsignedInt8
        |> D.andThen
            (\tag ->
                case tag of
                    0 ->
                        atomDecoder

                    1 ->
                        D.map2 Add exprDecoder exprDecoder

                    _ ->
                        D.fail
            )


atomDecoder : D.Decoder Expr
atomDecoder =
    D.unsignedInt8
        |> D.map Lit


main =
    let
        bytes =
            E.encode
                (E.sequence
                    [ E.unsignedInt8 1
                    , E.unsignedInt8 0
                    , E.unsignedInt8 10
                    , E.unsignedInt8 0
                    , E.unsignedInt8 20
                    ]
                )

        result =
            D.decode exprDecoder bytes

        _ =
            Debug.log "decoded" result
    in
    text "done"
