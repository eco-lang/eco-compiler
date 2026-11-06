module File exposing (main)

{-| A root module named like a module of a dependency crashes the compiler.

<https://github.com/elm/compiler/issues/2135>

This module is called `File`, as is a module of elm/file, a dependency of this project. It is
valid and nothing imports it, but Elm 0.19.1 prints "Success!" and then crashes with "Error from
`File` should have been reported already" (Build.hs:1233), writing no output. (With
`--output=/dev/null` it exits 0 without a word.) It should compile. The issue had a module
`Matrix` and the package jonathanfishbein1/linear-algebra; any package module name does it.

Because of this module, a test of this project cannot `import File`.

-}

-- CHECK: compiled: True

import Html exposing (text)


main =
    let
        _ =
            Debug.log "compiled" True
    in
    text "done"
