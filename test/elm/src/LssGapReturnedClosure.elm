module LssGapReturnedClosure exposing (main)

{-| LSS gap probe — the TWO uncovered position kinds, isolated in one module.

Both are about arrow positions the `pos|` census names by path (`pos|<global>|<path>|<kind>`,
`Monomorphize.posRows`; path syntax `a<n>`=argument n, `r`=result).

**(1) The returned closure — expected `var` at `/r`.** `adder`'s declaredArity is 1,
so LSS_013 stamps only the head arrow (`""`, tautologically `g|adder`) and stops:
arrow declaredArity+1 belongs to the value `adder` PRODUCES, not to `adder`. Nothing
tautological is available there, so the slot is written only if the body-to-signature
tie carries the fact that the body returns `\y -> x + y`. That tie fails ~97.5% of the
time (annotation arrow and body arrow are distinct objects), and the slot then zonks to
`LVar` — never written, no boundary, no widening. The lambda is plainly visible in the
source, which is exactly why `var` (recoverable) and not ⊤ (terminal) is the honest label.

**(2) The kernel-alias head — expected `top` at `""`.** `List.foldl` is a kernel alias,
and `regIdentity` DOES stamp its head: `memberIdForDepth` at d=0 routes through
`kernelAliasOf` to mint `k|List.foldl` (self-compile census: regid|stamped=192,420,
regid|alreadySet=56,745, regid|noId=**0** — nothing is skipped). Yet 2,997 head arrows
read back ⊤ on a self-compile, all owned by kernel-backed names (andThen 899, cons 658,
succeed 303, foldl 144, ...), and head-`var` is exactly 0 — so the stamp is being
DESTROYED downstream, not omitted. LSS_004 poisons every arrow of a kernel crossing
including the alias's own head, whose identity is the one thing that is not in doubt.

Read the outcome with:
ECO_MONO_LSS_REPORT=1 ECO_MONO_LSS_ARROW_CENSUS=1 ... 2>&1 | grep '^pos|'

-}

-- CHECK: returnedClosure: 7
-- CHECK: kernelAliasHead: 6

import Html exposing (text)


{-| declaredArity 1, returning a function: head is stampable, `/r` is not.
-}
adder : Int -> (Int -> Int)
adder x =
    \y -> x + y


{-| Consumes the returned closure, so `/a0` is a real call position.
-}
applyIt : (Int -> Int) -> Int -> Int
applyIt f n =
    f n


{-| Routes a function argument through the `List.foldl` kernel alias.
-}
sumWith : (Int -> Int -> Int) -> List Int -> Int
sumWith f xs =
    List.foldl f 0 xs


main =
    let
        _ =
            Debug.log "returnedClosure" (applyIt (adder 3) 4)

        _ =
            Debug.log "kernelAliasHead" (sumWith (+) [ 1, 2, 3 ])
    in
    text "hello"
