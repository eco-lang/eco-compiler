module CapturedStagedFuncCallTest exposing (main)

{-| Test: captured staged function applied to multiple args in a closure.

Reproduces a bug where annotateExprCalls doesn't add closure params to
varSourceArity, so a captured function parameter's arity falls back to
firstStageArityFromType, which returns only the first-stage arity.
When the function is staged (returns a function), only the first arg
is applied and subsequent args are silently dropped.
-}

-- CHECK: direct: 15
-- CHECK: viaCapture: 15

import Html exposing (text)


{-| Staged function: takes one arg, returns a function. -}
makeAdder : String -> (Int -> Int)
makeAdder key =
    \value -> String.length key + value


{-| Apply a captured 2-arg function via a wrapper closure.
The inner lambda captures 'f' and applies it to both a and b.
-}
applyBoth : (String -> Int -> Int) -> String -> Int -> Int
applyBoth f a b =
    let
        go () =
            f a b
    in
    go ()


main =
    let
        _ =
            Debug.log "direct" (makeAdder "hello" 10)

        _ =
            Debug.log "viaCapture" (applyBoth makeAdder "hello" 10)
    in
    text "done"
