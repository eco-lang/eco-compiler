module DebugLogNoDropTest exposing (main)

{-| Pins design_docs/debug-log-ordering-policy.md **D-1** under BOTH
ECO_KERNEL_FACTS_DCE flavors: an expression that transitively contains a
`Debug.*` reference is never droppable, however droppable the outer kernel is.

`deadLogged` is a DEAD binding — nothing reads it — whose bound expression is
`String.length` applied to a LOGGING argument. `(String, length)` IS droppable
in the KernelFacts table, so the outer call alone would license deletion; what
must stop it is the argument recursion, because `(Debug, log)` carries
`EffObservableIO` ⇒ `cseSafe = False` ⇒ `droppable = False`. If a future
widening drops the binding, the `kept: "logged"` line vanishes and this fails.

`deadPure` is the negative control: dead, droppable, no Debug, so flag-on it
DOES disappear. That is invisible in the output by design — the observable is
the `kernelLetDCE` counter under ECO_INLINE_REPORT=1.

No ordering is asserted. This fixture has one named binding and one wildcard,
and their relative order is unspecified (policy D-3 note); DebugLogOrderingTest
pins ordering over a wildcard-only sequence instead.

-}

-- CHECK: kept: "logged"

import Html exposing (text)


main : Html.Html msg
main =
    let
        deadLogged =
            String.length (Debug.log "kept" "logged")

        deadPure =
            String.length "xyz"
    in
    text "done"
