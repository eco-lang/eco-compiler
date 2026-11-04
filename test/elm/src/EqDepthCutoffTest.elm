module EqDepthCutoffTest exposing (main)

{-| kernel-opt-03 Phase 1 (precondition B), updated by UTILS-05 of
plans/kernel-lib-bug-fixes.md: `==` is exact on both sides of its depth bound.

`eqHelp` (elm-kernel-cpp/src/core/Utils.cpp) recurses at most 100 boxed levels and,
as elm/core's JS `_Utils_eqHelp` does, sets aside a pair it meets deeper than that;
`equal` then compares each set-aside pair from depth 0. So `a == b` and
`compare a b == EQ` agree on deeply nested values. (Before UTILS-05 it returned
`true` past depth 100 unexamined, and `aboveLimit` printed True.) `eco.value.eq`
arm 3 calls the same kernel, so this golden also covers the op.

Depth increments ONLY through the boxed-slot recursion, so each `Wrap` costs one
level while `Leaf Int` is an unboxed Int field compared in place (Int/Float/Char
are the only unboxed heap fields). `nest N` therefore bottoms out at depth N, and
the bound sits between N=100 and N=101. 90 and 120 are deliberately clear of the
boundary, so the test cannot depend on a one-level accounting difference.

`longList` pins the other half of the contract — `Tag_Cons` walks the spine
ITERATIVELY at a single depth, so a 5000-element list must still compare
correctly.

-}

-- CHECK: shallow: False
-- CHECK: belowLimit: False
-- CHECK: aboveLimit: False
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

        -- Past the depth bound: the pair is deferred and still compared.
        _ =
            Debug.log "aboveLimit" (nest 120 1 == nest 120 2)

        _ =
            Debug.log "longList" (List.range 1 5000 == List.range 1 4999)

        _ =
            Debug.log "longListEq" (List.range 1 5000 == List.range 1 5000)
    in
    text "done"
