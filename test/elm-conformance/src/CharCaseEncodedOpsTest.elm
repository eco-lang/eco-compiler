module CharCaseEncodedOpsTest exposing (main)

{-| Operations on the multi-code-point Chars that Char.toUpper/toLower return: equality,
compare, sort, Dict and Set keys, case, the Char predicates, re-mapping, the String functions
that write or read Chars, and Debug.log. Every equality here gives the same answer in Elm's
debug mode and under --optimize (the JS runner's mode guard checks this).
Expectations recorded from Elm (plans/char-case-mapping-elm-exact.md Step 0.6).
-}

-- CHECK: dbg: 'SS'
-- CHECK: dbgfi: 'FI'
-- CHECK: eq upSharpS S: "False"
-- CHECK: ne upSharpS S: "True"
-- CHECK: eq up1FB3 up1FBC: "True"
-- CHECK: eq upSharpS up1E9E: "False"
-- CHECK: cmp up1FB3 up1FBC: "EQ"
-- CHECK: cmp upSharpS S: "GT"
-- CHECK: cmp upSharpS T: "LT"
-- CHECK: cmp upSharpS R: "GT"
-- CHECK: cmp S upSharpS: "LT"
-- CHECK: cmp upSharpS upFB00: "GT"
-- CHECK: cmp upFB01 upFB00: "GT"
-- CHECK: lt upSharpS T: "True"
-- CHECK: gt upSharpS S: "True"
-- CHECK: max upSharpS S: "53 53"
-- CHECK: sorted: "46,46 46,46 46 49,46 49,46 4C,47,53,53 53,54"
-- CHECK: dict size: "6"
-- CHECK: dict keys: "41,46 49,53,53 53,54,391 399"
-- CHECK: dict values: "2,7,5,3,6,4"
-- CHECK: dict get up1FBC: "Just 4"
-- CHECK: dict get upSharpS: "Just 3"
-- CHECK: set size: "5"
-- CHECK: set list: "46,46 46,53,53 53,391 399"
-- CHECK: set member upFB00: "True"
-- CHECK: case upSharpS: "other"
-- CHECK: isUpper upSharpS: "True"
-- CHECK: isLower upSharpS: "False"
-- CHECK: isAlpha upSharpS: "True"
-- CHECK: isLower lo130: "True"
-- CHECK: isAlpha lo130: "True"
-- CHECK: lo upSharpS: "73 73"
-- CHECK: up lo130: "49 307"
-- CHECK: up upSharpS: "53 53"
-- CHECK: lo lo130: "69 307"
-- CHECK: up up390: "399 308 301"
-- CHECK: lo up390: "3B9 308 301"
-- CHECK: fromChar upSharpS: "53 53"
-- CHECK: cons upSharpS: "53 53 78"
-- CHECK: fromList: "53 53 78 399 308 301"
-- CHECK: map toUpper strasse: "53 54 52 41 53 53 45"
-- CHECK: toList fromChar upSharpS: "53,53"
-- CHECK: length fromList: "5"
-- CHECK: fromCode toCode upSharpS: "53"
-- CHECK: toCode up390: "921"
-- CHECK: toCode lo130: "105"
-- CHECK: member list: "False"
-- CHECK: dbg value: "53 53"
-- CHECK: dbgfi value: "46 49"

import ConformanceHelp exposing (charCps, logAll, worker)
import Dict
import Set


sharpS : Char
sharpS =
    '\u{00DF}'


up : Char -> Char
up =
    Char.toUpper


lo : Char -> Char
lo =
    Char.toLower


bool : Bool -> String
bool b =
    if b then
        "True"

    else
        "False"


order : Order -> String
order o =
    case o of
        LT ->
            "LT"

        EQ ->
            "EQ"

        GT ->
            "GT"


cpsList : List Char -> String
cpsList cs =
    String.join "," (List.map charCps cs)


maybeInt : Maybe Int -> String
maybeInt m =
    case m of
        Just n ->
            "Just " ++ String.fromInt n

        Nothing ->
            "Nothing"


caseSharpS : Char -> String
caseSharpS c =
    case c of
        'S' ->
            "S"

        _ ->
            "other"


dict : Dict.Dict Char Int
dict =
    Dict.fromList
        [ ( up '\u{1FB3}', 1 )
        , ( 'A', 2 )
        , ( up sharpS, 3 )
        , ( up '\u{1FBC}', 4 )
        , ( 'S', 5 )
        , ( 'T', 6 )
        , ( up '\u{FB01}', 7 )
        ]


set : Set.Set Char
set =
    Set.fromList [ up '\u{1FB3}', up '\u{1FBC}', 'S', up sharpS, up sharpS, 'F', up '\u{FB00}' ]


report : ()
report =
    logAll
        [ ( "eq upSharpS S", bool (up sharpS == 'S') )
        , ( "ne upSharpS S", bool (up sharpS /= 'S') )
        , ( "eq up1FB3 up1FBC", bool (up '\u{1FB3}' == up '\u{1FBC}') )
        , ( "eq upSharpS up1E9E", bool (up sharpS == up '\u{1E9E}') )
        , ( "cmp up1FB3 up1FBC", order (compare (up '\u{1FB3}') (up '\u{1FBC}')) )
        , ( "cmp upSharpS S", order (compare (up sharpS) 'S') )
        , ( "cmp upSharpS T", order (compare (up sharpS) 'T') )
        , ( "cmp upSharpS R", order (compare (up sharpS) 'R') )
        , ( "cmp S upSharpS", order (compare 'S' (up sharpS)) )
        , ( "cmp upSharpS upFB00", order (compare (up sharpS) (up '\u{FB00}')) )
        , ( "cmp upFB01 upFB00", order (compare (up '\u{FB01}') (up '\u{FB00}')) )
        , ( "lt upSharpS T", bool (up sharpS < 'T') )
        , ( "gt upSharpS S", bool (up sharpS > 'S') )
        , ( "max upSharpS S", charCps (max (up sharpS) 'S') )
        , ( "sorted"
          , cpsList
                (List.sort
                    [ up sharpS, 'S', 'T', up '\u{FB00}', 'F', up '\u{FB01}', up '\u{FB02}', 'G', up '\u{FB03}' ]
                )
          )
        , ( "dict size", String.fromInt (Dict.size dict) )
        , ( "dict keys", cpsList (Dict.keys dict) )
        , ( "dict values", String.join "," (List.map String.fromInt (Dict.values dict)) )
        , ( "dict get up1FBC", maybeInt (Dict.get (up '\u{1FBC}') dict) )
        , ( "dict get upSharpS", maybeInt (Dict.get (up sharpS) dict) )
        , ( "set size", String.fromInt (Set.size set) )
        , ( "set list", cpsList (Set.toList set) )
        , ( "set member upFB00", bool (Set.member (up '\u{FB00}') set) )
        , ( "case upSharpS", caseSharpS (up sharpS) )
        , ( "isUpper upSharpS", bool (Char.isUpper (up sharpS)) )
        , ( "isLower upSharpS", bool (Char.isLower (up sharpS)) )
        , ( "isAlpha upSharpS", bool (Char.isAlpha (up sharpS)) )
        , ( "isLower lo130", bool (Char.isLower (lo '\u{0130}')) )
        , ( "isAlpha lo130", bool (Char.isAlpha (lo '\u{0130}')) )
        , ( "lo upSharpS", charCps (lo (up sharpS)) )
        , ( "up lo130", charCps (up (lo '\u{0130}')) )
        , ( "up upSharpS", charCps (up (up sharpS)) )
        , ( "lo lo130", charCps (lo (lo '\u{0130}')) )
        , ( "up up390", charCps (up (up '\u{0390}')) )
        , ( "lo up390", charCps (lo (up '\u{0390}')) )
        , ( "fromChar upSharpS", ConformanceHelp.cps (String.fromChar (up sharpS)) )
        , ( "cons upSharpS", ConformanceHelp.cps (String.cons (up sharpS) "x") )
        , ( "fromList", ConformanceHelp.cps (String.fromList [ up sharpS, 'x', up '\u{0390}' ]) )
        , ( "map toUpper strasse", ConformanceHelp.cps (String.map Char.toUpper "stra\u{00DF}e") )
        , ( "toList fromChar upSharpS", cpsList (String.toList (String.fromChar (up sharpS))) )
        , ( "length fromList", String.fromInt (String.length (String.fromList [ up sharpS, up '\u{0390}' ])) )
        , ( "fromCode toCode upSharpS", charCps (Char.fromCode (Char.toCode (up sharpS))) )
        , ( "toCode up390", String.fromInt (Char.toCode (up '\u{0390}')) )
        , ( "toCode lo130", String.fromInt (Char.toCode (lo '\u{0130}')) )
        , ( "member list", bool (List.member (up sharpS) [ 'T', up '\u{1E9E}' ]) )

        -- The only raw Char logs (their expansions are ASCII). Their results feed the report so
        -- that no target can drop them as unused. Each logs one Char, not a list: Elm prints a
        -- list as [a,b] and eco as [a, b], a Debug-format divergence unrelated to case mapping.
        , ( "dbg value", charCps (Debug.log "dbg" (up sharpS)) )
        , ( "dbgfi value", charCps (Debug.log "dbgfi" (up '\u{FB01}')) )
        ]


main : Program () () ()
main =
    worker report
