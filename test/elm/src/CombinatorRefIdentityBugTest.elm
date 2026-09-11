module CombinatorRefIdentityBugTest exposing (main)

{-| Regression pin for `/work/combinator-uf-devirt-error.md`.

`b` is the B combinator written at FULL arity. Two specializations of `s`
share the erased ABI `(value, value, i64) -> i64` but receive different
callbacks in `uf` (`inc` here, `double` from `s_feed`). The post-mono inliner
beta-reduces `b`'s body to a saturated `s (k f) g y`, and the live chain is
then wired to the `double` specialization: `b square inc 4` prints
`square (double 4) = 64` instead of `square (inc 4) = 25`.

Both definitions are load-bearing — drop `s_feed` and the answer is right.
`CombinatorTest.elm` is the point-free spelling of the same program; it stays
boxed and never reaches the unboxed specialization, which is why it passes.

-}

import Html exposing (text)



-- CHECK: b_compose: 25
-- CHECK: s_feed: 15


k a _ =
    a


s bf uf x =
    bf x (uf x)


b f g y =
    s (k s) k f g y


inc x =
    x + 1


double x =
    x * 2


square x =
    x * x


main =
    let
        _ =
            Debug.log "b_compose" (b square inc 4)

        _ =
            Debug.log "s_feed" (s (+) double 5)
    in
    text "done"
