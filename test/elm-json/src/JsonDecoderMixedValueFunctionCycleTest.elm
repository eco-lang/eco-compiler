module JsonDecoderMixedValueFunctionCycleTest exposing (main)

{-| Mirror of `BytesDecoderMixedValueFunctionCycleTest` but via
    `Json.Decode`. The JSON decoder pipeline runs through the same
    monomorphization path, so the mixed value/function cycle should
    miscompile the top-level value exactly the same way.

    Note: `Json.Decode.lazy` is deliberately NOT used — the value
    `treeDecoder` references `branchBy` directly. Using `lazy` would
    introduce a closure that breaks the SCC shape, hiding the bug.
-}

-- CHECK: decoded: Ok (Branch (Leaf 7) (Leaf 9))

import Html exposing (text)
import Json.Decode as D


type Tree
    = Leaf Int
    | Branch Tree Tree


treeDecoder : D.Decoder Tree
treeDecoder =
    D.field "tag" D.int
        |> D.andThen
            (\tag ->
                case tag of
                    0 ->
                        D.map Leaf (D.field "value" D.int)

                    n ->
                        branchBy n
            )


branchBy : Int -> D.Decoder Tree
branchBy n =
    if n == 1 then
        D.map2 Branch
            (D.field "left" treeDecoder)
            (D.field "right" treeDecoder)

    else
        D.fail "bad tag"


main =
    let
        json =
            """{"tag":1,"left":{"tag":0,"value":7},"right":{"tag":0,"value":9}}"""

        result =
            D.decodeString treeDecoder json

        _ =
            Debug.log "decoded" result
    in
    text "done"
