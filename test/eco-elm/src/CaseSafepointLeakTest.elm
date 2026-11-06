module CaseSafepointLeakTest exposing (main)

{-| Checks that the value of a `case` bound in a `let` can be consed onto a list
in a later binding of the same `let`.

`extract` binds the `String` from `MyOk`, or `fallback` for `MyErr`, and puts it
at the head of `acc`. `extract1` takes the `MyOk` branch and `extract2` the
`MyErr` branch.

## eco

Exercises GC root tracking around `case`: the alternatives create temporary `!eco.value`s, and the cons after the case allocates, so the allocating op carries live-root operands for the enclosing scope. If any of those referenced an SSA value defined inside a case region, the MLIR would fail to parse (a cross-region reference). The test predates the removal of the standalone `eco.safepoint` op; the same hazard now applies to the allocating op's live-roots operands.

-}

-- CHECK: extract1: ["b","a"]
-- CHECK: extract2: ["default","a"]

import Html exposing (text)


type MyResult
    = MyOk String
    | MyErr String


extract : MyResult -> String -> List String -> List String
extract result fallback acc =
    let
        val =
            case result of
                MyOk s ->
                    s

                MyErr _ ->
                    fallback

        newAcc =
            val :: acc
    in
    newAcc


main =
    let
        _ = Debug.log "extract1" (extract (MyOk "b") "default" [ "a" ])
        _ = Debug.log "extract2" (extract (MyErr "oops") "default" [ "a" ])
    in
    text "done"
