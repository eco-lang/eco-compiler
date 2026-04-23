module BytesDecoderMixedValueFunctionCycleTest exposing (main)

{-| Mutually recursive Bytes.Decode cycle mixing a top-level VALUE decoder
    with a top-level FUNCTION decoder that takes an `Int` argument.

    `treeDecoder` (zero-arg value) references `branchBy` (one-arg function),
    and `branchBy` references `treeDecoder` back. Together they form a single
    recursive group that, in TypedOptimized form, becomes a `TOpt.Cycle` with
    both `valueDefs` AND `funcDefs` populated.

    Monomorphization routes such a Cycle to `specializeFunctionCycle`, which
    only processes `funcDefs` — the value gets a MonoExtern stub that the
    MLIR codegen lowers to `eco.constant kind=Unit`. When the runtime tries
    to pattern-match on the stub "Parser", it dereferences the embedded Unit
    constant and trips the `eco_resolve_hptr` assertion.

    This test exercises exactly that shape and is expected to decode
    `Branch (Leaf 7) (Leaf 9)` without crashing.
-}

-- CHECK: decoded: Just (Branch (Leaf 7) (Leaf 9))

import Bytes.Decode as D
import Bytes.Encode as E
import Html exposing (text)


type Tree
    = Leaf Int
    | Branch Tree Tree


{-| Top-level VALUE decoder (zero arguments).

Placed in the recursive group alongside `branchBy`.

-}
treeDecoder : D.Decoder Tree
treeDecoder =
    D.unsignedInt8
        |> D.andThen
            (\tag ->
                case tag of
                    0 ->
                        D.map Leaf D.unsignedInt8

                    n ->
                        branchBy n
            )


{-| Top-level FUNCTION decoder (takes an `Int` argument).

Mutually recursive with `treeDecoder`. The non-zero parameter means
the Elm compiler classifies this as a function, forcing the SCC
containing `treeDecoder` to be specialized via the function path.

-}
branchBy : Int -> D.Decoder Tree
branchBy n =
    if n == 1 then
        D.map2 Branch treeDecoder treeDecoder

    else
        D.fail


main =
    let
        bytes =
            E.encode
                (E.sequence
                    [ E.unsignedInt8 1
                    , E.unsignedInt8 0
                    , E.unsignedInt8 7
                    , E.unsignedInt8 0
                    , E.unsignedInt8 9
                    ]
                )

        result =
            D.decode treeDecoder bytes

        _ =
            Debug.log "decoded" result
    in
    text "done"
