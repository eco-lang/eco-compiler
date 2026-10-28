module CharCaseOrdinaryTest exposing (main)

{-| Char.toUpper/toLower of characters whose case mapping is one code point (or none), across
Latin-1, Greek, Cyrillic, Armenian, Georgian, Cherokee, titlecase digraphs and an astral
script. Expectations recorded from Elm (plans/char-case-mapping-elm-exact.md Step 0.6).
-}

-- CHECK: E9 up: "C9"
-- CHECK: E9 lo: "E9"
-- CHECK: FF up: "178"
-- CHECK: FF lo: "FF"
-- CHECK: B5 up: "39C"
-- CHECK: B5 lo: "B5"
-- CHECK: 131 up: "49"
-- CHECK: 131 lo: "131"
-- CHECK: 17F up: "53"
-- CHECK: 17F lo: "17F"
-- CHECK: 3A3 up: "3A3"
-- CHECK: 3A3 lo: "3C3"
-- CHECK: 436 up: "416"
-- CHECK: 436 lo: "436"
-- CHECK: 416 up: "416"
-- CHECK: 416 lo: "436"
-- CHECK: 561 up: "531"
-- CHECK: 561 lo: "561"
-- CHECK: 10D0 up: "1C90"
-- CHECK: 10D0 lo: "10D0"
-- CHECK: 13A0 up: "13A0"
-- CHECK: 13A0 lo: "AB70"
-- CHECK: AB70 up: "13A0"
-- CHECK: AB70 lo: "AB70"
-- CHECK: 1C5 up: "1C4"
-- CHECK: 1C5 lo: "1C6"
-- CHECK: C0 up: "C0"
-- CHECK: C0 lo: "E0"
-- CHECK: 10428 up: "10400"
-- CHECK: 10428 lo: "10428"
-- CHECK: 10400 up: "10400"
-- CHECK: 10400 lo: "10428"
-- CHECK: 31 up: "31"
-- CHECK: 31 lo: "31"
-- CHECK: 4E2D up: "4E2D"
-- CHECK: 4E2D lo: "4E2D"
-- CHECK: 1F600 up: "1F600"
-- CHECK: 1F600 lo: "1F600"
-- CHECK: 3B1 up: "391"
-- CHECK: 3B1 lo: "3B1"
-- CHECK: 3B2 up: "392"
-- CHECK: 3B2 lo: "3B2"
-- CHECK: 3B3 up: "393"
-- CHECK: 3B3 lo: "3B3"
-- CHECK: 3B4 up: "394"
-- CHECK: 3B4 lo: "3B4"
-- CHECK: 3B5 up: "395"
-- CHECK: 3B5 lo: "3B5"
-- CHECK: 3B6 up: "396"
-- CHECK: 3B6 lo: "3B6"
-- CHECK: 3B7 up: "397"
-- CHECK: 3B7 lo: "3B7"
-- CHECK: 3B8 up: "398"
-- CHECK: 3B8 lo: "3B8"
-- CHECK: 3B9 up: "399"
-- CHECK: 3B9 lo: "3B9"
-- CHECK: 3BA up: "39A"
-- CHECK: 3BA lo: "3BA"
-- CHECK: 3BB up: "39B"
-- CHECK: 3BB lo: "3BB"
-- CHECK: 3BC up: "39C"
-- CHECK: 3BC lo: "3BC"
-- CHECK: 3BD up: "39D"
-- CHECK: 3BD lo: "3BD"
-- CHECK: 3BE up: "39E"
-- CHECK: 3BE lo: "3BE"
-- CHECK: 3BF up: "39F"
-- CHECK: 3BF lo: "3BF"
-- CHECK: 3C0 up: "3A0"
-- CHECK: 3C0 lo: "3C0"
-- CHECK: 3C1 up: "3A1"
-- CHECK: 3C1 lo: "3C1"
-- CHECK: 3C2 up: "3A3"
-- CHECK: 3C2 lo: "3C2"
-- CHECK: 3C3 up: "3A3"
-- CHECK: 3C3 lo: "3C3"
-- CHECK: 3C4 up: "3A4"
-- CHECK: 3C4 lo: "3C4"
-- CHECK: 3C5 up: "3A5"
-- CHECK: 3C5 lo: "3C5"
-- CHECK: 3C6 up: "3A6"
-- CHECK: 3C6 lo: "3C6"
-- CHECK: 3C7 up: "3A7"
-- CHECK: 3C7 lo: "3C7"
-- CHECK: 3C8 up: "3A8"
-- CHECK: 3C8 lo: "3C8"
-- CHECK: 3C9 up: "3A9"
-- CHECK: 3C9 lo: "3C9"

import ConformanceHelp exposing (charCps, logAll, worker)


inputs : List Char
inputs =
    [ '\u{00E9}' -- e acute
    , '\u{00FF}' -- y diaeresis (upper is U+0178)
    , '\u{00B5}' -- micro sign (upper is Greek mu)
    , '\u{0131}' -- dotless i (upper is I)
    , '\u{017F}' -- long s (upper is S)
    , '\u{03A3}' -- capital sigma (a lone one lowers to U+03C3)
    , '\u{0436}' -- Cyrillic zhe
    , '\u{0416}' -- Cyrillic capital zhe
    , '\u{0561}' -- Armenian ayb
    , '\u{10D0}' -- Georgian an (upper is Mtavruli U+1C90)
    , '\u{13A0}' -- Cherokee A
    , '\u{AB70}' -- Cherokee small a
    , '\u{01C5}' -- titlecase DZ with caron
    , '\u{00C0}' -- A grave
    , '\u{10428}' -- Deseret small long i
    , '\u{10400}' -- Deseret capital long i
    , '1'
    , '\u{4E2D}' -- CJK, no case
    , '\u{1F600}' -- emoji, no case
    ]
        ++ List.map Char.fromCode (List.range 0x03B1 0x03C9)


entries : Char -> List ( String, String )
entries c =
    let
        name =
            charCps c
    in
    [ ( name ++ " up", charCps (Char.toUpper c) )
    , ( name ++ " lo", charCps (Char.toLower c) )
    ]


report : ()
report =
    logAll (List.concatMap entries inputs)


main : Program () () ()
main =
    worker report
