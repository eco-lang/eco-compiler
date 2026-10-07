module TempDiagRsMapStrSmallTest exposing (main)

{-| TEMP(diag) (plans/ci-all-platforms-green.md issue 8): one step of RootStackAppendLargeTest's
list construction per test process, so a macOS crash in one step cannot hide the others. List.map pad over 1M, 2M and 3M Ints. Remove
with the fix.
-}

-- CHECK: mapStr1M: 1000000
-- CHECK: mapStr2M: 2000000
-- CHECK: mapStr3M: 3000000

import Html exposing (text)


pad : Int -> String
pad n =
    String.padLeft 7 '0' (String.fromInt n)


count : List a -> Int
count =
    List.foldl (\_ n -> n + 1) 0


main =
    let
        _ =
            Debug.log "mapStr1M" (count (List.map pad (List.range 0 999999)))

        _ =
            Debug.log "mapStr2M" (count (List.map pad (List.range 0 1999999)))

        _ =
            Debug.log "mapStr3M" (count (List.map pad (List.range 0 2999999)))
    in
    text "done"
