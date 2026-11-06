module PolyLetConstTest exposing (main)

{-| A let-bound polymorphic `const` is used at two different type combinations in
the same scope, and each use returns its first argument.

`const 1 "hi"` logs 1 and `const "hi" 1` logs `"hi"`.

-}

-- CHECK: r1: 1
-- CHECK: r2: "hi"

import Html exposing (text)


main =
    let
        const a b = a

        r1 = const 1 "hi"
        r2 = const "hi" 1
        _ = Debug.log "r1" r1
        _ = Debug.log "r2" r2
    in
    text "done"
