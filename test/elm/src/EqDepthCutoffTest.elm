module EqDepthCutoffTest exposing (main)

{-| kernel-opt-03 Phase 1 (precondition B): pin `==`'s depth cutoff.

`eqHelp` returns `true` once nesting depth exceeds 100
(elm-kernel-cpp/src/core/Utils.cpp:560-563) while `cmp` has no such limit, so
`a == b` and `compare a b == EQ` can disagree on deeply nested values. That is a
pre-existing kernel divergence, recorded in kernel-opt-07's KernelFacts row for
`(Utils, equal)`. `eco.value.eq` INHERITS it — arm 3 calls the same kernel — so
this golden exists to prove the op does not MOVE the boundary. Run it before the
op work and again after; the answers must not change.

Depth increments ONLY through the boxed-slot recursion, so each `Wrap` costs one
level while `Leaf Int` is an unboxed Int field compared in place (Int/Float/Char
are the only unboxed heap fields). `nest N` therefore bottoms out at depth N, and
the flip sits between N=100 and N=101. 90 and 120 are deliberately clear of the
boundary so the test cannot flake on a one-level accounting difference: if a
future layout change boxes the `Leaf Int` field every depth shifts by one, and
both assertions still hold.

`longList` pins the other half of the contract — `Tag_Cons` walks the spine
ITERATIVELY at a single depth, so a 5000-element list must still compare
correctly and must NOT trip the cutoff.

-}

-- CHECK: shallow: False
-- CHECK: belowLimit: False
-- CHECK: aboveLimit: True
-- CHECK: longList: False
-- CHECK: longListEq: True

import Html exposing (text)


type Nest
    = Leaf Int
    | Wrap Nest


nest : Int -> Int -> Nest
nest n leaf =
    if n <= 0 then
        Leaf leaf

    else
        Wrap (nest (n - 1) leaf)


main : Html.Html msg
main =
    let
        _ =
            Debug.log "shallow" (nest 3 1 == nest 3 2)

        _ =
            Debug.log "belowLimit" (nest 90 1 == nest 90 2)

        -- Above the cutoff the kernel answers True even though the values
        -- differ. This is the divergence being pinned, not a bug to fix here.
        _ =
            Debug.log "aboveLimit" (nest 120 1 == nest 120 2)

        _ =
            Debug.log "longList" (List.range 1 5000 == List.range 1 4999)

        _ =
            Debug.log "longListEq" (List.range 1 5000 == List.range 1 5000)
    in
    text "done"
