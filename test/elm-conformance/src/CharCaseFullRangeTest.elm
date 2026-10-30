module CharCaseFullRangeTest exposing (main)

{-| The whole case-mapping table, as hashes. For every code point of every plane (surrogates
and `skip` skipped) it mixes the Char mappings, their re-mappings, Char.toCode, Char.isUpper and
the one-Char String mappings into one hash per plane ("plane p"); String.toUpper/toLower of each
block of 0x100 code points (minus `skip`) into a second hash per plane ("strplane p"), which
covers the whole-string paths with real neighbours; and the sorted list of every toUpper/toLower
result below U+D800 whose source is not in `skip`, plus its Set size ("sorted"). A mismatch says
which plane to look at. Expectations recorded from Elm (run-js-e2e.js --record).

`skip` holds the code points where eco differs from Elm on purpose (plans/char-simple-case-mapping.md,
design\_docs/char-case-mapping.md): the 103 whose full case mapping is several code points (Elm's
results for them are recorded in CaseMappingDivergenceTest), U+1E9E, whose lower case is U+00DF,
and U+03A3, whose lower case depends on Final\_Sigma. All are in the BMP, so the hashes of planes
1-16 are what they would be without it.
-}

-- CHECK: plane 0: "818950263"
-- CHECK: strplane 0: "773073838"
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
-- CHECK: sorted: "1490912566"

import ConformanceHelp exposing (charCps, hashString, logAll, mix, worker)
import Set


isSurrogate : Int -> Bool
isSurrogate cp =
    cp >= 0xD800 && cp <= 0xDFFF


{-| The code points left out (see the module comment).
-}
skip : Set.Set Int
skip =
    Set.fromList
        (0x1E9E
            :: 0x03A3
            :: [ 0x00DF, 0x0130, 0x0149, 0x01F0, 0x0390, 0x03B0, 0x0587, 0x1E96, 0x1E97, 0x1E98
               , 0x1E99, 0x1E9A, 0x1F50, 0x1F52, 0x1F54, 0x1F56, 0x1F80, 0x1F81, 0x1F82, 0x1F83
               , 0x1F84, 0x1F85, 0x1F86, 0x1F87, 0x1F88, 0x1F89, 0x1F8A, 0x1F8B, 0x1F8C, 0x1F8D
               , 0x1F8E, 0x1F8F, 0x1F90, 0x1F91, 0x1F92, 0x1F93, 0x1F94, 0x1F95, 0x1F96, 0x1F97
               , 0x1F98, 0x1F99, 0x1F9A, 0x1F9B, 0x1F9C, 0x1F9D, 0x1F9E, 0x1F9F, 0x1FA0, 0x1FA1
               , 0x1FA2, 0x1FA3, 0x1FA4, 0x1FA5, 0x1FA6, 0x1FA7, 0x1FA8, 0x1FA9, 0x1FAA, 0x1FAB
               , 0x1FAC, 0x1FAD, 0x1FAE, 0x1FAF, 0x1FB2, 0x1FB3, 0x1FB4, 0x1FB6, 0x1FB7, 0x1FBC
               , 0x1FC2, 0x1FC3, 0x1FC4, 0x1FC6, 0x1FC7, 0x1FCC, 0x1FD2, 0x1FD3, 0x1FD6, 0x1FD7
               , 0x1FE2, 0x1FE3, 0x1FE4, 0x1FE6, 0x1FE7, 0x1FF2, 0x1FF3, 0x1FF4, 0x1FF6, 0x1FF7
               , 0x1FFC, 0xFB00, 0xFB01, 0xFB02, 0xFB03, 0xFB04, 0xFB05, 0xFB06, 0xFB13, 0xFB14
               , 0xFB15, 0xFB16, 0xFB17
               ]
        )


skipped : Int -> Bool
skipped cp =
    isSurrogate cp || Set.member cp skip


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


{-| Folds `mixCodePoint` over code points `cp .. last`, skipping surrogates and `skip`.
Tail-recursive.
-}
charLoop : Int -> Int -> Int -> Int
charLoop cp last h =
    if cp > last then
        h

    else if skipped cp then
        charLoop (cp + 1) last h

    else
        charLoop (cp + 1) last (mixCodePoint cp h)


{-| The String of code points `lo .. lo + 0xFF`, surrogates and `skip` skipped.
-}
block : Int -> String
block lo =
    List.range lo (lo + 0xFF)
        |> List.filter (\cp -> not (skipped cp))
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
                |> List.filter (\cp -> not (Set.member cp skip))
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
