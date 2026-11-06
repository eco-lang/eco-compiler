module MutualLetRecClosuresTest exposing (main)

{-| Two `let`-bound functions that call each other (`evenP` and `oddP`) are mutually recursive, and each returns a record holding a Bool result and a step count.

Each step decrements `k` and increments `counter`; `evenP` returns `True` and
`oddP` returns `False` when `k` reaches `0`.

  - `classify 4` starts at `evenP 4`, ends in `evenP 0` after 4 steps, and
    reports `isEven = True`, `calls = 4`.
  - `classifyOdd 3` starts at `oddP 3`, ends in `evenP 0` after 3 steps, so the
    probe result is `True` and `isOdd`, its negation, is `False`.

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
