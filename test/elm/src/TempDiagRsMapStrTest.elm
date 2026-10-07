module TempDiagRsMapStrTest exposing (main)

{-| TEMP(diag) (plans/ci-all-platforms-green.md issue 8): one step of RootStackAppendLargeTest's
list construction per test process, so a macOS crash in one step cannot hide the others. List.map pad over 4.3M Ints. Remove
with the fix.
-}

-- CHECK: mapStrFold: 4300000
-- CHECK: mapStr: 4300000

import Html exposing (text)


pad : Int -> String
pad n =
    String.padLeft 7 '0' (String.fromInt n)


count : List a -> Int
count =
    List.foldl (\_ n -> n + 1) 0


main =
    let
        s =
            List.map pad (List.range 0 4299999)

        _ =
            Debug.log "mapStrFold" (count s)

        _ =
            Debug.log "mapStr" (List.length s)
    in
    text "done"
