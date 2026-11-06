module LssVerbatimCopiesFastDispatchTest exposing (main)

{-| A polymorphic function that passes a capturing lambda to a recursive higher-order function gives each call its own captured value.

`runWith` ignores its first argument, whose type is a type variable, and calls
`applyN (\x -> x + start) 3 start`, which adds `start` three times to itself. `runWith` is used
at two types, `String` with `start` = 1 and `Float` with `start` = 10, giving 4 and 40.

## eco

Exercises verbatim-copy representative stamping in lambda-set specialization
(plans/lss-lambda-set-specialization.md). `runWith` is polymorphic in a parameter the lambda never
uses, so its two specializations each contain a verbatim copy of the capturing lambda: the same
source lambda and layout, but distinct lambda ids. The shared `applyN` specialization's `f acc`
call sees a singleton set with two instances, which AbiCloning
(compiler/src/Compiler/MonoOpt/AbiCloning.elm) may upgrade using either copy as representative,
since they are interchangeable. Captured values differ per closure (1 and 10) and the fast clone
loads them from the closure, so the output must be the same with lambda-set specialization on or off.

-}

-- CHECK: first: 4
-- CHECK: second: 40

import Html exposing (text)


applyN : (Int -> Int) -> Int -> Int -> Int
applyN f n acc =
    if n <= 0 then
        acc

    else
        applyN f (n - 1) (f acc)


runWith : a -> Int -> Int
runWith _ start =
    applyN (\x -> x + start) 3 start


main =
    let
        _ =
            Debug.log "first" (runWith "one" 1)

        _ =
            Debug.log "second" (runWith 2.0 10)
    in
    text "done"
