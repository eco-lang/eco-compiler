module ReprDerefStressTest exposing (main)

{-| Checks record field access, tuple projection and `Bool` field tests over a 10,000-element list of records that stays live while it is traversed three times.

Each `Item` for `i` in 0 to 9999 holds `n = i`, `flag = (modBy 3 i == 0)` and
`pair = ( i, i * 2 )`. Three folds over the same top-level list check:

  - `sumField`: the sum of `n`, 0 + ... + 9999 = 49995000.
  - `nested`: the sum of both tuple components, 3 times that, 149985000.
  - `trueCount`: how many `flag`s are `True`, the 3334 multiples of 3 in the range.

## eco

Stresses the inline heap-dereference fast paths
(plans/hpointer-deref-inline-fastpath.md). The list outlives many minor GCs, so
its spine and records are promoted to the old generation and may be moved by
major GC and incremental compaction. The list head/tail, record field (`Int`
and boxed), tuple projections and `Bool` tests then run against relocated
objects, where the inline forwarding check and its `eco_follow_forward` slow
path (runtime/src/allocator/RuntimeExports.cpp) must fire correctly.

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
