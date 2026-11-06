module RecordNestedAccessTest exposing (main)

{-| Chained field access reads through nested record literals two and three levels deep.

`r.nested.value` gives 42 and `s.a.b.c` gives 99.
-}

-- CHECK: deep: 42
-- CHECK: chain: 99

import Html exposing (text)


main =
    let
        r =
            { nested = { value = 42 } }

        s =
            { a = { b = { c = 99 } } }

        _ =
            Debug.log "deep" r.nested.value

        _ =
            Debug.log "chain" s.a.b.c
    in
    text "done"
