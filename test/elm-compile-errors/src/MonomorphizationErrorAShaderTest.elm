module MonomorphizationErrorAShaderTest exposing (..)

import Html

{-| MONOMORPHIZATION ERROR: a shader.

From `SourceIR.MonoFailsCases` (`unsupportedCases`), the elm-test catalogue of programs
the compiler must reject.

-}

-- COMPILE-ERROR: MONOMORPHIZATION ERROR, a shader
-- CHECK: -- MONOMORPHIZATION ERROR -
-- SKIP-ELM: eco does not support GLSL shaders and rejects them; Elm compiles an unused one
-- CHECK: unsupported: shader

type alias Fn =
    Int -> Int


withShader : Int -> Fn
withShader n =
    let
        h z =
            let
                s =
                    [glsl| attribute vec3 position; void main () { gl_Position = vec4(position, 1.0); } |]
            in
            z + n
    in
    h


testValue =
    withShader 1 2


main =
    Html.text (Debug.toString testValue)
