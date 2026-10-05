module UserBoolNamedCtorTest exposing (main)

{-| A program's own constructors named `True` / `False` are ordinary
constructors, not the built-in Bool singletons.

`Compiler.Data.CtorTag.isEmbeddedConstantCtor` (used by
`Compiler.Generate.MLIR.Patterns.testToTagInt`, `Functions.generateCtor` /
`generateEnum` and the spec maps in `Backend.elm`) must recognise `True`,
`False` and `Nothing` by home module (elm/core `Basics` / `Maybe`) as well as
name. Matched by bare name, `Tri.True` and `Tri.False` both got the reserved
constant tag in `eco.case` (tags [65533, 65533, 0] instead of [0, 1, 2]) and
lowering failed with `'scf.index_switch' op has duplicate case value: 65533`.

(A program's own `Nothing` was matched by name too, but consistently: it was
the shared empty constant and dispatched on the reserved tag, so it behaved.)
-}

-- CHECK: pickTrue: 1
-- CHECK: pickFalse: 2
-- CHECK: pickUnknown: 3
-- CHECK: names: ["T", "F", "U"]

import Html exposing (text)


type Tri
    = True
    | False
    | Unknown


pick : Tri -> Int
pick t =
    case t of
        True ->
            1

        False ->
            2

        Unknown ->
            3


name : Tri -> String
name t =
    case t of
        True ->
            "T"

        False ->
            "F"

        Unknown ->
            "U"


tris : List Tri
tris =
    [ True, False, Unknown ]


main =
    let
        _ =
            Debug.log "pickTrue" (pick True)

        _ =
            Debug.log "pickFalse" (pick False)

        _ =
            Debug.log "pickUnknown" (pick Unknown)

        _ =
            Debug.log "names" (List.map name tris)
    in
    text "done"
