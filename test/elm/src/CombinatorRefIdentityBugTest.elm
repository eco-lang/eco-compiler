module CombinatorRefIdentityBugTest exposing (main)

{-| A B combinator defined with all its arguments, `b f g y = s (k s) k f g y`, used in the same program as a separate application of `s` to a different function: `b square inc 4` must still be `square (inc 4)`, which is 25.

`s` is applied to an `Int -> Int` function as its second argument in two
places: inside `b`, where that function is `inc`, and directly as `s (+) double 5`,
which is `5 + double 5`, 15. A compiler that mixes up the two calls of `s` would
print `square (double 4)`, 64, for the first.

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
