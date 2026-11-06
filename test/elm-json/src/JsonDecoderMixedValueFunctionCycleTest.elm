module JsonDecoderMixedValueFunctionCycleTest exposing (main)

{-| A recursive `Json.Decode` decoder whose cycle runs through a top-level value and a top-level function decodes a nested tree correctly.

`treeDecoder` is a value (it takes no arguments) and `branchBy` is a function, and each
refers to the other without `Json.Decode.lazy`. The reference from `treeDecoder` to `branchBy`
sits inside the `andThen` callback. The input is a branch (tag 1) holding two leaves (tag 0) with values 7 and 9.
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
