module ModByZeroKernelPathTest exposing (main)

{-| ABI-01 (plans/kernel-lib-bug-fixes.md, group 09): `modBy 0` through the kernel export.

A saturated `modBy m x` is lowered inline (CGEN_084: total, `modBy 0 x == 0`). The triage
expected an unsaturated `modBy`, a `modBy` passed as a value, or `List.map2 modBy` to call
the kernel symbol `Elm_Kernel_Basics_modBy`, whose C++ body (`Basics::modBy`) threw
`std::runtime_error` for a zero modulus; the exception would leave an `extern "C"` function
and end the program in `std::terminate`. Fixed by decision D1: the kernel returns 0, like the
inline lowering.

Phase 1 finding: none of these shapes reaches the kernel symbol. Every use of `modBy`, even
`Basics.modBy` captured in a PAP, compiles to a `Basics_modBy` wrapper whose body is the
`eco.int.modby` intrinsic (Intrinsics.elm), so the program prints the CGEN_084 answers today.
The CHECK-MLIR-NOT line pins that; if a change ever routes one of these calls to
`Elm_Kernel_Basics_modBy`, it fails here and this program becomes the end-to-end witness of
ABI-01. The fix itself is pinned by the C++ case `int-arith/mod-by-zero-returns-zero`
(test/kernel/IntArithTest.cpp), which calls the export directly. Stock Elm crashes on `modBy 0`
(hint 11), so the expected output is eco's documented divergence, not Elm's: SKIP-JS, and
the test lives here, not in elm-conformance.

-}

-- CHECK: inline: 0
-- CHECK: map: [0,0]
-- CHECK: value: 0
-- CHECK: map2: [0,1]
-- CHECK-MLIR-NOT: Elm_Kernel_Basics_modBy
-- SKIP-JS: elm/core crashes on modBy 0 (hint 11); eco's total division is a deliberate divergence (CGEN_084)


import Html exposing (text)


{-| Picks one of several Int functions by an index known only at run time, so the inliner
cannot see which one is called and saturate `modBy` at the call.
-}
pick : Int -> (Int -> Int -> Int)
pick i =
    case List.head (List.drop i [ modBy, remainderBy, (+) ]) of
        Just f ->
            f

        Nothing ->
            (*)


applyTo : (Int -> Int -> Int) -> Int -> Int -> Int
applyTo f a b =
    f a b


main =
    let
        zero =
            List.length []

        _ =
            Debug.log "inline" (modBy zero 5)

        _ =
            Debug.log "map" (List.map (modBy zero) [ 5, -3 ])

        _ =
            Debug.log "value" (applyTo (pick zero) zero 7)

        _ =
            Debug.log "map2" (List.map2 modBy [ zero, 4 ] [ 9, -7 ])
    in
    text "done"
