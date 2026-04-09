module BytesDecoderMutualRecursiveTest exposing (main)

{-| Mutually recursive Bytes.Decode decoders.

    Two decoders `exprDecoder` and `atomDecoder` reference each other.
    Tests the mutual-recursion variant of the self-recursive decoder bug.

    Encoding: [0, 42] for Lit 42, [1, 0, 10, 0, 20] for Add (Lit 10) (Lit 20).

    Expected: prints "decoded: Just (Add (Lit 10) (Lit 20))" without crashing.
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
