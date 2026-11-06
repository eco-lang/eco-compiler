module ConformanceHelp exposing (charCps, cps, hashString, logAll, mix, worker)

{-| Shared helpers for the conformance tests, which log values that must print identically
under every Elm compiler.

A conformance test computes its results at start-up, logs each one as a labelled `String`, and
exits. The helpers keep that output plain ASCII: a character is shown by its code points in
upper-case hexadecimal rather than as itself, so a logged value never contains a character whose
printed form could differ between compilers.

`logAll` and `worker` run and print the results. `cps` and `charCps` turn text into code points.
`mix` and `hashString` reduce a large amount of output to one number that stays exact under
every compiler.

-}


{-| Logs each `( label, value )` pair with `Debug.log`, first to last, and returns `()`.

Each pair prints as `label: "value"`, since `value` is a `String`. Nothing here checks that
labels are distinct; a test whose CHECK lines are matched by label needs them to be.

-}
logAll : List ( String, String ) -> ()
logAll entries =
    List.foldl
        (\( label, value ) () ->
            let
                _ =
                    Debug.log label value
            in
            ()
        )
        ()
        entries


{-| Creates a headless program whose model is `report`.

The argument is the result of the test's logging, so the logging has already happened by the
time the program starts. The program sends no commands and subscribes to nothing.

-}
worker : () -> Program () () ()
worker report =
    Platform.worker
        { init = \_ -> ( report, Cmd.none )
        , update = \_ model -> ( model, Cmd.none )
        , subscriptions = \_ -> Sub.none
        }


{-| Returns the code points of `s` in upper-case hexadecimal, without leading zeros, separated
by single spaces: `cps "SS" == "53 53"`. The empty string gives `""`.
-}
cps : String -> String
cps s =
    String.toList s
        |> List.map (\c -> hex (Char.toCode c))
        |> String.join " "


{-| Returns `cps` of the one-character string made from `c`.

Under some compilers a case mapping such as `Char.toUpper` can return a `Char` that holds more
than one code point, which is why the result can contain several.

-}
charCps : Char -> String
charCps c =
    cps (String.fromChar c)


{-| Returns a non-negative `n` in upper-case hexadecimal, without leading zeros.
-}
hex : Int -> String
hex n =
    let
        digit d =
            String.slice d (d + 1) "0123456789ABCDEF"

        go k acc =
            if k < 16 then
                digit k ++ acc

            else
                go (k // 16) (digit (modBy 16 k) ++ acc)
    in
    go n ""


{-| Returns `h` combined with `v`, one step of a simple hash.

For `h` below 2^31 and a small non-negative `v`, the intermediate value stays below 2^36 and the
result below 2^31, so the arithmetic is exact whether `Int` is a 64-bit integer or a JavaScript
number. It avoids `Bitwise` and `//`, whose results on large values depend on the integer width
a compiler uses.

-}
mix : Int -> Int -> Int
mix h v =
    modBy 2147483629 (h * 31 + v + 1)


{-| Returns `h` with the code point of every character of `s`, in order, and then
`String.length s`, folded in by `mix`.
-}
hashString : Int -> String -> Int
hashString h s =
    mix (String.foldl (\c acc -> mix acc (Char.toCode c)) h s) (String.length s)
