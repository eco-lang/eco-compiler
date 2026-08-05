module Compiler.GlobalOpt.Borrow.Sig exposing
    ( BorrowSig, SigTy, ResPos
    , optimisticSig, allOwnedSig, sigEq
    , uniformSigTy
    )

{-| Interprocedural borrow signatures (design §11). A `BorrowSig` summarises a
def's per-position access modes so callers can stop treating direct calls as
all-owned poison.

Position convention: a `SigTy` carries modes positionally, indexed by the
pre-order mint order of `freshRTy`/`Rty.allRes` (§7.3). Sound because every
pairing site zips *ground, equal* MonoTypes, so re-minting `freshRTy` from
`shape` at a call site reproduces the same resource ordering. Signatures are
pure data — no ResVars stored.

`readbackSig` (which reads a solved state) lives in the `Borrow` driver, not
here, to keep `Sig` free of a `Solve` import (`Constrain` imports `Sig`, and
`Solve` imports `Constrain`).

-}

import Array exposing (Array)
import Compiler.AST.Monomorphized as Mono
import Compiler.GlobalOpt.Borrow.Mode exposing (Mode(..))
import Dict
import Set exposing (Set)


type alias ResPos =
    Int


type alias SigTy =
    { shape : Mono.MonoType -- ground; freshRTy re-mints at use sites
    , modes : Array Mode -- indexed by ResPos (pre-order of Rty.allRes)
    }


type alias BorrowSig =
    { params : List SigTy
    , result : SigTy
    , resultLts : List ( ResPos, Set Int ) -- result position → LParams set
    }


{-| Count the pre-order resources of a MonoType (must match `Rty.allRes`
length exactly — every §7.2 heap position mints one ResVar). Kept here so
`optimisticSig`/`allOwnedSig` can size mode arrays without importing `Rty`
(which would pull `Dict`/`Name`); the shape recursion mirrors `Rty.freshRTy`.
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


sigTyOf : (Int -> Mode) -> Mono.MonoType -> SigTy
sigTyOf pick ty =
    { shape = ty
    , modes = Array.initialize (resCount ty) pick
    }


{-| A `SigTy` whose every resource carries `mode` (used by B3.5 standalone
adapters: kernel/ctor/accessor sigs built from a callee type).
-}
uniformSigTy : Mode -> Mono.MonoType -> SigTy
uniformSigTy mode ty =
    sigTyOf (\_ -> mode) ty


{-| params all-`Borrowed`, result all-`Borrowed`, `resultLts = []` (§11.1
"params Borrowed with fresh α, results LParams ∅").
-}
optimisticSig : List Mono.MonoType -> Mono.MonoType -> BorrowSig
optimisticSig paramTys resultTy =
    { params = List.map (sigTyOf (always Borrowed)) paramTys
    , result = sigTyOf (always Borrowed) resultTy
    , resultLts = []
    }


{-| The poison/baseline sig: every mode `Owned`, `resultLts = []`. Used for
ports/extern/manager nodes and the non-convergence bailout.
-}
allOwnedSig : List Mono.MonoType -> Mono.MonoType -> BorrowSig
allOwnedSig paramTys resultTy =
    { params = List.map (sigTyOf (always Owned)) paramTys
    , result = sigTyOf (always Owned) resultTy
    , resultLts = []
    }


{-| Convergence test: positional equality of every `modes` array + set-equality
of `resultLts` (shapes are fixed across iterations; skip comparing them).
-}
sigEq : BorrowSig -> BorrowSig -> Bool
sigEq a b =
    (List.length a.params == List.length b.params)
        && List.all identity (List.map2 sigTyEq a.params b.params)
        && sigTyEq a.result b.result
        && resultLtsEq a.resultLts b.resultLts


sigTyEq : SigTy -> SigTy -> Bool
sigTyEq a b =
    a.modes == b.modes


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
