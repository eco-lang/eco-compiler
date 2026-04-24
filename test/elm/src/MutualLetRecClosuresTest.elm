module MutualLetRecClosuresTest exposing (main)

{-| Stage-6 regression for mutually recursive let-bound closures.

    Two let-bindings reference each other as captures (e.g. `evenP` calls
    `oddP` and vice versa via stored function references). Without the
    compiler's forward-sibling fix, the papCreate for the first binding
    would emit an SSA operand naming the second binding's placeholder
    before the second papCreate is emitted — `eco-boot-native` rejects
    the resulting MLIR with

        error: operand #0 does not dominate this use

    The fix replaces the forward operand with a Unit placeholder and
    emits `eco.closure.patch_capture` after both closures are allocated.

    This pattern is structurally identical to the GLSL-parser's
    `rassocP` / `rassocP1` (and `lassocP` / `lassocP1`) let-bindings in
    `buildExpressionParser`, which was the site triggering the bootstrap
    failure.

-}

-- CHECK: evenResult: True
-- CHECK: oddResult: False
-- CHECK: callsEven: 4
-- CHECK: callsOdd: 3

import Html exposing (text)


classify : Int -> { isEven : Bool, calls : Int }
classify n =
    let
        evenP : Int -> Int -> { result : Bool, steps : Int }
        evenP k counter =
            if k == 0 then
                { result = True, steps = counter }

            else
                oddP (k - 1) (counter + 1)

        oddP : Int -> Int -> { result : Bool, steps : Int }
        oddP k counter =
            if k == 0 then
                { result = False, steps = counter }

            else
                evenP (k - 1) (counter + 1)

        probe =
            evenP n 0
    in
    { isEven = probe.result, calls = probe.steps }


classifyOdd : Int -> { isOdd : Bool, calls : Int }
classifyOdd n =
    let
        evenP : Int -> Int -> { result : Bool, steps : Int }
        evenP k counter =
            if k == 0 then
                { result = True, steps = counter }

            else
                oddP (k - 1) (counter + 1)

        oddP : Int -> Int -> { result : Bool, steps : Int }
        oddP k counter =
            if k == 0 then
                { result = False, steps = counter }

            else
                evenP (k - 1) (counter + 1)

        probe =
            oddP n 0
    in
    { isOdd = not probe.result, calls = probe.steps }


main =
    let
        evenInfo =
            classify 4

        oddInfo =
            classifyOdd 3

        _ =
            Debug.log "evenResult" evenInfo.isEven

        _ =
            Debug.log "oddResult" oddInfo.isOdd

        _ =
            Debug.log "callsEven" evenInfo.calls

        _ =
            Debug.log "callsOdd" oddInfo.calls
    in
    text "done"
