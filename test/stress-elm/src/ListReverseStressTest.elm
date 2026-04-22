module ListReverseStressTest exposing (main)

-- CHECK: ListReverseStressTest: True

import StressHarness exposing (StressFlags)


type alias State =
    { list : List Int
    , original : List Int
    }


seed : StressFlags -> State
seed flags =
    let
        xs =
            List.range 1 flags.maxSize
    in
    { list = xs, original = xs }


{-| Reverse twice per step so the list is guaranteed to match `original`
regardless of the parity of `numLoops`. -}
step : State -> State
step s =
    { s | list = List.reverse (List.reverse s.list) }


check : State -> Bool
check s =
    s.list == s.original


main : Program StressFlags StressHarness.Model StressHarness.Msg
main =
    StressHarness.program
        { label = "ListReverseStressTest"
        , seed = seed
        , step = step
        , check = check
        }
