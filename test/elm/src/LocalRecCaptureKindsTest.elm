module LocalRecCaptureKindsTest exposing (main)

{-| A local recursive function (MonoTailDef) capturing one value of each
capture representation: unboxed Int (i64), Float (f64) and Char (i16), boxed
Bool (REP_CLOSURE_001: i1 boxed to !eco.value at the closure boundary) and a
boxed String. The closure is also passed to a HOF so it is called through the
closure ABI, not only through the direct self-call loop.

go 0 with k=2, f=0.5, c='b', flag=True, s="xy":
  i = 0,2,4 -> stop at 4: 4 + round (0.5 * 10) + toCode 'b' (98) + 1 + 2 = 110

-}

-- CHECK: direct: 110
-- CHECK: via_hof: [110, 110]

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
