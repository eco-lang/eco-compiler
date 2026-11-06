module EqDepthCutoffTest exposing (main)

{-| `==` compares deeply nested values exactly, however deep the difference
lies, and compares long lists correctly.

`nest n leaf` builds `n` `Wrap` constructors around `Leaf leaf`, so two values
built with different leaves differ only at the bottom. The test compares such
pairs nested 3, 90 and 120 levels deep, and each comparison must be `False`. The
nesting depths are chosen to lie on either side of 100, because elm/core's
JavaScript equality recurses only about 100 levels before deferring the rest of
a comparison, and the answer must not change at that point.

It also compares `List.range 1 5000` with `List.range 1 4999`, which must be
`False`, and with itself rebuilt, which must be `True`.

## eco

Exercises `eqHelp` in elm-kernel-cpp/src/core/Utils.cpp, fixed under plans/kernel-lib-bug-fixes.md (UTILS-05). It recurses at most 100 boxed levels and, like elm/core's JS `_Utils_eqHelp`, sets aside any pair met deeper; `equal` then compares each set-aside pair from depth 0, so `a == b` and `compare a b == EQ` agree on deep values. Before the fix it returned `True` past depth 100 without looking. The `eco.value.eq` op calls the same kernel, so this test covers it too.

Depth only grows through boxed fields: each `Wrap` costs one level, while `Leaf Int` holds an unboxed `Int` compared in place (only Int, Float and Char are unboxed in heap fields). So `nest N` bottoms out at depth N, and 90 and 120 sit clearly on either side of the bound. The long lists check that `Tag_Cons` walks the spine iteratively at one depth.

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

        -- Deeper than 100 levels: the difference must still be found.
        _ =
            Debug.log "aboveLimit" (nest 120 1 == nest 120 2)

        _ =
            Debug.log "longList" (List.range 1 5000 == List.range 1 4999)

        _ =
            Debug.log "longListEq" (List.range 1 5000 == List.range 1 5000)
    in
    text "done"
