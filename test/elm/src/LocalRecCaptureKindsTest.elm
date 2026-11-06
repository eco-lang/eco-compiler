module LocalRecCaptureKindsTest exposing (main)

{-| A let-bound recursive function that uses an Int, a Float, a Char, a Bool and a
String from its enclosing scope gives the same result whether it is called
directly or passed to `List.map`.

`run` calls the local `go` directly; `runHof` defines the same `go` and maps it
over `[ 0, 2 ]`. With k = 2, f = 0.5, c = 'b', flag = True and s = "xy", `go`
steps i by 2 until `i >= 4` and returns
4 + round (0.5 * 10) + Char.toCode 'b' + 1 + String.length "xy" = 4 + 5 + 98 + 1 + 2 = 110.
Starting from 2 also stops at 4, so the mapped list is `[110,110]`.
-}

-- CHECK: direct: 110
-- CHECK: via_hof: [110,110]

import Html exposing (text)


run : Int -> Float -> Char -> String -> Int -> Int
run k f c s start =
    let
        flag =
            k > 1

        go i =
            if i >= 4 then
                i
                    + round (f * 10)
                    + Char.toCode c
                    + (if flag then
                        1

                       else
                        0
                      )
                    + String.length s

            else
                go (i + k)
    in
    go start


runHof : Int -> Float -> Char -> String -> List Int
runHof k f c s =
    let
        flag =
            k > 1

        go i =
            if i >= 4 then
                i
                    + round (f * 10)
                    + Char.toCode c
                    + (if flag then
                        1

                       else
                        0
                      )
                    + String.length s

            else
                go (i + k)
    in
    List.map go [ 0, 2 ]


main =
    let
        _ =
            Debug.log "direct" (run 2 0.5 'b' "xy" 0)

        _ =
            Debug.log "via_hof" (runHof 2 0.5 'b' "xy")
    in
    text "done"
