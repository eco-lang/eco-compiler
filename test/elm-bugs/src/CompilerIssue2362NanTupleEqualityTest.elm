module CompilerIssue2362NanTupleEqualityTest exposing (main)

{-| A tuple holding NaN is not equal to anything, including itself.

<https://github.com/elm/compiler/issues/2362>

NaN is not equal to itself, so `p == q`, two separately built `( NaN, 1 )` tuples, and `p == p`,
one tuple compared with itself, must both be False. Elm 0.19.1 returns False for `p == q` but True
for `p == p`, because its equality first checks whether both sides are the same JavaScript object.

-}

-- CHECK: nan == nan: False
-- CHECK: p == q: False
-- CHECK: p == p: False

import Html exposing (text)


main =
    let
        nan =
            0 / 0

        p =
            ( nan, 1 )

        q =
            ( 0 / 0, 1 )

        _ =
            Debug.log "nan == nan" (nan == nan)

        _ =
            Debug.log "p == q" (p == q)

        _ =
            Debug.log "p == p" (p == p)
    in
    text "done"
