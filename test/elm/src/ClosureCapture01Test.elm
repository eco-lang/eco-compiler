module ClosureCapture01Test exposing (main)

{-| A lambda returned from a function captures a single-constructor custom-type
argument and unwraps it with `case` when called.

`unwrapLater` takes a `Wrapper Int` and returns a lambda that ignores its own
argument and pattern matches on the captured wrapper. The wrapper is used only
as the subject of that `case`. Applied to `Wrap 42` and `Wrap 99`, the lambdas
return 42 and 99.

-}

-- CHECK: unwrap1: 42
-- CHECK: unwrap2: 99

import Html exposing (text)


type Wrapper a
    = Wrap a


unwrapLater : Wrapper Int -> (Int -> Int)
unwrapLater w =
    \dummy ->
        case w of
            Wrap x ->
                x


main =
    let
        _ = Debug.log "unwrap1" (unwrapLater (Wrap 42) 0)
        _ = Debug.log "unwrap2" (unwrapLater (Wrap 99) 0)
    in
    text "done"
