module Tensor.Internal.Names exposing (names)

{-| A list of labels can repeat a label, and a repeated label does not tell its elements apart.
This module turns a list of labels into a list of names, numbering the labels that repeat.

A _label_ is a string in that list. Slot labels are one source, a slot being one tensor input or
output of a signature: a slot made by `Signature` carries `arg` until it is relabelled, for example
by `Signature.label`, and nothing keeps two slots from carrying the same label. A _name_ is what
`names` makes of a label once every `arg` has been replaced by the caller's default, counting
occurrences after that replacement: the label itself where it then occurs once, and the label with
a number appended where it repeats.

-}

import Dict


{-| Returns one name for each of `labels`, in the same order. The names are distinct.

Every `arg` is first replaced by `default`. Then a label that occurs once in the list is its own
name, and a label that occurs more than once is numbered by occurrence, from 0 in list order:
`[ "w", "b", "w" ]` gives `[ "w0", "b", "w1" ]`. Because the replacement comes first, `arg` and
`default` count as one label: `names "x" [ "arg", "x" ]` gives `[ "x0", "x1" ]`.

A number whose name is one of the labels, or a name already given, is skipped, and the next number
is tried: `[ "w", "w", "w1" ]` gives `[ "w0", "w2", "w1" ]`.

-}
names : String -> List String -> List String
names default labels =
    let
        ls =
            List.map
                (\l ->
                    if l == "arg" then
                        default

                    else
                        l
                )
                labels

        counts =
            List.foldl (\l d -> Dict.update l (\c -> Just (Maybe.withDefault 0 c + 1)) d) Dict.empty ls

        repeated l =
            Maybe.withDefault 0 (Dict.get l counts) > 1

        -- Every label that occurs once is its own name, so those names are taken from the start;
        -- a repeated label is never a name itself, but is kept out so that no number gives it.
        taken0 =
            Dict.map (\_ _ -> ()) counts

        free l i taken =
            if Dict.member (l ++ String.fromInt i) taken then
                free l (i + 1) taken

            else
                i

        step l ( next, taken, acc ) =
            if repeated l then
                let
                    i =
                        free l (Maybe.withDefault 0 (Dict.get l next)) taken

                    n =
                        l ++ String.fromInt i
                in
                ( Dict.insert l (i + 1) next, Dict.insert n () taken, n :: acc )

            else
                ( next, taken, l :: acc )

        ( _, _, named ) =
            List.foldl step ( Dict.empty, taken0, [] ) ls
    in
    List.reverse named
