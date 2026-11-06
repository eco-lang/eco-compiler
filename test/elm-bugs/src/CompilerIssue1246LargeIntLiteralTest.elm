module CompilerIssue1246LargeIntLiteralTest exposing (main)

{-| Int literals that do not fit 64 bits are silently wrapped.

<https://github.com/elm/compiler/issues/1246>

Elm 0.19.1 reads integer literals into a 64-bit Int, so `100000000000000000000` becomes
7766279631452242000 and 2^63 becomes -2^63, with no error. The literal should keep its value
(as a JavaScript number); silently changing it is wrong.

-}

-- CHECK: big: 100000000000000000000
-- CHECK: sixtyThree: 9223372036854776000

import Html exposing (text)


big : Int
big =
    100000000000000000000


sixtyThree : Int
sixtyThree =
    9223372036854775808


main =
    let
        _ =
            Debug.log "big" big

        _ =
            Debug.log "sixtyThree" sixtyThree
    in
    text "done"
