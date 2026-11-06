module PapCopyStampTest exposing (main)

{-| Tests a recursive function that partially applies itself, binds the
result in a `let`, and calls it from inside a lambda passed to `List.foldr`.

`enc tbl` encodes a tree of `Leaf` and `Node` values, adding `tbl.seed` to
every leaf; for a `Node` it binds `f = enc tbl` and maps the children through
a `foldr` lambda calling `f x`. `total` sums the encoded tree by passing
itself to `List.map`. With seed 3 and leaves 1 to 4 the sum is
4 + 5 + 6 + 7 = 22.

## eco

Pins emission of the fast-dispatch stamp on known-segmentation closure calls
(found during plans/pre-mono-lss-transforms-04-alias-forwarding.md).
`generateCall` in compiler/src/Compiler/GenerateMlir/Expr.elm once consulted
the stamp from compiler/src/Compiler/MonoOpt/AbiCloning.elm only for generic
and segmentation-unknown calls. A call classified
`CallDirectKnownSegmentation`, whose callee is built in the same function,
took the typed saturated helper and dropped the stamp, so those calls fell
from the fast to the typed dispatch path.

Here the PAP `f = enc tbl` is built inside `enc` and captured by the `foldr`
lambda, so `f x` is such a call carrying the `p|enc|1` stamp (LSS_040 in
design_docs/invariants.csv). An explicit lambda is used instead of
`List.map (enc tbl) ts` because `List.map` is only inlined into `enc` once
alias forwarding is on. `total`'s callback is a bare global, called directly,
and is deliberately not pinned. The CHECK-MLIR line asserts the call names an
`enc` fast evaluator; the CHECK line guards against a wrong bound-argument
load.

-}

import Html exposing (text)



-- CHECK: r: 22
-- CHECK-MLIR: _fast_evaluator = @PapCopyStampTest_enc_$_


type alias Tbl =
    { seed : Int, name : String, tag : Maybe Int }


type T
    = Leaf Int
    | Node (List T)


type Enc
    = Enc Int
    | Seq (List Enc)


enc : Tbl -> T -> Enc
enc tbl t =
    case t of
        Leaf n ->
            Enc (tbl.seed + n)

        Node ts ->
            let
                f =
                    enc tbl
            in
            Seq (List.foldr (\x acc -> f x :: acc) [] ts)


total : Enc -> Int
total e =
    case e of
        Enc n ->
            n

        Seq es ->
            List.sum (List.map total es)


main =
    let
        _ =
            Debug.log "r" (total (enc { seed = 3, name = "x", tag = Nothing } (Node [ Leaf 1, Node [ Leaf 2, Leaf 3 ], Leaf 4 ])))
    in
    text "done"
