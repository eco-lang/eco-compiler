module CrossSpecSretMixedRecordTest exposing (main)

{-| Wrapper-fca-fix Chunk 5 end-to-end fixture: a helper returns a
2-tuple `(Int, String)` whose elements mix a primitive (Int → i64) and
a boxed `!eco.value` (String). Pre-fix the all-primitive gate on
`eco.return` would have demoted this to the Boxed ABI; after lifting
the gate, cross-spec routes the result through Sret and the wrapper
re-boxes via a single `eco.construct.tuple2` op.

The optimised binary must produce the same observable behaviour as the
pre-promotion heap path — i.e., the tuple's fields are preserved
across the worker/wrapper boundary.

-}

-- CHECK: index: 11
-- CHECK: label: "hello"


import Html exposing (text)


labelled : Int -> String -> ( Int, String )
labelled n s =
    ( n, s )


main =
    let
        ( i, lbl ) =
            labelled 11 "hello"

        _ =
            Debug.log "index" i

        _ =
            Debug.log "label" lbl
    in
    text "done"
