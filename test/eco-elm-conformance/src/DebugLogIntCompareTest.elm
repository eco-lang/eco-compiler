module DebugLogIntCompareTest exposing (main)

{-| An Int returned by `Debug.log`, placed in a list literal, compares correctly with `<` inside a
`List.all` lambda.

`d` is `Debug.log "d" 66108864`, which logs and returns 66108864.

  - `allLt`: `List.all (\h -> h < 67108864) [ d ]` is `True`.
  - `allBoth`: the same list with `h >= 0 && h < 67108864` is `True`.
  - `allPlain`: the first test on a list holding the literal 66108864 directly is `True`.

## eco

Found while fixing a hashing bug in the kernel library work (plans/kernel-lib-bug-fixes.md). Natively, `allLt` used to print `False` while `allBoth` printed `True`. `Debug.log` returned its argument boxed, and the list literal chose the head's slot kind from that SSA type, so the `List Int` held a boxed head that the compiled list walk read as a raw Int (the pointer bits). List literals now follow the element type's static layout (REP_HEAP_001 and HEAP_046 in design_docs/invariants.csv), and `Debug.log` returns its argument unboxed.

The expected output was recorded from Elm on node (test/scripts/run-js-e2e.js --record).

-}

-- CHECK: d: 66108864
-- CHECK: allLt: True
-- CHECK: allBoth: True
-- CHECK: allPlain: True

import Platform


main : Program () () ()
main =
    let
        d =
            Debug.log "d" 66108864

        plain =
            66108864

        _ =
            Debug.log "allLt" (List.all (\h -> h < 67108864) [ d ])

        _ =
            Debug.log "allBoth" (List.all (\h -> h >= 0 && h < 67108864) [ d ])

        _ =
            Debug.log "allPlain" (List.all (\h -> h < 67108864) [ plain ])
    in
    Platform.worker
        { init = \_ -> ( (), Cmd.none )
        , update = \_ m -> ( m, Cmd.none )
        , subscriptions = \_ -> Sub.none
        }
