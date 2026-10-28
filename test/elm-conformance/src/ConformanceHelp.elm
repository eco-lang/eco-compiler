module ConformanceHelp exposing (charCps, cps, hashString, logAll, mix, worker)

{-| Helpers for the Elm-vs-eco conformance tests (plans/char-case-mapping-elm-exact.md Step 0).

Every logged value is a `String` built by the test and kept ASCII: Chars are shown as their
code points in upper-case hex, so a CHECK line ends at a closing quote and reads the same on
both targets.

-}


{-| Logs each `(label, value)` in order, as `label: "value"`. Labels must be unique.
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


{-| A `Platform.worker` whose model is `report`: the test's logging runs at start-up and the
program then exits (no subscriptions).
-}
worker : () -> Program () () ()
worker report =
    Platform.worker
        { init = \_ -> ( report, Cmd.none )
        , update = \_ model -> ( model, Cmd.none )
        , subscriptions = \_ -> Sub.none
        }


{-| The code points of a String, as upper-case hex joined by spaces: `cps "SS" == "53 53"`.
-}
cps : String -> String
cps s =
    String.toList s
        |> List.map (\c -> hex (Char.toCode c))
        |> String.join " "


{-| `cps` of one Char's string, which has several code points for some case mappings.
-}
charCps : Char -> String
charCps c =
    cps (String.fromChar c)


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


{-| One step of a hash that is exact on both targets: the result stays below 2^31 and the
intermediate below 2^36, inside a JS double's exact range and eco's Int64. No `Bitwise`
(64-bit on eco) and no `//` on large values (32-bit in Elm JS).
-}
mix : Int -> Int -> Int
mix h v =
    modBy 2147483629 (h * 31 + v + 1)


{-| Mixes the code point of every Char of a String, then its UTF-16 length, into `h`.
-}
hashString : Int -> String -> Int
hashString h s =
    mix (String.foldl (\c acc -> mix acc (Char.toCode c)) h s) (String.length s)
