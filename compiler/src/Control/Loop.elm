module Control.Loop exposing (Step(..))

{-| Shared loop step type for stack-safe monadic iteration.

@docs Step

-}


{-| Represents a step in a looping computation.

  - `Loop state`: Continue iterating with the given state
  - `Done a`: Terminate and return the result

-}
type Step state a
    = Loop state
    | Done a
