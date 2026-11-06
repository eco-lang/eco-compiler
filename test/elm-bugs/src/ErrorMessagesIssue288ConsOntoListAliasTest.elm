module ErrorMessagesIssue288ConsOntoListAliasTest exposing (main)

{-| Consing an element of the wrong type onto a value whose type is an alias of a List
(`type alias ListOfInts = List Int`) produces a second report claiming the alias is not a list.

<https://github.com/elm/error-message-catalog/issues/288>

Elm 0.19.1 reports, besides the real mismatch (a String consed onto a List Int), "The (::)
operator can only add elements onto lists ... This `list` value is a: ListOfInts ... But (::)
needs a List on the right." `ListOfInts` is a List, so that claim is false.

-}

-- COMPILE-ERROR: String consed onto an alias of List Int
-- CHECK: -- TYPE MISMATCH -
-- CHECK-NOT: needs a List on the right

import Html exposing (text)


type alias ListOfInts =
    List Int


sscce : ListOfInts -> ListOfInts
sscce list =
    "oops" :: list


main =
    text (String.fromInt (List.length (sscce [ 1 ])))
