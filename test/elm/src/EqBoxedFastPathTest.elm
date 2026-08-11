module EqBoxedFastPathTest exposing (main)

{-| kernel-opt-03 Phase 3: boxed structural equality lowers to `eco.value.eq`
under `ECO_VALUE_EQ=1`, and Bool equality lowers to `eco.bool.xor`
unconditionally.

Behaviour must be IDENTICAL in both flavours, so this fixture pins behaviour.
Each admissible shape is compared three ways, one per arm of the expansion:

  - with ITSELF, which is arm 1 (word equality) — the arm that must never
    disagree with the kernel, and does not, because `eqHelp`'s
    `if (a == b) return true` runs before its tag switch;
  - with a structurally-equal TWIN built separately, which reaches arm 3 (the
    kernel call) and must answer True;
  - with a different value, which answers False through arm 2 or arm 3.

`unitEq` is the pure arm-2 witness reachable from Elm: `()` is the merged
`Const_Empty` embedded constant, so both operands have `ptr_ind` set.

`notEqual` is emission-side negation (`eco.bool.not` after the op, no second op
def), so every shape is also exercised through `/=`.

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

        -- Built separately, so these are distinct heap pointers with equal
        -- contents: arm 3.
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

        -- Both operands are the merged Const_Empty constant: pure arm 2.
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
