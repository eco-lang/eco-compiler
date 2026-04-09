module PureRecursiveValueThunkTest exposing (main)

{-| Minimal reproducer: zero-arity top-level self-recursive value.

    The binding `me` is a value (not a function) whose RHS contains a
    lambda that captures `me` itself. In stock Elm/JS this works because
    top-level bindings are lazily memoized. In Eco's native lowering,
    if closure capture eagerly evaluates the captured binding, constructing
    `me` re-evaluates `me`, producing infinite C-stack recursion at init time.

    Expected: prints "ok: ()" without crashing.
-}

-- CHECK: ok: ()

import Html exposing (text)


type Box
    = Box (() -> Box)


me : Box
me =
    Box (\_ -> me)


main =
    let
        _ =
            case me of
                Box _ ->
                    Debug.log "ok" ()
    in
    text "done"
