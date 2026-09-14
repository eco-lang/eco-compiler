module PapCopyStampTest exposing (main)

{-| Emission pin for the `CallDirectKnownSegmentation` stamp gap
(`plans/pre-mono-lss-transforms-04-alias-forwarding.md` §7.1).

`Expr.generateCall` consulted the AbiCloning stamp (`fastDispatchStamp`) only
on the `CallGenericApply` / `CallSegmentationUnknown` arms. A closure-valued
call that `annotateExprCalls` classifies `CallDirectKnownSegmentation` — the
callee's construction is visible in the same function, e.g. a captured PAP
after the post-mono inliner copied `List.map`'s lambda into its caller, or a
global passed as a callback — took the typed saturated helper
(`eco_closure_call_saturated`) and silently dropped its `PsStampPap` /
`Stamp`. On the self-compile that was 21 M dispatches per compile falling
from `fast` to `typed` (call-stats Runs 11/12).

The shape, in the DEFAULT arm (no forwarding needed): inside the recursive
`enc`, a PAP of itself is let-bound (`f = enc tbl`, built in this very
function) and CAPTURED by the `foldr` lambda, whose `f x` is then a
known-segmentation closure-valued call carrying the LSS\_040 `p|enc|1` stamp.
Written with an explicit lambda rather than `List.map (enc tbl) ts` because
`List.map` is only inlined (and its lambda only copied into `enc`) once alias
forwarding makes it cheap — the explicit lambda pins the emission gap with
the flag off. `total`'s `List.map total es` is a bare-global callback and is
NOT pinned: its callee is a `MonoVarGlobal`, which the saturated path calls
directly, and the fix deliberately leaves that path alone (the first cut of
the fix diverted 4,691 such direct calls per self-compile into fast PAPs).

The CHECK-MLIR line pins the `_fast_evaluator` symbol on the emitted call —
with the gap open the only `enc`-targeted fast evaluator in this program is
absent; the CHECK line pins the value so a wrong bound-argument load cannot
pass.

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
