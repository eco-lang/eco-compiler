module DebugLogIntCompareTest exposing (main)

{-| DEBUGLOG-INT-CMP, found while fixing HASH-01 (plans/kernel-lib-bug-fixes.md, work package C2):
an Int that came back from `Debug.log`, put in a list literal and compared with `<` inside a
`List.all` lambda, compared wrongly natively: `List.all (\h -> h < 67108864) [ Debug.log "d" 66108864 ]`
gave `False` (Elm: `True`), while `h >= 0` gave `True`. `Debug.log` yielded its argument boxed, and
the list literal chose the head's slot kind from that SSA type, so the `List Int` had a boxed head
which the compiled list walk read as a raw Int (the pointer bits). List literals now follow the
element type's static layout (REP_HEAP_001, HEAP_046), and `Debug.log` yields its argument
unboxed. Expected output recorded from Elm on node (run-js-e2e.js --record).
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
