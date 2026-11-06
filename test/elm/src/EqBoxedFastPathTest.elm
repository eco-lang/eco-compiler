module EqBoxedFastPathTest exposing (main)

{-| Structural equality gives the correct answer for strings, lists, tuples,
records, custom types, unit, empty values, `Bool` and nested containers, through
both `==` and `/=`.

Each shape is compared with an equal value built separately (`strTwin`,
`listTwin`, `tupleTwin`, `recordTwin`, `customTwin`, `nestedTwin`) and, except
the nested one, with a different value (`strDiff`, `listDiff`, `tupleDiff`,
`recordDiff`, `customDiff`). A string and a list are also compared with
themselves (`strSame`, `listSame`). `twinA` and `twinB` are computed at run time
by the same expression, so they are equal strings that are not one literal;
`List.range 1 3` is compared with the literal `[ 1, 2, 3 ]` for the same reason.

The remaining cases compare `()` with `()`, `""` with `""`, `[]` with `[]`, and
the `Bool` constants with each other; `strNe` and `boolNe` check `/=`.

-}

-- CHECK: strSame: True
-- CHECK: strTwin: True
-- CHECK: strDiff: False
-- CHECK: strNe: True
-- CHECK: listSame: True
-- CHECK: listTwin: True
-- CHECK: listDiff: False
-- CHECK: tupleTwin: True
-- CHECK: tupleDiff: False
-- CHECK: recordTwin: True
-- CHECK: recordDiff: False
-- CHECK: customTwin: True
-- CHECK: customDiff: False
-- CHECK: unitEq: True
-- CHECK: emptyStrEq: True
-- CHECK: emptyListEq: True
-- CHECK: boolTT: True
-- CHECK: boolTF: False
-- CHECK: boolNe: True
-- CHECK: nestedTwin: True

import Html exposing (text)


type Shape
    = Circle Int
    | Rect Int Int


twinA : String
twinA =
    String.fromInt 42 ++ "x"


twinB : String
twinB =
    String.fromInt 42 ++ "x"


main : Html.Html msg
main =
    let
        s =
            "hello"

        l =
            [ 1, 2, 3 ]

        _ =
            Debug.log "strSame" (s == s)

        -- Equal strings computed separately, not the same literal.
        _ =
            Debug.log "strTwin" (twinA == twinB)

        _ =
            Debug.log "strDiff" (twinA == "nope")

        _ =
            Debug.log "strNe" (twinA /= "nope")

        _ =
            Debug.log "listSame" (l == l)

        _ =
            Debug.log "listTwin" (List.range 1 3 == [ 1, 2, 3 ])

        _ =
            Debug.log "listDiff" (List.range 1 3 == [ 1, 2 ])

        _ =
            Debug.log "tupleTwin" (( 1, "a" ) == ( 1, "a" ))

        _ =
            Debug.log "tupleDiff" (( 1, "a" ) == ( 1, "b" ))

        _ =
            Debug.log "recordTwin" ({ x = 1, y = "a" } == { x = 1, y = "a" })

        _ =
            Debug.log "recordDiff" ({ x = 1, y = "a" } == { x = 2, y = "a" })

        _ =
            Debug.log "customTwin" (Rect 2 3 == Rect 2 3)

        _ =
            Debug.log "customDiff" (Rect 2 3 == Circle 2)

        _ =
            Debug.log "unitEq" (() == ())

        _ =
            Debug.log "emptyStrEq" ("" == "")

        _ =
            Debug.log "emptyListEq" ([] == [])

        _ =
            Debug.log "boolTT" (True == True)

        _ =
            Debug.log "boolTF" (True == False)

        _ =
            Debug.log "boolNe" (True /= False)

        _ =
            Debug.log "nestedTwin" (Just [ ( 1, "a" ) ] == Just [ ( 1, "a" ) ])
    in
    text "done"
