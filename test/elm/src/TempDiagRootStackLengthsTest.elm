module TempDiagRootStackLengthsTest exposing (main)

{-| TEMP(diag) (plans/ci-all-platforms-green.md issue 8): on macOS RootStackAppendLargeTest builds
`List.map pad (List.range 0 4299999)` 2,812,475 elements long. Log each step's length, and a count
that does not use List.length, to find the operation that loses elements. Remove with the fix.
-}

-- CHECK: range: 4300000
-- CHECK: rangeFold: 4300000
-- CHECK: reverse: 4300000
-- CHECK: mapInt: 4300000
-- CHECK: mapStr1M: 1000000
-- CHECK: mapStr2M: 2000000
-- CHECK: mapStr3M: 3000000
-- CHECK: mapStr: 4300000
-- CHECK: mapStrFold: 4300000

import Html exposing (text)


pad : Int -> String
pad n =
    String.padLeft 7 '0' (String.fromInt n)


count : List a -> Int
count =
    List.foldl (\_ n -> n + 1) 0


main =
    let
        r =
            List.range 0 4299999

        _ =
            Debug.log "range" (List.length r)

        _ =
            Debug.log "rangeFold" (count r)

        _ =
            Debug.log "reverse" (List.length (List.reverse r))

        _ =
            Debug.log "mapInt" (List.length (List.map (\x -> x + 1) r))

        _ =
            Debug.log "mapStr1M" (List.length (List.map pad (List.range 0 999999)))

        _ =
            Debug.log "mapStr2M" (List.length (List.map pad (List.range 0 1999999)))

        _ =
            Debug.log "mapStr3M" (List.length (List.map pad (List.range 0 2999999)))

        s =
            List.map pad r

        _ =
            Debug.log "mapStr" (List.length s)

        _ =
            Debug.log "mapStrFold" (count s)
    in
    text "done"
