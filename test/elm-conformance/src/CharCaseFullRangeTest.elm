module CharCaseFullRangeTest exposing (main)

{-| The whole case-mapping table, as hashes. For every code point of every plane (surrogates
skipped) it mixes the Char mappings, their re-mappings, Char.toCode, Char.isUpper and the
one-Char String mappings into one hash per plane ("plane p"); String.toUpper/toLower of each
block of 0x100 code points into a second hash per plane ("strplane p"), which covers the
whole-string paths and Final_Sigma with real neighbours; and the sorted list of every
toUpper/toLower result below U+D800 plus its Set size ("sorted"). A mismatch says which plane
to look at. Expectations recorded from Elm (plans/char-case-mapping-elm-exact.md Step 0.6).
-}

-- CHECK: plane 0: "1592108178"
-- CHECK: strplane 0: "429400736"
-- CHECK: plane 1: "1952169291"
-- CHECK: strplane 1: "173977151"
-- CHECK: plane 2: "202726133"
-- CHECK: strplane 2: "2086547382"
-- CHECK: plane 3: "588604363"
-- CHECK: strplane 3: "1945575612"
-- CHECK: plane 4: "974482593"
-- CHECK: strplane 4: "1804603842"
-- CHECK: plane 5: "1360360823"
-- CHECK: strplane 5: "1663632072"
-- CHECK: plane 6: "1746239053"
-- CHECK: strplane 6: "1522660302"
-- CHECK: plane 7: "2132117283"
-- CHECK: strplane 7: "1381688532"
-- CHECK: plane 8: "370511884"
-- CHECK: strplane 8: "1240716762"
-- CHECK: plane 9: "756390114"
-- CHECK: strplane 9: "1099744992"
-- CHECK: plane 10: "1142268344"
-- CHECK: strplane 10: "958773222"
-- CHECK: plane 11: "1528146574"
-- CHECK: strplane 11: "817801452"
-- CHECK: plane 12: "1914024804"
-- CHECK: strplane 12: "676829682"
-- CHECK: plane 13: "152419405"
-- CHECK: strplane 13: "535857912"
-- CHECK: plane 14: "538297635"
-- CHECK: strplane 14: "394886142"
-- CHECK: plane 15: "924175865"
-- CHECK: strplane 15: "253914372"
-- CHECK: plane 16: "1310054095"
-- CHECK: strplane 16: "112942602"
-- CHECK: sorted: "554220795"

import ConformanceHelp exposing (charCps, hashString, logAll, mix, worker)
import Set


isSurrogate : Int -> Bool
isSurrogate cp =
    cp >= 0xD800 && cp <= 0xDFFF


{-| Mixes everything about one code point into `h`.
-}
mixCodePoint : Int -> Int -> Int
mixCodePoint cp h =
    let
        c =
            Char.fromCode cp

        u =
            Char.toUpper c

        l =
            Char.toLower c

        one =
            String.fromChar c
    in
    h
        |> (\a -> hashString a (String.fromChar u))
        |> (\a -> hashString a (String.fromChar l))
        |> (\a -> mix a (Char.toCode u))
        |> (\a -> mix a (Char.toCode l))
        |> (\a -> hashString a (String.fromChar (Char.toLower u)))
        |> (\a -> hashString a (String.fromChar (Char.toUpper l)))
        |> (\a -> hashString a (String.toUpper one))
        |> (\a -> hashString a (String.toLower one))
        |> (\a ->
                mix a
                    (if Char.isUpper u then
                        1

                     else
                        0
                    )
           )


{-| Folds `mixCodePoint` over code points `cp .. last`, skipping surrogates. Tail-recursive.
-}
charLoop : Int -> Int -> Int -> Int
charLoop cp last h =
    if cp > last then
        h

    else if isSurrogate cp then
        charLoop (cp + 1) last h

    else
        charLoop (cp + 1) last (mixCodePoint cp h)


{-| The String of code points `lo .. lo + 0xFF`, surrogates skipped.
-}
block : Int -> String
block lo =
    List.range lo (lo + 0xFF)
        |> List.filter (\cp -> not (isSurrogate cp))
        |> List.map Char.fromCode
        |> String.fromList


{-| Folds the String mappings of every 0x100-code-point block of `lo .. last`. Tail-recursive.
-}
blockLoop : Int -> Int -> Int -> Int
blockLoop lo last h =
    if lo > last then
        h

    else
        let
            s =
                block lo
        in
        blockLoop (lo + 0x0100) last (hashString (hashString h (String.toUpper s)) (String.toLower s))


planeEntries : Int -> List ( String, String )
planeEntries p =
    let
        lo =
            p * 0x00010000

        last =
            lo + 0xFFFF
    in
    [ ( "plane " ++ String.fromInt p, String.fromInt (charLoop lo last 7) )
    , ( "strplane " ++ String.fromInt p, String.fromInt (blockLoop lo last 11) )
    ]


sorted : String
sorted =
    let
        mapped =
            List.range 0 0xD7FF
                |> List.concatMap (\cp -> [ Char.toUpper (Char.fromCode cp), Char.toLower (Char.fromCode cp) ])

        h =
            List.foldl (\c acc -> hashString acc (charCps c)) 13 (List.sort mapped)
    in
    String.fromInt (mix h (Set.size (Set.fromList mapped)))


report : ()
report =
    logAll (List.concatMap planeEntries (List.range 0 16) ++ [ ( "sorted", sorted ) ])


main : Program () () ()
main =
    worker report
