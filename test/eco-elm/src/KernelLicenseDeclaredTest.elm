module KernelLicenseDeclaredTest exposing (main)

{-| Checks `Json.Encode.list` with two different encoder functions, and `String.split` and `String.join` on short strings.

  - `a` and `b` encode the same list `[1,2,3]` with two different encoders,
    one doubling and one negating, so each must produce its own JSON array.
  - `c` splits a string and `d` joins a list of strings.
  - `e` joins the result of a split, and `f` counts the pieces of a split.

## eco

Exercises LSS_022 occurrence verification (design_docs/invariants.csv) for
the kernels whose license is a declared type
(plans/kernel-parametricity-license.md). These kernels have no type annotation
in package source, so the row declares the type and `licenseApplies` in
compiler/src/Compiler/Monomorphize/Solver/KernelSetFacts.elm checks that each
occurrence is an instance of it.

`a` and `b`: `Json.Encode.list` passes the user encoder, partially applied, to
the licensed `Elm.Kernel.Json.addEntry`. Two different encoders cross that one
boundary; if the licensed slot carried a false singleton lambda set, one
encoder's code would run in the other's place and the JSON would differ.

`c` to `f`: `List.fromArray` and `List.toArray`, reached only through
`String.split` and `String.join`, are deliberately not licensed (their
non-List side is an unsolved variable at the only occurrence), so they keep
LSS_004 poison. These lines pin behaviour through the poisoned path and are
the negative control for `a` and `b`; they do not prove more than that.

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
-- CHECK: c: ["a","b","c"]
-- CHECK: d: "x-y-z"
-- CHECK: e: "p-q-r"
-- CHECK: f: 4
