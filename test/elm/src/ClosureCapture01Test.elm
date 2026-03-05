module ClosureCapture01Test exposing (main)

{-| Test closure captures variable used only in single-ctor destruct.

Uses explicit lambda return (`f w = \dummy -> ...`) to force nested
Function nodes in the TypedOpt AST. The inner lambda captures `w`,
which appears only as the root of a destruct path (MonoRoot).
This triggers the collectVarTypes traversal asymmetry bug.
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
