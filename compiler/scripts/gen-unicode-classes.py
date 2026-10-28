"""Generates compiler/src/Compiler/Parse/Unicode.elm, the Unicode letter
classes the parser uses for identifiers beyond ASCII.

    python3 compiler/scripts/gen-unicode-classes.py > compiler/src/Compiler/Parse/Unicode.elm

Its output is already in elm-format's layout.

The Unicode version is that of the running Python's `unicodedata`.
"""
import unicodedata, sys
def ranges(cats):
    out=[];start=None
    for cp in range(0x80,0x110000):
        ok = unicodedata.category(chr(cp)) in cats
        if ok and start is None: start=cp
        if not ok and start is not None: out.append((start,cp-1)); start=None
    if start is not None: out.append((start,0x10FFFF))
    return out
def hexlit(v):
    # elm-format's layout of a hex literal: 2, 4 or 8 digits.
    digits = 2 if v <= 0xFF else 4 if v <= 0xFFFF else 8
    return "0x%0*X" % (digits, v)
def emit(name, doc, rs):
    body="\n        , ".join("( %s, %s )"%(hexlit(lo),hexlit(hi)) for lo,hi in rs)
    return f'''{{-| {doc}
-}}
{name} : Array ( Int, Int )
{name} =
    Array.fromList
        [ {body}
        ]
'''
U=ranges({'Lu','Lt'}); L=ranges({'Ll'}); A=ranges({'Lu','Ll','Lt','Lm','Lo'})
print(len(U),len(L),len(A),file=sys.stderr)
print(f'''module Compiler.Parse.Unicode exposing (isUpper, isLower, isAlpha)

{{-| Unicode letter classes for code points at or above U+0080, as GHC's
`Data.Char` gives them and as upstream Elm's `Parse.Variable` uses them:
`isUpper` is general category Lu or Lt, `isLower` is Ll, `isAlpha` is any
letter category (Lu, Ll, Lt, Lm, Lo). ASCII is the caller's job. Surrogates
(Cs) are in no class.

Generated from Unicode {unicodedata.unidata_version} by `compiler/scripts/gen-unicode-classes.py`;
do not edit by hand. Upstream Elm takes its classes from the GHC that built it,
so a letter assigned in a later Unicode version than that GHC knows may be
accepted here and rejected there.

@docs isUpper, isLower, isAlpha

-}}

import Array exposing (Array)


{{-| Returns whether the code point is an uppercase or titlecase letter (Lu, Lt).
-}}
isUpper : Int -> Bool
isUpper code =
    inRanges upperRanges code


{{-| Returns whether the code point is a lowercase letter (Ll).
-}}
isLower : Int -> Bool
isLower code =
    inRanges lowerRanges code


{{-| Returns whether the code point is a letter of any category (Lu, Ll, Lt, Lm, Lo).
-}}
isAlpha : Int -> Bool
isAlpha code =
    inRanges alphaRanges code


{{-| Returns whether `code` is in one of the ranges of `table`, a sorted array of
inclusive `( lo, hi )` ranges, by binary search.
-}}
inRanges : Array ( Int, Int ) -> Int -> Bool
inRanges table code =
    search table code 0 (Array.length table - 1)


{{-| Searches the ranges at indices `lo` to `hi` (inclusive) of `table` for one
containing `code`.
-}}
search : Array ( Int, Int ) -> Int -> Int -> Int -> Bool
search table code lo hi =
    if lo > hi then
        False

    else
        let
            mid : Int
            mid =
                (lo + hi) // 2

            ( rlo, rhi ) =
                Maybe.withDefault ( 0, -1 ) (Array.get mid table)
        in
        if code < rlo then
            search table code lo (mid - 1)

        else if code > rhi then
            search table code (mid + 1) hi

        else
            True


{emit("upperRanges","Lu and Lt ranges.",U)}

{emit("lowerRanges","Ll ranges.",L)}

{emit("alphaRanges","Lu, Ll, Lt, Lm and Lo ranges.",A)}''', end="")
