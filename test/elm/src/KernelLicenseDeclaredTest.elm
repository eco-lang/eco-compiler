module KernelLicenseDeclaredTest exposing (main)

{-| LSS_022 occurrence verification + the three DECLARED-shape licenses
(`plans/kernel-parametricity-license.md`).

Three kernels have no aliasing annotation in package source, so nothing bounds
their occurrence types (`Can.VarKernel` generates `CTrue`). Their rows declare
the type instead, and `KernelSetFacts.licenseApplies` enforces that each
occurrence is an instance of it. This fixture drives the Elm-visible paths that
actually reach them.

**`Json.addEntry` is the one with a functional payload**, and it is the only
one of the three that can have one. `Json.Encode.list` is

    list func entries =
        Elm.Kernel.Json.wrap
            (List.foldl (Elm.Kernel.Json.addEntry func) (Elm.Kernel.Json.emptyArray ()) entries)

so `func` is a user closure crossing the kernel boundary, PARTIALLY APPLIED
(one of three params) — which also exercises §1's "a partial kernel application
needs no arity rule". `a` / `b` below pass two DIFFERENT encoders through that
one boundary: if the licensed slot ever carried a false singleton, one
encoder's code would run in the other's place and the JSON would differ.

**`List.fromArray` / `List.toArray` are NOT licensed**, and `c`-`f` record why.
Their only call sites anywhere are hardcoded in elm/core's `String.elm` --
`split` and `join` -- and `Elm.Kernel.String.split` is itself `CTrue`, so the
type on the non-`List` side of both kernels is an UNSOLVED VARIABLE at the only
occurrence. Measured, not assumed: a declared `Array a -> List a` verifies
against nothing (kernelLicensed unchanged), and the `List a` half alone matched
while `Array` and `JsArray` both failed. With no auditable type basis there is
nothing to license, so R5 stands and these two keep LSS_004 poison. `c`-`f`
therefore pin BEHAVIOUR through the poisoned path -- a regression guard on the
pass-through, and the negative control for `a`/`b` above. Said plainly so nobody
later reads them as proving more than they do.

-}

import Html exposing (text)
import Json.Encode as E


encodeDoubled : Int -> E.Value
encodeDoubled n =
    E.int (n * 2)


encodeNegated : Int -> E.Value
encodeNegated n =
    E.int (negate n)


main : Html.Html msg
main =
    let
        _ =
            Debug.log "a" (E.encode 0 (E.list encodeDoubled [ 1, 2, 3 ]))

        _ =
            Debug.log "b" (E.encode 0 (E.list encodeNegated [ 1, 2, 3 ]))

        _ =
            Debug.log "c" (String.split "," "a,b,c")

        _ =
            Debug.log "d" (String.join "-" [ "x", "y", "z" ])

        _ =
            Debug.log "e" (String.join "-" (String.split "," "p,q,r"))

        _ =
            Debug.log "f" (List.length (String.split "," "1,2,3,4"))
    in
    text "done"



-- CHECK: a: "[2,4,6]"
-- CHECK: b: "[-1,-2,-3]"
-- CHECK: c: ["a", "b", "c"]
-- CHECK: d: "x-y-z"
-- CHECK: e: "p-q-r"
-- CHECK: f: 4
