module CompilerIssue1691ContradictoryExtensibleRecordHangTest exposing (main)

{-| A contradictory extensible-record annotation, used point-free.

<https://github.com/elm/compiler/issues/1691>

The program is ill-typed, so it must be rejected with a type error. Elm 0.19.1 instead hangs while
its memory grows without bound (the runner kills it at its compile memory limit), or crashes.

-}

-- COMPILE-ERROR: a type error, not a hang
-- CHECK: {{-- [A-Z ]+ -}}
-- CHECK-NOT: HasCallStack

import Html


type alias FullRecord =
    { fieldA : String
    , fieldB : Maybe String
    }


type alias PartialRecordA a =
    { a | fieldA : String }


type alias PartialRecordB a =
    { a | fieldB : String }


fullRecord : PartialRecordA a -> Maybe (PartialRecordB b) -> FullRecord
fullRecord partialRecordA partialRecordB =
    { fieldA = partialRecordA.fieldA
    , fieldB = Maybe.map .fieldB partialRecordB
    }


combineA : PartialRecordA a -> FullRecord
combineA =
    combineMaybeAB (always Nothing)


combineAB : PartialRecordA (PartialRecordB a) -> FullRecord
combineAB =
    combineMaybeAB Just


combineMaybeAB : (PartialRecordA a -> Maybe (PartialRecordB a)) -> PartialRecordA a -> FullRecord
combineMaybeAB partialSelectorB partialRecordA =
    fullRecord partialRecordA (partialSelectorB partialRecordA)


main =
    Html.text ""
