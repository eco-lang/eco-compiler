module DebugToStringAsValueTest exposing (main)

{-| `Debug.toString` passed as a function value to `List.map` works on lists of
`Float`s, of number literals and of `String`s in the same program.

The number literals `[ 1, 2 ]` have the type `number`, which defaults to `Int`,
and print as `"1"` and `"2"`. `Debug.toString` of a `String` includes its quotes, which appear escaped when
the list of results is logged.

-}

-- CHECK: floats: ["1.5","2.5"]
-- CHECK: ints: ["1","2"]
-- CHECK: strings: ["\"a\"","\"b\""]

import Html exposing (text)


main =
    let
        _ =
            Debug.log "floats" (List.map Debug.toString [ 1.5, 2.5 ])

        _ =
            Debug.log "ints" (List.map Debug.toString [ 1, 2 ])

        _ =
            Debug.log "strings" (List.map Debug.toString [ "a", "b" ])
    in
    text "done"
