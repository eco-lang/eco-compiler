module RecordNestedAccessTest exposing (main)

{-| Test nested record chained access. -}

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
