module CoreIssue988NanContainerSelfEqualityTest exposing (main)

{-| Any container holding NaN equals itself, because (==) first checks whether the two sides are
the same object.

<https://github.com/elm/core/issues/988>

NaN is not equal to anything, itself included, so no value holding NaN can be equal to anything.
Elm 0.19.1's `_Utils_eq` returns True as soon as `x === y`, before it looks inside, so a record,
custom type, `Maybe`, `Array`, `Dict` or `Set` compared with itself is True. The shortcut applies
at every level: two separately built tuples holding the same inner NaN tuple are equal too.
(CompilerIssue2362NanTupleEqualityTest covers a tuple, CoreIssue988NanEqualityReferenceTest a
list.)

-}

-- CHECK: record: False
-- CHECK: custom type: False
-- CHECK: maybe: False
-- CHECK: array: False
-- CHECK: dict: False
-- CHECK: set: False
-- CHECK: shared inner tuple: False
-- CHECK: shared inner list: False

import Array
import Dict
import Html exposing (text)
import Set


type Box
    = Box Float


main =
    let
        nan =
            0 / 0

        record =
            { x = nan }

        box =
            Box nan

        maybe =
            Just nan

        array =
            Array.fromList [ nan ]

        dict =
            Dict.fromList [ ( 1, nan ) ]

        set =
            Set.fromList [ nan ]

        inner =
            ( nan, 1 )

        _ =
            Debug.log "record" (record == record)

        _ =
            Debug.log "custom type" (box == box)

        _ =
            Debug.log "maybe" (maybe == maybe)

        _ =
            Debug.log "array" (array == array)

        _ =
            Debug.log "dict" (dict == dict)

        _ =
            Debug.log "set" (set == set)

        _ =
            Debug.log "shared inner tuple" (( inner, 2 ) == ( inner, 2 ))

        _ =
            Debug.log "shared inner list" ([ inner ] == [ inner ])
    in
    text "done"
