module Compiler.Data.IndexName exposing (fromIndex)

{-| Gives each position in a sequence a short name, for use as the name of a
local variable.

The first 52 positions are named by single letters. The docstring of
`fromIndex` sets out the whole scheme, including where it breaks down for later
positions.

@docs fromIndex

-}

import Compiler.Data.Index as Index
import Compiler.Data.Name as Name


{-| Returns the short name for `index`.

Counting from zero, positions 0 to 25 are named `a` to `z` and positions 26 to
51 `A` to `Z`. From position 52 on a name has two characters, and the scheme
does not hold up there: positions 52 to 77 are `a0` to `z0`, the names of
positions 78 to 103 end in `0` but start with a character that is not a letter
(`{` for 78), and from 104 on different positions can share a name (104 and
130 are both `a1`).

    fromIndex Index.first == "a"

    fromIndex Index.second == "b"

    fromIndex Index.third == "c"

-}
fromIndex : Index.ZeroBased -> Name.Name
fromIndex index =
    fromInt (Index.toMachine index)


{-| Returns the name for the count from zero `n`, by the scheme `fromIndex`
describes.
-}
fromInt : Int -> Name.Name
fromInt n =
    if n < 26 then
        -- lowercase a-z
        Name.fromWords [ Char.fromCode (97 + n) ]

    else if n < 52 then
        -- uppercase A-Z
        Name.fromWords [ Char.fromCode (65 + n - 26) ]

    else
        let
            base =
                n - 52

            first =
                modBy 52 base

            rest =
                base // 52
        in
        if rest == 0 then
            Name.fromWords [ Char.fromCode (97 + first), '0' ]

        else
            Name.fromWords [ Char.fromCode (97 + modBy 26 first), Char.fromCode (48 + modBy 10 rest) ]
