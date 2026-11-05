module ShaderInLambdasReturnedByCaseTest exposing (..)

{-| Lambdas returned by `case` branches, each building a pair holding a GLSL shader.

From `Compiler.LocalOpt.Typed.ShaderCoverageTest`, an elm-test unit test, which eco
rejects (Elm 0.19.1 compiles it).

-}

-- COMPILE-ERROR: MONOMORPHIZATION ERROR, shader
-- CHECK: -- MONOMORPHIZATION ERROR -
-- CHECK: unsupported: shader
-- SKIP-ELM: eco does not support GLSL shaders and rejects them; Elm 0.19.1 compiles this program

import Basics exposing (..)
import Char exposing (Char)
import Html exposing (text)
import List exposing ((::))
import Maybe exposing (Maybe(..))
import Platform.Cmd as Cmd exposing (Cmd)
import Platform.Sub as Sub exposing (Sub)
import String exposing (String)
import Tuple


testValue =
    Tuple.second (pick 0 1)


pick n =
    case n of
        0 ->
            \p ->
                let
                    k =
                        p + 1
                in
                ( [glsl| attribute vec3 position; void main () { gl_Position = vec4(position, 1.0); } |], k )

        _ ->
            \q ->
                ( [glsl| attribute vec3 position; void main () { gl_Position = vec4(position, 1.0); } |], q )


main =
    let
        _ =
            Debug.log "testValue" testValue
    in
    Html.text "done"
