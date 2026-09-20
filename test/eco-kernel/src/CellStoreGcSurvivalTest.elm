module CellStoreGcSurvivalTest exposing (main)

{-| THE pin for the root scanner. Everything else about CellStore can be right
and this can still be wrong, silently, until a collection moves an object a
cell points at.

Shape: push tens of thousands of freshly allocated records into a store, then
allocate a large amount of garbage so several minor collections run and some
of the store's objects are promoted, then read every cell back and check its
payload. If the cells were not registered as GC roots, or were registered but
not UPDATED when the collector moved the objects, the payloads come back wrong
or the run crashes.

The trail is covered too: a scope is opened and filled with replacement values
before the garbage is allocated, so the ORIGINAL values are reachable only
from the trail at that moment. Rolling back afterwards must restore them
intact, which it can only do if the trail was scanned and forwarded as well.
-}

-- CHECK: CellStoreGcSurvivalTest: True

import Eco.CellStore as CS
import Platform


type alias Cell =
    { tag : Int, name : String, pad : List Int }


cell : Int -> Cell
cell i =
    { tag = i, name = "cell-" ++ String.fromInt i, pad = [ i, i + 1, i + 2 ] }


count : Int
count =
    40000


build : Int -> CS.Store Cell -> CS.Store Cell
build i st =
    if i >= count then
        st

    else
        build (i + 1) (CS.push (cell i) st)


checkAll : Int -> CS.Store Cell -> Bool
checkAll i st =
    if i >= count then
        True

    else if CS.get i st == cell i then
        checkAll (i + 1) st

    else
        False


{-| Allocate a lot of short-lived garbage to force minor collections and some
promotion. The sum is returned so nothing here can be optimized away.
-}
churn : Int -> Int -> Int
churn n acc =
    if n <= 0 then
        acc

    else
        let
            junk =
                List.map (\k -> { tag = k, name = "junk", pad = [ k ] }) (List.range 0 60)

            s =
                List.foldl (\r a -> a + r.tag) 0 junk
        in
        churn (n - 1) (acc + modBy 7 s)


{-| Replace the first 5000 cells inside an open scope. After this the ORIGINAL
values for those indices are reachable only from the trail.
-}
replace : Int -> CS.Store Cell -> CS.Store Cell
replace i st =
    if i >= 5000 then
        st

    else
        replace (i + 1) (CS.set i { tag = -1, name = "replaced", pad = [] } st)


result : Bool
result =
    let
        filled =
            build 0 (CS.new 1024)
    in
    -- Chained, not a let block: `replace` MUTATES the same store `checkAll`
    -- reads, and independent let bindings are not ordered. See the note in
    -- CellStoreRoundtripTest.
    if churn 3000 0 < 0 then
        False

    else if not (checkAll 0 filled) then
        False

    else
        let
            -- originals for [0, 5000) now live only in the trail
            speculated =
                replace 0 (CS.pushMark filled)
        in
        if churn 3000 0 < 0 then
            False

        else
            let
                restored =
                    CS.rollback speculated
            in
            CS.size restored == count && checkAll 0 restored


init : () -> ( (), Cmd () )
init _ =
    let
        _ =
            Debug.log "CellStoreGcSurvivalTest" result
    in
    ( (), Cmd.none )


main : Program () () ()
main =
    Platform.worker
        { init = init
        , update = \_ m -> ( m, Cmd.none )
        , subscriptions = \_ -> Sub.none
        }
