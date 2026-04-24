module DictDiffFoldlStress exposing (main)

{-| Stress test: Dict.diff + Dict.foldl with a long-lived base Dict.

Targets the Stage 7 bootstrap crash signature (2026-04-24): unbounded
recursion in Dict.foldl invoked from Dict.diff inside Builder.Build during
native self-compile. Evidence suggested a Dict node three levels deep had
`left = 0` (null HPointer) after major GCs — hinting at either a Dict
constructor codegen bug or a compacting-GC bug that nulled a child pointer.

Strategy:
  * One base Dict of 8000 String-keyed entries, built ONCE and kept live
    across all 200 rounds. It survives every minor GC and gets promoted
    into old gen, so any compacting-GC bug that fails to update its
    child pointers will corrupt it.
  * Each round allocates millions of transient RBNodes (rebuild + diff +
    replay) around the persistent Dict, forcing repeated major GCs that
    move old-gen objects — precisely the condition under which a missed
    pointer update would surface.
  * After each round, re-fold the persistent base Dict and compare to a
    precomputed checksum. If any child pointer becomes null, Dict.foldl
    will diverge (→ SIGSEGV via stack overflow) with the defensive
    eco_get_tag assert, or return a wrong checksum.

-}

-- CHECK: ok: True

import Dict exposing (Dict)
import Html exposing (text)


n : Int
n =
    4000


rounds : Int
rounds =
    200


keyOf : Int -> String
keyOf i =
    "Compiler.Reporting.Submodule."
        ++ String.fromInt (remainderBy 7 i)
        ++ "."
        ++ String.fromInt (remainderBy 13 i)
        ++ "."
        ++ String.fromInt i


buildDict : Int -> Int -> Dict String Int -> Dict String Int
buildDict lo hi acc =
    if lo > hi then
        acc

    else
        buildDict (lo + 1) hi (Dict.insert (keyOf lo) lo acc)


{-| Allocation-heavy rebuild: throws away the previous Dict and constructs
a fresh one via foldl+insert. Used to generate GC pressure.
-}
rebuild : Dict String Int -> Dict String Int
rebuild d =
    Dict.foldl (\k v acc -> Dict.insert k (v + 1) acc) Dict.empty d


checksum : Dict String Int -> Int
checksum =
    Dict.foldl (\_ v acc -> acc + v) 0


{-| Re-fold the long-lived base Dict every round. If the GC (or a codegen
bug) ever corrupts one of its child pointers to null, this fold will
either diverge (SIGSEGV) or return the wrong answer.
-}
loop :
    Int
    -> Dict String Int -- persistent base — never reassigned
    -> Dict String Int -- persistent remove-set
    -> Int -- expected base checksum
    -> Int -- expected diff size
    -> Int -- expected diff checksum
    -> Bool
    -> Bool
loop count base removed expectedBaseSum expectedDiffSize expectedDiffSum ok =
    if count <= 0 then
        ok

    else
        let
            -- Re-verify the persistent base Dict itself each round.
            baseSum =
                checksum base

            baseOk =
                Dict.size base == n && baseSum == expectedBaseSum

            -- Transient allocation: rebuild base (GC churn).
            rebuilt =
                rebuild base

            -- Dict.diff — the exact operation that crashed stage 7.
            diffed =
                Dict.diff rebuilt removed

            diffSum =
                checksum diffed

            diffSizeOk =
                Dict.size diffed == expectedDiffSize

            diffSumOk =
                diffSum == expectedDiffSum

            -- Fold the persistent removed-set too, for extra traversal.
            removedSum =
                checksum removed

            removedOk =
                removedSum == List.sum (List.range 1 (Dict.size removed))

            roundOk =
                baseOk && diffSizeOk && diffSumOk && removedOk
        in
        loop (count - 1)
            base
            removed
            expectedBaseSum
            expectedDiffSize
            expectedDiffSum
            (ok && roundOk)


main =
    let
        -- Built ONCE — kept live across all rounds via the `loop` arg.
        base =
            buildDict 1 n Dict.empty

        -- Remove-set is also persistent (smaller).
        removed =
            buildDict 1 (n // 2) Dict.empty

        expectedBaseSum =
            List.sum (List.range 1 n)

        expectedDiffSize =
            n - (n // 2)

        -- After rebuild, every value is v+1. Diff removes keys 1..n/2, so
        -- the remaining values in `diffed` are (n/2+1)+1 ... n+1.
        expectedDiffSum =
            List.sum (List.map (\i -> i + 1) (List.range (n // 2 + 1) n))

        ok =
            loop rounds base removed expectedBaseSum expectedDiffSize expectedDiffSum True

        _ =
            Debug.log "ok" ok
    in
    text "done"
