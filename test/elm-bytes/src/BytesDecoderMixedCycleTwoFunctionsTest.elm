module BytesDecoderMixedCycleTwoFunctionsTest exposing (main)

{-| Recursive cycle with one top-level VALUE decoder and two top-level
    FUNCTION decoders. Every arrow below points from a definition to one
    of its callees:

        listDecoder  -->  decideDispatch
        decideDispatch  -->  continueList
        continueList  -->  listDecoder

    All three are in the same SCC. Because `funcDefs` is non-empty,
    monomorphization routes the group through `specializeFunctionCycle`,
    which ignores `valueDefs` — so `listDecoder` becomes a Unit stub
    and the first use crashes in `eco_resolve_hptr`.

    Encoding: each element is preceded by tag `1` and the list is
    terminated by tag `0`.

-}

-- CHECK: decoded: Just [3, 5, 7]

import Bytes.Decode as D
import Bytes.Encode as E
import Html exposing (text)


{-| VALUE (zero-arg).  Reads a tag byte, then dispatches.
-}
listDecoder : D.Decoder (List Int)
listDecoder =
    D.unsignedInt8
        |> D.andThen decideDispatch


{-| FUNCTION.  Decides whether we are at end-of-list or need to continue.
-}
decideDispatch : Int -> D.Decoder (List Int)
decideDispatch flag =
    if flag == 0 then
        D.succeed []

    else
        continueList flag


{-| FUNCTION.  Reads one element, then recurses via `listDecoder`
— closing the cycle back to the value.
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
