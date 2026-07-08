module ReprDerefStressTest exposing (main)

{-| Stress the inline heap-dereference fast paths (plan hpointer-deref-inline-fastpath,
--inline-deref) over old-gen–promoted structures.

Builds a large list of records, then traverses it repeatedly. The initial build
survives many minor GCs (promoting the spine + records to old gen) and provokes
major GC / incremental compaction, so the record/list projections below run
against relocated old-gen objects — exactly the path where the inline forward
check (and its eco_follow_forward slow path) must fire correctly.

Exercises inline deref of: list head/tail, record field project (Int + boxed),
tuple project, and Bool unbox — all over long-lived old-gen data.
-}

-- CHECK: sumField: 49995000
-- CHECK: nested: 149985000
-- CHECK: trueCount: 3334

import Html exposing (text)


type alias Item =
    { n : Int, flag : Bool, pair : ( Int, Int ) }


mkItem : Int -> Item
mkItem i =
    { n = i, flag = modBy 3 i == 0, pair = ( i, i * 2 ) }


items : List Item
items =
    List.map mkItem (List.range 0 9999)


sumField : Int
sumField =
    List.foldl (\it acc -> acc + it.n) 0 items


nested : Int
nested =
    -- projects a tuple field out of each old-gen record
    List.foldl (\it acc -> acc + Tuple.first it.pair + Tuple.second it.pair) 0 items


trueCount : Int
trueCount =
    List.foldl
        (\it acc ->
            if it.flag then
                acc + 1

            else
                acc
        )
        0
        items


main =
    let
        _ = Debug.log "sumField" sumField
        _ = Debug.log "nested" nested
        _ = Debug.log "trueCount" trueCount
    in
    text "done"
