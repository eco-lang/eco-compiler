module DebugLogOrderingTest exposing (main)

{-| Pins design_docs/debug-log-ordering-policy.md **D-3** under BOTH
ECO_KERNEL_FACTS_DCE flavors: a sequence of wildcard (`_ =`) logging statements
keeps source order, and no line is duplicated or dropped.

The chain is deliberately wildcard-only. Named `let` bindings are evaluated
before wildcard statements and not in source order among themselves (measured
2026-08-12; see the policy's D-3 note), which Elm leaves unspecified — mixing
the two shapes here would bake that unspecified order into a gate. D-1
non-deletion is pinned separately by DebugLogNoDropTest.elm.

`CHECK-NEXT` pins presence, order, and absence of duplicates in one directive
stream: each constraint must match on the line immediately after the previous
one (test/CheckPatterns.hpp).

-}

-- CHECK: a: "start"
-- CHECK-NEXT: b: "second"
-- CHECK-NEXT: c: "mid"
-- CHECK-NEXT: d: "fourth"
-- CHECK-NEXT: e: "end"

import Html exposing (text)


main : Html.Html msg
main =
    let
        _ =
            Debug.log "a" "start"

        _ =
            Debug.log "b" "second"

        _ =
            Debug.log "c" "mid"

        _ =
            Debug.log "d" "fourth"

        _ =
            Debug.log "e" "end"
    in
    text "done"
