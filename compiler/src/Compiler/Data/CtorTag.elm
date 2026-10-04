module Compiler.Data.CtorTag exposing
    ( effective
    , checkNullConsCapacity, constantTag, embedsAsNullCons, isEmbeddedConstantCtor
    )

{-| The tag a constructor carries at run time must be worked out the same way
wherever a value is built and wherever one is matched, and must agree with
numbers fixed in the C++ runtime, so the rules for it live here.

A constructor's runtime tag is the number a value carries to say which of its
type's constructors built it. For most constructors it is the zero-based
position at which the constructor is declared in its type, its declaration
index. The exception is a reserved tag: a value at the top of the 16-bit range
the runtime keeps tags in, which the runtime recognises and treats specially.
The one reserved tag given to a constructor is 0xFFFF, for `elm/core`'s
`Dict.RBNode_elm_builtin`, so that the runtime compares two dictionaries by
their contents in key order rather than by the shape of their trees.
`effective` computes the tag.

A nullary constructor, one with no fields, needs no heap object. It can be
represented by a single word marked as a constant that holds the constructor's
declaration index in a 10-bit field, which is called a null-cons constant.
`embedsAsNullCons` says which nullary constructors are represented this way,
and `checkNullConsCapacity` stops the compile for one whose index does not fit.

`Nothing`, `True` and `False` are not null-cons constants. Each is a fixed
constant word, and `isEmbeddedConstantCtor` picks them out. `Nothing` shares its
word with the other empty values, such as `()` and `[]`, so its value cannot
say which constructor it is, and the runtime reports `constantTag` as the tag
of that shared word. `isEmbeddedConstantCtor` and `embedsAsNullCons` go by the
constructor's name alone, not by the module that declares it.

The numbers here must equal the runtime's: 0xFFFF its `CTOR_DICT_RBNODE`,
0xFFFD its `CONSTANT_TAG`, and 1023 its `NULL_CONS_MAX`. Nothing in the compiler
checks that they agree.

@docs effective
@docs checkNullConsCapacity, constantTag, embedsAsNullCons, isEmbeddedConstantCtor

-}

import Compiler.Data.Index as Index
import Compiler.Data.Name exposing (Name)
import Compiler.Elm.ModuleName as ModuleName
import Utils.Crash exposing (crash)



-- ============================================================================
-- ====== RESERVED CTOR TAGS ======
-- ============================================================================


{-| The reserved runtime tag of `elm/core`'s `Dict.RBNode_elm_builtin`, the
constructor of a node in a dictionary's tree. It must equal the runtime's
`CTOR_DICT_RBNODE`.

`RBEmpty_elm_builtin`, the empty dictionary, has no reserved tag. It is
nullary, so it is a null-cons constant carrying its declaration index like other
nullary constructors.

-}
dictRBNode : Int
dictRBNode =
    0xFFFF


{-| The runtime tag reported for the shared empty constant word, which
`Nothing` uses along with `()`, `{}`, `[]` and `""`. Those values cannot be
told apart by their word, so they all report this one tag. It must equal the
runtime's `CONSTANT_TAG`.
-}
constantTag : Int
constantTag =
    0xFFFD


{-| Returns whether `name` is `Nothing`, `True` or `False`, the constructors
represented by a fixed constant word rather than a null-cons constant. `Nothing`
uses the shared empty word, and `True` and `False` the Bool constants. The test
is by name alone, so a constructor with one of these names in any module counts.
-}
isEmbeddedConstantCtor : Name -> Bool
isEmbeddedConstantCtor name =
    name == "Nothing" || name == "True" || name == "False"



-- ============================================================================
-- ====== NULL-CONS EMBEDDING ======
-- ============================================================================


{-| The largest declaration index a null-cons constant can hold. The index
occupies a 10-bit field of the word, so this is 2^10 - 1. It must equal the
runtime's `NULL_CONS_MAX`.
-}
nullConsCapacity : Int
nullConsCapacity =
    1023


{-| Returns whether the nullary constructor `name` is represented as a
null-cons constant, which it is unless `isEmbeddedConstantCtor` picks it out.
The tag argument is ignored.
-}
embedsAsNullCons : Name -> Bool
embedsAsNullCons name =
    not (isEmbeddedConstantCtor name)


{-| Returns `tag` unchanged when it fits in a null-cons constant, that is when
it is at most `nullConsCapacity`. A larger `tag` stops the compile with an
error naming the constructor `name` and its index.
-}
checkNullConsCapacity : Name -> Int -> Int
checkNullConsCapacity name tag =
    if tag > nullConsCapacity then
        crash
            ("nullary constructor '"
                ++ name
                ++ "' has declaration index "
                ++ String.fromInt tag
                ++ ", exceeding the 10-bit HPointer null_cons_idx capacity ("
                ++ String.fromInt nullConsCapacity
                ++ "); widen the field using the padding bits — see "
                ++ "plans/null-cons-hpointer-embedding.md §2.2"
            )

    else
        tag



-- ============================================================================
-- ====== TAG COMPUTATION ======
-- ============================================================================


{-| Returns the runtime tag of the constructor `name`, declared at position
`index` in a type of module `home`. This is the declaration index, except for
`Dict.RBNode_elm_builtin` in `elm/core`, which gets the reserved tag 0xFFFF.

For `Nothing` the result is still its declaration index, although at run time a
`Nothing` reports `constantTag`.

-}
effective : ModuleName.Canonical -> Name -> Index.ZeroBased -> Int
effective home name index =
    if home == ModuleName.dict then
        if name == "RBNode_elm_builtin" then
            dictRBNode

        else
            Index.toMachine index

    else
        Index.toMachine index
