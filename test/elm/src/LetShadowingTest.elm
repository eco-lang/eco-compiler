module LetShadowingTest exposing (main)

{-| Test nested let bindings with variable shadowing. -}

-- CHECK: outer: 1
-- CHECK: inner: 2
-- CHECK: afterInner: 1
-- CHECK: deep: 3
-- CHECK: param_shadow: 20

import Html exposing (text)


useShadow x =
    let
        y = x * 2
        result =
            let
                y = x * 4
            in
            y
    in
    result


main =
    let
        x = 1
        _ = Debug.log "outer" x
        result =
            let
                x = 2
            in
            x
        _ = Debug.log "inner" result
        _ = Debug.log "afterInner" x
        deep =
            let
                a = 1
            in
            let
                a = 2
            in
            let
                a = 3
            in
            a
        _ = Debug.log "deep" deep
        _ = Debug.log "param_shadow" (useShadow 5)
    in
    text "done"
