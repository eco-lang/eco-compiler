module Control.Loop exposing (Step(..))

{-| One type for what a single iteration of a loop decides, so that loops over
different kinds of computation can share it.

A loop of this kind is written as a step function, which a separate driver
applies to a state over and over. After each application the step says either
to go round again with a new state, or to stop with a result. The driver does
the repeating; this module has no functions and defines only that answer.

@docs Step

-}


{-| What one iteration of a loop decides: go round again, or stop.

`Loop` carries the state the next iteration starts from.

`Done` carries the result the loop finishes with.

-}
type Step state a
    = Loop state
    | Done a
