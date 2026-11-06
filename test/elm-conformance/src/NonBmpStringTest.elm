module NonBmpStringTest exposing (main)

{-| String functions that work a `Char` at a time step over a character outside the Basic
Multilingual Plane as one `Char`, while `String.length` counts it as two UTF-16 code units.

The text is "a😀b" (U+1F600 between two ASCII letters), and a `Char` literal holds U+1F600. The
tests check `String.length` (4), `String.toList`, the folds, `uncons`, `map`, `filter`, `any`,
`all`, `reverse`, `cons`, `fromList` and `fromChar`, and the literal's `Char.toCode`. Characters
are logged as decimal codes or as hexadecimal code points (`ConformanceHelp.cps`).

-}

-- CHECK: length: "4"
-- CHECK: toList: "[97,128512,98]"
-- CHECK: toList length: "3"
-- CHECK: foldl: "3"
-- CHECK: foldr: "[97,128512,98]"
-- CHECK: uncons: "Just (128512,1)"
-- CHECK: map: "78 1F600 62"
-- CHECK: filter: "2"
-- CHECK: any all: "(True,False)"
-- CHECK: reverse: "62 1F600 61"
-- CHECK: literal: "1F600"
-- CHECK: literal code: "128512"
-- CHECK: fromChar length: "2"
-- CHECK: cons: "1F600 7A"
-- CHECK: fromList: "1F600 71 1F600"

import ConformanceHelp exposing (charCps, cps, logAll, worker)


literal : Char
literal =
    '😀'


text : String
text =
    "a😀b"


report : ()
report =
    logAll
        [ ( "length", String.fromInt (String.length text) )
        , ( "toList", Debug.toString (List.map (\c -> Char.toCode c) (String.toList text)) )
        , ( "toList length", String.fromInt (List.length (String.toList text)) )
        , ( "foldl", String.fromInt (String.foldl (\_ n -> n + 1) 0 text) )
        , ( "foldr", Debug.toString (String.foldr (\c acc -> Char.toCode c :: acc) [] text) )
        , ( "uncons", Debug.toString (Maybe.map (\( c, rest ) -> ( Char.toCode c, String.length rest )) (String.uncons (String.dropLeft 1 text))) )
        , ( "map", cps (String.map (\c -> if c == 'a' then 'x' else c) text) )
        , ( "filter", String.fromInt (String.length (String.filter (\c -> Char.toCode c > 0xFFFF) text)) )
        , ( "any all", Debug.toString ( String.any (\c -> c == literal) text, String.all (\c -> Char.toCode c < 0x10000) text ) )
        , ( "reverse", cps (String.reverse text) )
        , ( "literal", charCps literal )
        , ( "literal code", String.fromInt (Char.toCode literal) )
        , ( "fromChar length", String.fromInt (String.length (String.fromChar literal)) )
        , ( "cons", cps (String.cons literal "z") )
        , ( "fromList", cps (String.fromList [ literal, 'q', literal ]) )
        ]


main : Program () () ()
main =
    worker report
