module CompilerIssue2185PhantomWrapperLetAnnotationTest exposing (main)

{-| The compiler crashes on a valid let annotation with a type variable around a wrapped phantom
type.

<https://github.com/elm/compiler/issues/2185>

`func` (unannotated) has type `Internal a -> Bool`; its `let` annotation `x : Wrapper a` is fine.
Elm 0.19.1 crashes ("You ran into a compiler bug ... a [rank = 2]", Type/Solve.hs:206, then
"thread blocked indefinitely in an MVar operation"). It should compile.

-}

-- CHECK: func: True

import Html exposing (text)


type Wrapper a
    = Wrapper (Internal a)


type Internal a
    = Internal


func internal =
    let
        x : Wrapper a
        x =
            Wrapper internal
    in
    True


main =
    let
        _ =
            Debug.log "func" (func Internal)
    in
    text "done"
