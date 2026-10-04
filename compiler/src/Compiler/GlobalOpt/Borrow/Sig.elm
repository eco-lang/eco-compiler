module Compiler.GlobalOpt.Borrow.Sig exposing
    ( BorrowSig
    , ResPos
    , SigTy
    , allOwnedSig
    , optimisticSig
    , sigEq
    , uniformSigTy
    )

{-| Borrow inference analyses one function at a time, and without a summary of
each callee it would have to assume that every call takes ownership of every
argument. This module defines that summary, the borrow signature.

A function's arguments and result are values, and each value has some number of
_heap positions_: the string, list, tuple, record, custom-type value, closure or
`CEcoValue` type variable inside its type, counted in pre-order (the container
before its contents). Scalars (`Int`, `Float`, `Bool`, `Char`, unit and number
type variables) have none. A borrow signature gives each heap position of each
parameter and of the result an access mode, as `Compiler.GlobalOpt.Borrow.Mode`
describes, and says which parameters each result position may alias.

A signature holds only types and modes, not the resource variables of the
analysis that produced it. Modes are matched to positions by index alone. That
works because the types paired at a call are ground and equal, so building
fresh resources from the stored `shape` at a call site, with
`Compiler.GlobalOpt.Borrow.Rty`, numbers the positions in the same order as when
the signature was read back.

Reading a signature back from a solved analysis is done in
`Compiler.GlobalOpt.Borrow`, not here: `Constrain` imports this module and
`Solve` imports `Constrain`, so this module cannot import `Solve`.

-}

import Array exposing (Array)
import Compiler.AST.Monomorphized as Mono
import Compiler.GlobalOpt.Borrow.Mode exposing (Mode(..))
import Dict
import Set exposing (Set)


{-| The index of one heap position within a type, counting from 0 in pre-order.

This is a name for `Int`, not a new type, so the compiler does not check that a
value is in range for the type it is used with.

-}
type alias ResPos =
    Int


{-| The access modes of one value in a signature: its type, and one mode per
heap position of that type.

`shape` is a ground type. `modes` is indexed by `ResPos`, and its length is
expected to equal the type's number of heap positions; nothing checks this.

-}
type alias SigTy =
    { shape : Mono.MonoType
    , modes : Array Mode
    }


{-| The borrow signature of a function: the modes of each parameter in order,
the modes of the result, and which parameters the result may alias.

Each entry of `resultLts` pairs a position of the result with the indices of the
parameters that position may alias. A result position with no entry aliases no
parameter.

-}
type alias BorrowSig =
    { params : List SigTy
    , result : SigTy
    , resultLts : List ( ResPos, Set Int )
    }


{-| Returns the number of heap positions in a type.

The count must agree with the resources `Compiler.GlobalOpt.Borrow.Rty` builds
for the same type, since the mode arrays built here are indexed by them. The
rule is repeated here rather than imported from `Rty`, and nothing checks that
the two agree.

-}
resCount : Mono.MonoType -> Int
resCount ty =
    case ty of
        Mono.MInt ->
            0

        Mono.MFloat ->
            0

        Mono.MBool ->
            0

        Mono.MChar ->
            0

        Mono.MUnit ->
            0

        Mono.MString ->
            1

        Mono.MVar _ Mono.CEcoValue ->
            1

        Mono.MVar _ Mono.CNumber ->
            0

        Mono.MList _ elem ->
            1 + resCount elem

        Mono.MTuple _ ts ->
            1 + List.sum (List.map resCount ts)

        Mono.MRecord _ d ->
            1 + List.sum (List.map resCount (Dict.values d))

        Mono.MCustom _ _ _ args ->
            1 + List.sum (List.map resCount args)

        Mono.MFunction _ _ _ _ ->
            1


{-| Builds the `SigTy` of a type, giving the position at each index the mode
`pick` returns for that index.
-}
sigTyOf : (Int -> Mode) -> Mono.MonoType -> SigTy
sigTyOf pick ty =
    { shape = ty
    , modes = Array.initialize (resCount ty) pick
    }


{-| Builds the `SigTy` of a type with `mode` at every heap position.
-}
uniformSigTy : Mode -> Mono.MonoType -> SigTy
uniformSigTy mode ty =
    sigTyOf (\_ -> mode) ty


{-| Builds the most optimistic signature for a function with the given parameter
and result types: every position `Borrowed`, and a result that aliases no
parameter.
-}
optimisticSig : List Mono.MonoType -> Mono.MonoType -> BorrowSig
optimisticSig paramTys resultTy =
    { params = List.map (sigTyOf (always Borrowed)) paramTys
    , result = sigTyOf (always Borrowed) resultTy
    , resultLts = []
    }


{-| Builds the most pessimistic signature for a function with the given
parameter and result types: every position `Owned`, and a result that aliases no
parameter.
-}
allOwnedSig : List Mono.MonoType -> Mono.MonoType -> BorrowSig
allOwnedSig paramTys resultTy =
    { params = List.map (sigTyOf (always Owned)) paramTys
    , result = sigTyOf (always Owned) resultTy
    , resultLts = []
    }


{-| Returns whether two signatures have the same modes and the same `resultLts`.

Modes are compared position by position, and the number of parameters must
match. Shapes are not compared. `resultLts` is compared as a mapping from
result position to parameter set, in any order; a list that repeats a position
can make two lists that agree as mappings compare unequal, because their
lengths differ.

-}
sigEq : BorrowSig -> BorrowSig -> Bool
sigEq a b =
    (List.length a.params == List.length b.params)
        && List.all identity (List.map2 sigTyEq a.params b.params)
        && sigTyEq a.result b.result
        && resultLtsEq a.resultLts b.resultLts


{-| Returns whether two `SigTy`s have equal modes, ignoring their shapes.
-}
sigTyEq : SigTy -> SigTy -> Bool
sigTyEq a b =
    a.modes == b.modes


{-| Returns whether two `resultLts` lists have the same length and every entry
of `a` is matched by the first entry for the same position in `b`.
-}
resultLtsEq : List ( ResPos, Set Int ) -> List ( ResPos, Set Int ) -> Bool
resultLtsEq a b =
    (List.length a == List.length b)
        && List.all
            (\( pos, s ) ->
                case listLookup pos b of
                    Just t ->
                        s == t

                    Nothing ->
                        False
            )
            a


{-| Returns the value of the first pair in `pairs` whose key is `k`.
-}
listLookup : Int -> List ( Int, a ) -> Maybe a
listLookup k pairs =
    case pairs of
        [] ->
            Nothing

        ( j, v ) :: rest ->
            if j == k then
                Just v

            else
                listLookup k rest
