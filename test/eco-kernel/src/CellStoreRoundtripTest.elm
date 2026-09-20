module CellStoreRoundtripTest exposing (main)

{-| Eco.CellStore basic round-trip on the NATIVE kernel: push, get, set, get,
over enough boxed values that the backing vector reallocates several times.

The values are records, not Ints, so every cell holds a real HPointer that has
to survive the kernel boundary unchanged — an Int could be embedded and would
not exercise the boxed path.

This is also the pin for the index contract the union-find store depends on:
the index a value lands at is the `size` taken BEFORE the push.

NOTE ON SHAPE. The checks below are an `if`/`else` chain, not a `let` block of
independent bindings, and that is deliberate. The store is mutated IN PLACE, so
a read of it and a write to it are ordered only if the handle threads them —
Elm's `let` bindings are sorted into dependency order and independent ones may
be evaluated in any order. An earlier draft of this file bound `readOk` and
`written` side by side and read the OVERWRITTEN cells in `readOk`, which is the
contract being violated by the test rather than by the kernel. Keep the chain.
-}

-- CHECK: CellStoreRoundtripTest: True

import Eco.CellStore as CS
import Platform


type alias Cell =
    { tag : Int, name : String }


cell : Int -> Cell
cell i =
    { tag = i, name = "cell-" ++ String.fromInt i }


count : Int
count =
    1000


build : Int -> CS.Store Cell -> CS.Store Cell
build i st =
    if i >= count then
        st

    else
        build (i + 1) (CS.push (cell i) st)


{-| Every index reads back the value pushed at it.
-}
checkAll : Int -> CS.Store Cell -> Bool
checkAll i st =
    if i >= count then
        True

    else if CS.get i st == cell i then
        checkAll (i + 1) st

    else
        False


{-| Overwrite every third cell, then check the whole store again.
-}
overwrite : Int -> CS.Store Cell -> CS.Store Cell
overwrite i st =
    if i >= count then
        st

    else
        overwrite (i + 3) (CS.set i { tag = -i, name = "over" } st)


checkOverwritten : Int -> CS.Store Cell -> Bool
checkOverwritten i st =
    if i >= count then
        True

    else
        let
            expected =
                if modBy 3 i == 0 then
                    { tag = -i, name = "over" }

                else
                    cell i
        in
        if CS.get i st == expected then
            checkOverwritten (i + 1) st

        else
            False


result : Bool
result =
    let
        filled =
            build 0 (CS.new 8)
    in
    -- Chained so that every read of `filled` happens before `overwrite`
    -- mutates it. See the note in the module docs.
    if CS.size (CS.new 8) /= 0 then
        False

    else if CS.size filled /= count then
        False

    else if not (checkAll 0 filled) then
        False

    else
        let
            written =
                overwrite 0 filled
        in
        CS.size written == count && checkOverwritten 0 written


init : () -> ( (), Cmd () )
init _ =
    let
        _ =
            Debug.log "CellStoreRoundtripTest" result
    in
    ( (), Cmd.none )


main : Program () () ()
main =
    Platform.worker
        { init = init
        , update = \_ m -> ( m, Cmd.none )
        , subscriptions = \_ -> Sub.none
        }
