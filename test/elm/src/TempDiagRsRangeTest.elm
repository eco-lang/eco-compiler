module TempDiagRsRangeTest exposing (main)

{-| TEMP(diag) (plans/ci-all-platforms-green.md issue 8): one step of RootStackAppendLargeTest's
list construction per test process, so a macOS crash in one step cannot hide the others. List.range and two ways to count it. Remove
with the fix.
-}

-- CHECK: rangeFold: 4300000
-- CHECK: range: 4300000

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
            Debug.log "rangeFold" (count r)

        _ =
            Debug.log "range" (List.length r)
    in
    text "done"
