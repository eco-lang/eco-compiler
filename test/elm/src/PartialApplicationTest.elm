module PartialApplicationTest exposing (main)

{-| Test partial application (currying).
-}

-- CHECK: partial1: 7
-- CHECK: partial2: 15
-- CHECK: partial3: [2,3,4]

import Html exposing (text)


add a b = a + b
multiply a b = a * b


main =
    let
        add5 = add 5
        triple = multiply 3
        addOne = add 1
        _ = Debug.log "partial1" (add5 2)
        _ = Debug.log "partial2" (triple 5)
        _ = Debug.log "partial3" (List.map addOne [1, 2, 3])
    in
    text "done"
