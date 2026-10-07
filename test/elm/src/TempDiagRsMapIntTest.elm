module TempDiagRsMapIntTest exposing (main)

{-| TEMP(diag) (plans/ci-all-platforms-green.md issue 8): one step of RootStackAppendLargeTest's
list construction per test process, so a macOS crash in one step cannot hide the others. List.map over 4.3M Ints. Remove
with the fix.
-}

-- CHECK: mapInt: 4300000

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
            Debug.log "mapInt" (count (List.map (\x -> x + 1) (List.range 0 4299999)))
    in
    text "done"
