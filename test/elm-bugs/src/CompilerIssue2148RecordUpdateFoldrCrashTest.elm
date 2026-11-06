module CompilerIssue2148RecordUpdateFoldrCrashTest exposing (main)

{-| A type error in a `List.foldr` over records must be reported normally, not crash the compiler.

<https://github.com/elm/compiler/issues/2148>

Elm 0.19.1 crashes with "Data/Vector/Generic/Mutable.hs:703 (modify): index out of bounds (3,3)"
and "thread blocked indefinitely in an MVar operation". `Model` is `{}`, so `model.a` is a type
error that must be reported normally.

-}

-- COMPILE-ERROR: a type error, not a compiler crash
-- CHECK-NOT: HasCallStack
-- CHECK: {{-- [A-Z ]+ -}}
-- CHECK-NOT: bypassed the normal error reporting

import Html exposing (text)


main =
    text "done"


type alias A =
    { ap1 : String }


type alias B =
    { bp1 : String }


type alias Model =
    {}


f1 : Model -> Model
f1 model =
    let
        ( a, b ) =
            List.foldr
                (\x ( a2, list ) ->
                    case x.d of
                        Nothing ->
                            ( a2, x :: list )

                        Just c ->
                            let
                                c2 =
                                    { c | p1 = c.p1 + 1 }

                                x2 =
                                    { x | c = Just c2 }

                                ( a3, x3 ) =
                                    f2 a2 x2
                            in
                            ( a3, x3 :: list )
                )
                ( model.a, [] )
                model.b
    in
    { model | a = a, b = b }


f2 : A -> B -> ( A, B )
f2 x y =
    ( x, y )
