module SeqDictTrie exposing (remap)

{-| Copies a SeqDict trie with its entries replaced, for `SeqDict.map`
(plans/seq-data-structures-performance.md, the `map` follow-up). Internal to eco/system's SeqDict.

@docs remap

-}

import Eco.Kernel.SeqDictTrie
import JsArray2 exposing (JsArray2)


{-| `remap flat probe root` copies the trie `root`, putting in place of each entry the entry at its
order index in `flat`. `probe` is any `Sub` slot of the result's slot type: the native kernel builds
its slots in the probe's representation.
-}
remap : JsArray2 (Maybe entryB) -> slotB -> nodeA -> nodeB
remap =
    Eco.Kernel.SeqDictTrie.remap
