module Compiler.IR.Kernel.Abi exposing
    ( suffixSelectingKernels, alwaysPolymorphicModules, comparePair
    , hasAnyFreeVar
    )

{-| What decides which kernel references keep a boxed ABI, independent of how
the ABI type is built. A kernel whose canonical type has no type variable has
one signature; a kernel with a type variable, or any kernel of a module in
`alwaysPolymorphicModules`, has one boxed root implementation. The kernels in
`suffixSelectingKernels` are the exception: a caller may keep the concrete
call-site type, so that a C++ variant can be picked.

`Compiler.Monomorphize.KernelAbi` builds the ABI types from these facts; the
passes before monomorphization use them to decide which kernel references can
be forwarded.


# Kernel Tables

@docs suffixSelectingKernels, alwaysPolymorphicModules, comparePair


# Type Variables

@docs hasAnyFreeVar

-}

import Compiler.Core.TypeIds exposing (MVarId)
import Compiler.IR.Canonical as Can
import Data.Set as EverySet exposing (EverySet)
import Dict



-- ============================================================================
-- CONSTANTS
-- ============================================================================


{-| The kernels, as `( home, name )` pairs, for which a call site may keep its
concrete call-site type instead of the boxed ABI that
`canTypeToMonoType_preserveVars` builds. The exact condition is the callers'. A kernel outside
this set never reaches its `_Int`, `_Float` or `_Char` variant, because by the
time the symbol is chosen the element type is already `CEcoValue`.

Two kinds of kernel are listed. Element-aware container kernels (`List.cons`,
`Json.wrap`, the `JsArray` element kernels, `MVar.put`) use the concrete element
type. Primitive-specialized kernels (the `Utils` comparisons, `Basics.add`,
`sub`, `mul` and `pow`, `String.fromNumber`) have per-type C++ variants.

The symbol choice is `Compiler.GenerateMlir.KernelAbi`'s; where no variant
matches the types (e.g. `Utils.compare` at `String`) the boxed root symbol is
used.

-}
suffixSelectingKernels : EverySet (List String) ( String, String )
suffixSelectingKernels =
    EverySet.fromList comparePair
        [ ( "List", "cons" )
        , ( "Utils", "compare" )
        , ( "Utils", "equal" )
        , ( "Utils", "notEqual" )
        , ( "Utils", "lt" )
        , ( "Utils", "le" )
        , ( "Utils", "gt" )
        , ( "Utils", "ge" )
        , ( "Json", "wrap" )
        , ( "JsArray", "singleton" )
        , ( "JsArray", "push" )
        , ( "JsArray", "unsafeSet" )
        , ( "MVar", "put" )
        , ( "Basics", "add" )
        , ( "Basics", "sub" )
        , ( "Basics", "mul" )
        , ( "Basics", "pow" )
        , ( "String", "fromNumber" )
        ]


{-| The modules whose kernels always get `PreserveVars`, even when the kernel's
type has no type variable. The one member is `Debug`.
-}
alwaysPolymorphicModules : EverySet (List String) String
alwaysPolymorphicModules =
    EverySet.fromList List.singleton [ "Debug" ]


{-| Returns the key under which a `( home, name )` pair is stored in an
`EverySet`, the two strings as a list.
-}
comparePair : ( String, String ) -> List String
comparePair ( a, b ) =
    [ a, b ]



-- ============================================================================
-- FREE TYPE VARIABLES
-- ============================================================================


{-| Returns whether `canType` has any type variable, stopping at the first one
found. It counts exactly what
`Compiler.Monomorphize.KernelAbi.freeVarIds` collects, including a record's
extension variable and both the body and the arguments of a holey alias, so
`hasAnyFreeVar t == not (List.isEmpty (freeVarIds t []))`.
-}
hasAnyFreeVar : Can.Type MVarId -> Bool
hasAnyFreeVar canType =
    case canType of
        Can.TVar _ ->
            True

        Can.TLambda _ from to ->
            hasAnyFreeVar from || hasAnyFreeVar to

        Can.TType _ _ args ->
            List.any hasAnyFreeVar args

        Can.TRecord fields maybeExt ->
            case maybeExt of
                Just _ ->
                    True

                Nothing ->
                    List.any (\( _, Can.FieldType _ t ) -> hasAnyFreeVar t) (Dict.toList fields)

        Can.TTuple a b rest ->
            List.any hasAnyFreeVar (a :: b :: rest)

        Can.TUnit ->
            False

        Can.TAlias _ _ _ (Can.Filled inner) ->
            hasAnyFreeVar inner

        Can.TAlias _ _ args (Can.Holey inner) ->
            hasAnyFreeVar inner || List.any (\( _, t ) -> hasAnyFreeVar t) args
