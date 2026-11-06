module BytesDecoderMixedValueFunctionCycleTest exposing (main)

{-| A top-level decoder value and a top-level decoder function that take turns recursing into each other decode a tagged tree correctly.

`treeDecoder` takes no arguments and calls `branchBy`, a function of an `Int`;
`branchBy` uses `treeDecoder` for both subtrees of a `Branch`.

The encoding is `0 x` for `Leaf x` and `1 left right` for `Branch left right`.
The input `1 0 7 0 9` decodes to `Just (Branch (Leaf 7) (Leaf 9))`.

## eco

In typed-optimized form `treeDecoder` and `branchBy` form one `TOpt.Cycle`
with both value and function definitions. Monomorphization used to route it
to `specializeFunctionCycle`
(compiler/src/Compiler/Monomorphize/Subst/Specialize.elm), which handled only
the function definitions; the value got a stub that MLIR codegen lowered to a
Unit constant, and matching on it tripped the `eco_resolve_hptr` assertion
(runtime/src/allocator/RuntimeExports.h). Fixed by
plans/fix-mixed-value-function-cycle-specialization.md; the `Int` argument on
`branchBy` is what makes the group a function cycle.

-}

-- CHECK: decoded: Just (Branch (Leaf 7) (Leaf 9))

import Bytes.Decode as D
import Bytes.Encode as E
import Html exposing (text)


type Tree
    = Leaf Int
    | Branch Tree Tree


{-| A decoder that reads a tag byte: `0` is followed by a leaf value, and any
other tag is handed to `branchBy`.
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


{-| Produces a decoder for two subtrees combined into a `Branch` when `n` is 1,
and a failing decoder otherwise.
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
