module Compiler.MonoSolver.KernelSetFacts exposing
    ( ParamSetFlow(..), KernelPlan, LicenseScope(..), TypeShape(..), License, KernelSetFact(..)
    , factFor, licenseApplies, shapeOfAnnotation, licensedFiles, rows
    )

{-| The solver's lambda-set analysis cannot see inside a kernel, and this module
is the audited table that says, kernel by kernel, how function values move
through one.

A kernel is a runtime function written in C++ rather than Elm, referred to in
Elm as `Elm.Kernel.Home.name` or `Eco.Kernel.Home.name`. Lambda-set
specialization (LSS) records, for each function-typed position in the program,
the set of function values that can reach it, its _members_. A position whose
set has exactly one member can be called directly. Because a kernel's body is
invisible to the analysis, the default treatment of a kernel call is to
_poison_ it: the lambda set of every function-typed position of the call is set
to ⊤, meaning unknown. Poison is always sound. This table says where it can be
skipped or narrowed.

A _function-capable_ position is one that could hold a function value: an
arrow, an extensible record, or a type variable, except one constrained to
`number` or `comparable`, whose values never contain a function.

`factFor` looks a kernel up by its home module and name, and the answer is one
of three:

  - A `TypeFaithful` row carries a _license_: an audited claim that function
    values cross the kernel only along the type variables its Elm type shares,
    that the kernel keeps nothing from one call for a later one, and that it
    creates no function values of its own. Under a license nothing is
    poisoned. Instantiating the kernel's type and unifying it with the call
    carries the members, because the shared type variables are the paths they
    take. A license names no positions, so partial and over-applied calls need
    no special treatment. Its `LicenseScope` says what must still be checked
    about the type at each occurrence, and `licenseApplies` checks it.
  - A `Positional` row gives, for a kernel that holds no license, a
    `ParamSetFlow` for each parameter and for the result. `Bytes.decode` is
    the only one.
  - No row means a call to the kernel is fully poisoned.

Removing poison is the safe direction. A lambda-set slot that nothing writes
reads back as an unresolved set variable, never as an empty set
(`Compiler.MonoSolver.Store` states the read-back rules), so a licensed
position that receives no flow loses nothing. The one hazard is a set that is
populated but incomplete: members flow in from the caller, the kernel adds or
reroutes a function value its type does not account for, and a one-member set
then names the wrong function, which becomes a wrong direct call. A wrong
license therefore miscompiles, while a missing one only costs precision, and an
audit in doubt gives the kernel a `Positional` row or none.


## What rules a license out

Three properties of a kernel refuse it a license.

1.  **Retention across calls.** A value stored by one call is read by a
    different call, so no type variable of either call names the path it
    takes. `Platform.sendToApp` and `sendToSelf` put a message in a mailbox
    that a later call delivers, and `MVar.read` and `take` return what an
    earlier `put` stored. Storing a value in the result the same call returns
    is not retention: `Scheduler.succeed f` returns a task holding `f`, the
    scheduler reads it back out of that task, and `a` in `a -> Task x a`
    carries the flow just as it does for `JsArray.singleton`.

2.  **Erasure into an opaque type with no parameters.** `Json.wrap` retypes
    any value as `Value`, and `Debugger.unsafeCoerce : a -> b` relates two
    unshared variables, so no type describes where their argument goes.

3.  **Function values the kernel creates.** A closure the kernel builds and
    hands back at a position its type can see has no member the analysis
    knows of.

None of `VirtualDom`, `Browser` or `Debug` has a row: `VirtualDom` keeps
nodes and taggers in runtime storage, and `Debug` is lowered specially by the
compiler.

`Compiler.GlobalOpt.KernelFacts` is a separate table about the same kernels,
recording effects, allocation and borrow modes. Neither table is evidence for
the other.


## Audit records

Every row carries an `evidence` string recording its audit as fields separated
by `|`. A license's record includes `class`, `entry` (the C++ entry point),
`type` (the Elm type audited), `B1` (how function values move through the
kernel), `B2` (what it stores outside its result), `B3` (whether it allocates
a closure) and `audited` (when the audit was done). The class is `vacuous` when
the type has no function-capable position. `cheap` and `full` are the
auditor's recorded judgement of the rest, and do not follow from the arrows in
the type. A license is `Inert` exactly when its class is `vacuous`.

A license also lists the C++ files its audit read.
`kernel-license-manifest.txt`, beside this module, pins a SHA-256 hash of each,
and `test/scripts/check-kernel-license-manifest.sh` compares the two, so an
edit to an audited C++ file is caught. That script reads this file as text,
not through `licensedFiles`: it finds each row by its opening line and takes
the quoted strings of the license's file list, so the table's layout is part
of the check.


## What the table cannot detect

  - **A change to a kernel's Elm type.** The manifest hashes C++ only. An
    `Inert` license is re-checked at every occurrence and a `TransportsAs`
    license is matched against its declared shape, but a `Transports` license
    is not checked at all, so a change to such a kernel's type needs a new
    audit.
  - **One kernel at several types.** A kernel can be reached through several
    annotated definitions, as `String.fromNumber` is through both
    `String.fromInt` and `String.fromFloat`, so a row is a claim about every
    type the kernel can be used at, not only the one its evidence quotes.
  - **The prefix is not part of the key.** `Elm.Kernel.File.size` and
    `Eco.Kernel.File.size` share one row, whose audit covers both bodies. Two
    rows with the same home and name do not fail: `Dict.fromList` keeps the
    later one.

@docs ParamSetFlow, KernelPlan, LicenseScope, TypeShape, License, KernelSetFact
@docs factFor, licenseApplies, shapeOfAnnotation, licensedFiles, rows

-}

import Compiler.AST.Canonical as Can
import Compiler.Data.Name exposing (Name)
import Dict


{-| What a `Positional` row says about one parameter of a kernel, or about its
result.

`PSFOpaque` means the kernel's handling of the value is not accounted for, so
the arrows in its type are poisoned.

`PSFApplies` means the kernel only applies the function it is given, so its
arrows need no poison.

`PSFTunnels` means the function values of the argument flow to the kernel's
result, whose lambda sets receive the argument's members. No row uses it.

-}
type ParamSetFlow
    = PSFOpaque
    | PSFApplies


{-| The per-position row of a kernel that holds no license: a `ParamSetFlow`
for each parameter, in order, and one for the result. `evidence` is the audit
record described in the module docstring. A call whose parameters cannot be
aligned with `params` is fully poisoned instead.
-}
type alias KernelPlan =
    { params : List ParamSetFlow

    -- PSFOpaque poisons the result's arrows; the other two leave them alone.
    , result : ParamSetFlow
    , evidence : String
    }


{-| What must be checked about a kernel's type at an occurrence before its
license may be used there.

A license is a claim about the type the audit examined, but each occurrence of
the kernel is seen at its own inferred type, and what ties the two together
differs per scope.

`Inert` is for a kernel whose type has no function-capable position in any
argument or in its final result, so no function value crosses the call and the
license has nothing to transport. `licenseApplies` derives that property again
from the occurrence type, so if the kernel's Elm type gains such a position
the occurrence is refused rather than wrongly licensed. A row is `Inert`
exactly when its audit class is `vacuous`.

`Transports` is for a kernel that function values can cross, along the shared
variables of its type, and that has an annotated definition in package source
whose annotation is the type the audit examined. Nothing is checked at the
occurrence.

`TransportsAs` is the same for a kernel with no annotated definition, and
carries the audited type as a `TypeShape`. No annotation in package source
fixes such a kernel's occurrence type (`Compiler.Type.PostSolve` describes how
a kernel occurrence is typed), so `licenseApplies` checks that the occurrence
is an instance of the shape.

-}
type LicenseScope
    = Inert
    | Transports
    | TransportsAs TypeShape


{-| A kernel's audited type, as a pattern that occurrence types are matched
against: arrows, named type constructors and type variables.

A `TsVar` matches any type, but every repeat of the same variable must match
the same type, because the repeated variables are the paths the license says
function values take. A `TsCon` matches a type constructor by name and
arguments, not by home module, and the unit type is a `TsCon` named `()` with
no arguments.

-}
type TypeShape
    = TsVar String
    | TsFun TypeShape TypeShape
    | TsCon String (List TypeShape)


{-| A kernel's license: its `LicenseScope`, the repository-relative paths of
the C++ files its audit read, which the license manifest pins, and the audit
record `evidence`.
-}
type alias License =
    { scope : LicenseScope
    , files : List String
    , evidence : String
    }


{-| Tells whether `license` may be used at an occurrence of its kernel whose
type is `occurrence`. `False` means the kernel is to be treated there as if it
had no row, which is full poison.

An `Inert` license applies when no argument and no final result of the
occurrence type has a function-capable position, a `TransportsAs` license when
the occurrence is an instance of its shape, and a `Transports` license always.

`isScalarVar` says whether a type variable is constrained to `number` or
`comparable`, whose values cannot contain a function, so that it does not
count as function-capable. It must answer `False` for a variable it does not
recognise, so that the failure is a missing license and not a wrong one, and
for `appendable`, which ranges over lists that can hold functions.

-}
licenseApplies : (id -> Bool) -> License -> Can.Type id -> Bool
licenseApplies isScalarVar license occurrence =
    case license.scope of
        Inert ->
            isInertType isScalarVar occurrence

        Transports ->
            True

        TransportsAs shape ->
            matchesShape shape occurrence


{-| Tells whether `tipe`, read as a kernel's type, has no function-capable
position in any argument or in its final result. The arrows of its spine are
the kernel itself, not places a caller's value can sit, so they are walked
rather than counted.
-}
isInertType : (id -> Bool) -> Can.Type id -> Bool
isInertType isScalarVar tipe =
    case tipe of
        Can.TLambda _ arg result ->
            not (hasFunctionCapable isScalarVar arg) && isInertType isScalarVar result

        _ ->
            not (hasFunctionCapable isScalarVar tipe)


{-| Tells whether `tipe` has a function-capable position anywhere: an arrow, an
extensible record, or a type variable for which `isScalarVar` is `False`. An
alias counts if any of its arguments does, or if its body does with the
alias's own parameters left out.
-}
hasFunctionCapable : (id -> Bool) -> Can.Type id -> Bool
hasFunctionCapable isScalarVar tipe =
    case tipe of
        Can.TVar v ->
            not (isScalarVar v)

        Can.TLambda _ _ _ ->
            True

        Can.TType _ _ args ->
            List.any (hasFunctionCapable isScalarVar) args

        Can.TTuple a b rest ->
            hasFunctionCapable isScalarVar a || hasFunctionCapable isScalarVar b || List.any (hasFunctionCapable isScalarVar) rest

        Can.TRecord fields ext ->
            ext /= Nothing || List.any (\(Can.FieldType _ ft) -> hasFunctionCapable isScalarVar ft) (Dict.values fields)

        Can.TAlias _ _ args real ->
            -- A Holey body still mentions the alias's parameters, which stand
            -- for `args` and are checked through them. Counting them again
            -- would refuse a parameterised alias such as `Task Never String`,
            -- whose body is `Task x a`.
            let
                paramIds =
                    List.map Tuple.first args

                bodyScalar v =
                    isScalarVar v || List.member v paramIds
            in
            List.any (\( _, t ) -> hasFunctionCapable isScalarVar t) args
                || hasFunctionCapable bodyScalar (aliasBody real)

        Can.TUnit ->
            False


{-| Returns the body of an alias, whether or not its parameters have been
substituted into it.
-}
aliasBody : Can.AliasType id -> Can.Type id
aliasBody real =
    case real of
        Can.Holey t ->
            t

        Can.Filled t ->
            t


{-| Returns the `TypeShape` of an annotation, or `Nothing` when it contains a
record, a tuple or an alias, which a shape cannot express. It exists so that a
test can compare a `TransportsAs` row's shape with the kernel's annotation in
`Compiler.Type.KernelIntrinsics`.
-}
shapeOfAnnotation : Can.Type Name -> Maybe TypeShape
shapeOfAnnotation tipe =
    case tipe of
        Can.TVar name ->
            Just (TsVar name)

        Can.TLambda _ arg result ->
            Maybe.map2 TsFun (shapeOfAnnotation arg) (shapeOfAnnotation result)

        Can.TType _ name args ->
            Maybe.map (TsCon name) (traverseShapes args)

        Can.TUnit ->
            Just (TsCon "()" [])

        _ ->
            Nothing


{-| Returns the shapes of `types` in order, or `Nothing` if any of them has
none.
-}
traverseShapes : List (Can.Type Name) -> Maybe (List TypeShape)
traverseShapes types =
    case types of
        [] ->
            Just []

        t :: rest ->
            Maybe.map2 (::) (shapeOfAnnotation t) (traverseShapes rest)


{-| Tells whether `occurrence` is an instance of `shape`. Each `TsVar` is bound
to the type at its first position, and every later position of the same
variable must hold a type that `sameType` judges equal to it. Aliases in the
occurrence are expanded before matching, arrow ids are ignored, and a record or
a tuple in the occurrence matches only a `TsVar`.
-}
matchesShape : TypeShape -> Can.Type id -> Bool
matchesShape shape occurrence =
    matchShapeGo [ ( shape, occurrence ) ] []


{-| Matches each pending pair of a shape and a type in turn, adding to
`bindings` as it binds a `TsVar`, and returns `False` at the first mismatch.
-}
matchShapeGo : List ( TypeShape, Can.Type id ) -> List ( String, Can.Type id ) -> Bool
matchShapeGo pending bindings =
    case pending of
        [] ->
            True

        ( shape, occurrence ) :: rest ->
            case ( shape, chaseAlias occurrence ) of
                ( TsVar name, occ ) ->
                    case lookupBinding name bindings of
                        Nothing ->
                            matchShapeGo rest (( name, occ ) :: bindings)

                        Just bound ->
                            if sameType bound occ then
                                matchShapeGo rest bindings

                            else
                                False

                ( TsFun p r, Can.TLambda _ p2 r2 ) ->
                    matchShapeGo (( p, p2 ) :: ( r, r2 ) :: rest) bindings

                ( TsCon name args, Can.TType _ name2 args2 ) ->
                    if name == name2 && List.length args == List.length args2 then
                        matchShapeGo (List.map2 Tuple.pair args args2 ++ rest) bindings

                    else
                        False

                ( TsCon name [], Can.TUnit ) ->
                    name == "()" && matchShapeGo rest bindings

                _ ->
                    False


{-| Expands aliases at the head of `tipe` until it is not an alias.
-}
chaseAlias : Can.Type id -> Can.Type id
chaseAlias tipe =
    case tipe of
        Can.TAlias _ _ _ real ->
            chaseAlias (aliasBody real)

        _ ->
            tipe


{-| Returns the type bound to the variable `name` by the first matching entry
in `bindings`, if there is one.
-}
lookupBinding : String -> List ( String, Can.Type id ) -> Maybe (Can.Type id)
lookupBinding name bindings =
    case bindings of
        [] ->
            Nothing

        ( n, t ) :: rest ->
            if n == name then
                Just t

            else
                lookupBinding name rest


{-| Tells whether two types are the same, for the check that every repeat of a
`TsVar` is bound to one type. Aliases are expanded at every level.

Type variables are equal only when they are the same variable. If any two
variables were taken as equal, a shape such as `(a -> b) -> a -> b` would
accept an occurrence whose two `a` positions are unrelated, and the check would
pass on a sharing it never tested.

Arrow ids are ignored, and must stay ignored. Two positions bound to the same
`TsVar` normally carry different arrow ids even when their types agree, so
comparing the ids would refuse the license wherever a repeated variable is
bound to a function type.

Type constructors are compared by name and arguments, not home module. Records
compare unequal even to themselves, so a repeated variable bound to a record
type fails the match.

-}
sameType : Can.Type id -> Can.Type id -> Bool
sameType a b =
    case ( chaseAlias a, chaseAlias b ) of
        ( Can.TUnit, Can.TUnit ) ->
            True

        ( Can.TVar v1, Can.TVar v2 ) ->
            v1 == v2

        ( Can.TLambda _ p1 r1, Can.TLambda _ p2 r2 ) ->
            sameType p1 p2 && sameType r1 r2

        ( Can.TType _ n1 a1, Can.TType _ n2 a2 ) ->
            n1 == n2 && List.length a1 == List.length a2 && List.all identity (List.map2 sameType a1 a2)

        ( Can.TTuple x1 y1 r1, Can.TTuple x2 y2 r2 ) ->
            sameType x1 x2 && sameType y1 y2 && List.length r1 == List.length r2 && List.all identity (List.map2 sameType r1 r2)

        _ ->
            False


{-| The audited fact about one kernel: a license, or a per-position row for a
kernel that holds none. A kernel with no fact is fully poisoned.
-}
type KernelSetFact
    = TypeFaithful License
    | Positional KernelPlan


{-| Returns the fact for the kernel `name` in module `home`, or `Nothing` when
it has no row and every function-typed position of a call to it is to be
poisoned. The `Elm` or `Eco` kernel prefix is not part of the key.

A `TypeFaithful` fact needs no alignment with the call, because partial and
over-application are handled by unification, but `licenseApplies` must accept
the occurrence. A `Positional` fact applies only to a call whose parameters
can be aligned with the row's `params`, and any other call is fully poisoned.

-}
factFor : Name -> Name -> Maybe KernelSetFact
factFor home name =
    Dict.get ( home, name ) facts


{-| The C++ files that any license depends on, sorted and without duplicates.
`Positional` rows contribute nothing, since they carry no license.
-}
licensedFiles : List String
licensedFiles =
    facts
        |> Dict.values
        |> List.concatMap
            (\fact ->
                case fact of
                    TypeFaithful license ->
                        license.files

                    Positional _ ->
                        []
            )
        |> List.sort
        |> dedupeSorted


{-| Removes adjacent duplicates from `xs`, so that a sorted list keeps each
element once.
-}
dedupeSorted : List String -> List String
dedupeSorted xs =
    case xs of
        a :: b :: rest ->
            if a == b then
                dedupeSorted (b :: rest)

            else
                a :: dedupeSorted (b :: rest)

        _ ->
            xs


{-| Every row of the table, ordered by home module and then by name.
-}
rows : List ( ( Name, Name ), KernelSetFact )
rows =
    Dict.toList facts


{-| The table, keyed by home module and name. Each row's evidence is its audit
record, with the C++ line numbers and dates the audit used.
-}
facts : Dict.Dict ( Name, Name ) KernelSetFact
facts =
    Dict.fromList
        [ ( ( "Basics", "acos" )
          , TypeFaithful
                { scope = Inert
                , files = [ "elm-kernel-cpp/src/core/BasicsExports.cpp", "elm-kernel-cpp/src/core/Basics.cpp" ]
                , evidence = "class: vacuous | entry: BasicsExports.cpp:Elm_Kernel_Basics_acos:13-15 | helpers: Basics.cpp:acos:16-18 | type: elm/core/1.0.5/src/Basics.elm:718 (Float -> Float) | B1: vacuous (no function-capable position) | B2: no static/global/cache write | B3: no allocClosure/Tag_Closure | audited: 2026-08-20"
                }
          )
        , ( ( "Basics", "add" )
          , TypeFaithful
                { scope = Inert
                , files = [ "elm-kernel-cpp/src/core/BasicsExports.cpp" ]
                , evidence = "class: vacuous | entry: BasicsExports.cpp:Elm_Kernel_Basics_add:95-100 (ABI instances :123-129) | helpers: BasicsExports.cpp anon-ns:70-91 | type: elm/core/1.0.5/src/Basics.elm:168 (number -> number -> number) | B1: vacuous (no function-capable position) | B2: no static/global/cache write | B3: no allocClosure | audited: 2026-08-20"
                }
          )
        , ( ( "Basics", "and" )
          , TypeFaithful
                { scope = Inert
                , files = [ "elm-kernel-cpp/src/core/BasicsExports.cpp", "elm-kernel-cpp/src/core/Basics.cpp", "elm-kernel-cpp/src/ExportHelpers.hpp" ]
                , evidence = "class: vacuous | entry: BasicsExports.cpp:Elm_Kernel_Basics_and:220-222 | helpers: Basics.cpp:and_:153-155, ExportHelpers.hpp:80-89 | type: elm/core/1.0.5/src/Basics.elm:468 (Bool -> Bool -> Bool) | B1: vacuous (no function-capable position) | B2: no static/global/cache write | B3: no allocClosure/Tag_Closure | audited: 2026-08-20"
                }
          )
        , ( ( "Basics", "asin" )
          , TypeFaithful
                { scope = Inert
                , files = [ "elm-kernel-cpp/src/core/BasicsExports.cpp", "elm-kernel-cpp/src/core/Basics.cpp" ]
                , evidence = "class: vacuous | entry: BasicsExports.cpp:Elm_Kernel_Basics_asin:17-19 | helpers: Basics.cpp:asin:20-22 | type: elm/core/1.0.5/src/Basics.elm:728 (Float -> Float) | B1: vacuous (no function-capable position) | B2: no static/global/cache write | B3: no allocClosure/Tag_Closure | audited: 2026-08-20"
                }
          )
        , ( ( "Basics", "atan" )
          , TypeFaithful
                { scope = Inert
                , files = [ "elm-kernel-cpp/src/core/BasicsExports.cpp", "elm-kernel-cpp/src/core/Basics.cpp" ]
                , evidence = "class: vacuous | entry: BasicsExports.cpp:Elm_Kernel_Basics_atan:21-23 | helpers: Basics.cpp:atan:24-26 | type: elm/core/1.0.5/src/Basics.elm:751 (Float -> Float) | B1: vacuous (no function-capable position) | B2: no static/global/cache write | B3: no allocClosure/Tag_Closure | audited: 2026-08-20"
                }
          )
        , ( ( "Basics", "atan2" )
          , TypeFaithful
                { scope = Inert
                , files = [ "elm-kernel-cpp/src/core/BasicsExports.cpp", "elm-kernel-cpp/src/core/Basics.cpp" ]
                , evidence = "class: vacuous | entry: BasicsExports.cpp:Elm_Kernel_Basics_atan2:25-27 | helpers: Basics.cpp:atan2:28-30 | type: elm/core/1.0.5/src/Basics.elm:766 (Float -> Float -> Float) | B1: vacuous (no function-capable position) | B2: no static/global/cache write | B3: no allocClosure/Tag_Closure | audited: 2026-08-20"
                }
          )
        , ( ( "Basics", "ceiling" )
          , TypeFaithful
                { scope = Inert
                , files = [ "elm-kernel-cpp/src/core/BasicsExports.cpp", "elm-kernel-cpp/src/core/Basics.cpp" ]
                , evidence = "class: vacuous | entry: BasicsExports.cpp:Elm_Kernel_Basics_ceiling:192-194 | helpers: Basics.cpp:ceiling:113-115 | type: elm/core/1.0.5/src/Basics.elm:300 (Float -> Int) | B1: vacuous (no function-capable position) | B2: no static/global/cache write | B3: no allocClosure/Tag_Closure | audited: 2026-08-20"
                }
          )
        , ( ( "Basics", "cos" )
          , TypeFaithful
                { scope = Inert
                , files = [ "elm-kernel-cpp/src/core/BasicsExports.cpp", "elm-kernel-cpp/src/core/Basics.cpp" ]
                , evidence = "class: vacuous | entry: BasicsExports.cpp:Elm_Kernel_Basics_cos:29-31 | helpers: Basics.cpp:cos:32-34 | type: elm/core/1.0.5/src/Basics.elm:683 (Float -> Float) | B1: vacuous (no function-capable position) | B2: no static/global/cache write | B3: no allocClosure/Tag_Closure | audited: 2026-08-20"
                }
          )
        , ( ( "Basics", "e" )
          , TypeFaithful
                { scope = Inert
                , files = [ "elm-kernel-cpp/src/core/BasicsExports.cpp", "elm-kernel-cpp/src/core/Basics.cpp" ]
                , evidence = "class: vacuous | entry: BasicsExports.cpp:Elm_Kernel_Basics_e:168-170 | helpers: Basics.cpp:e:60-62 | type: elm/core/1.0.5/src/Basics.elm:628 (Float, CAF arity 0) | B1: vacuous (no function-capable position) | B2: no static/global/cache write | B3: no allocClosure/Tag_Closure | audited: 2026-08-20"
                }
          )
        , ( ( "Basics", "fdiv" )
          , TypeFaithful
                { scope = Inert
                , files = [ "elm-kernel-cpp/src/core/BasicsExports.cpp", "elm-kernel-cpp/src/core/Basics.cpp" ]
                , evidence = "class: vacuous | entry: BasicsExports.cpp:Elm_Kernel_Basics_fdiv:176-178 | helpers: Basics.cpp:fdiv:84-86 | type: elm/core/1.0.5/src/Basics.elm:203 (Float -> Float -> Float) | B1: vacuous (no function-capable position) | B2: no static/global/cache write | B3: no allocClosure/Tag_Closure | audited: 2026-08-20"
                }
          )
        , ( ( "Basics", "floor" )
          , TypeFaithful
                { scope = Inert
                , files = [ "elm-kernel-cpp/src/core/BasicsExports.cpp", "elm-kernel-cpp/src/core/Basics.cpp" ]
                , evidence = "class: vacuous | entry: BasicsExports.cpp:Elm_Kernel_Basics_floor:196-198 | helpers: Basics.cpp:floor:117-119 | type: elm/core/1.0.5/src/Basics.elm:284 (Float -> Int) | B1: vacuous (no function-capable position) | B2: no static/global/cache write | B3: no allocClosure/Tag_Closure | audited: 2026-08-20"
                }
          )
        , ( ( "Basics", "idiv" )
          , TypeFaithful
                { scope = Inert
                , files = [ "elm-kernel-cpp/src/core/BasicsExports.cpp", "elm-kernel-cpp/src/core/Basics.cpp" ]
                , evidence = "class: vacuous | entry: BasicsExports.cpp:Elm_Kernel_Basics_idiv:180-182 | helpers: Basics.cpp:idiv:88-90 | type: elm/core/1.0.5/src/Basics.elm:225 (Int -> Int -> Int) | B1: vacuous (no function-capable position) | B2: no static/global/cache write | B3: no allocClosure/Tag_Closure | audited: 2026-08-20"
                }
          )
        , ( ( "Basics", "isInfinite" )
          , TypeFaithful
                { scope = Inert
                , files = [ "elm-kernel-cpp/src/core/BasicsExports.cpp", "elm-kernel-cpp/src/core/Basics.cpp", "elm-kernel-cpp/src/ExportHelpers.hpp" ]
                , evidence = "class: vacuous | entry: BasicsExports.cpp:Elm_Kernel_Basics_isInfinite:212-214 | helpers: Basics.cpp:isInfinite:141-143, ExportHelpers.hpp:80-82 | type: elm/core/1.0.5/src/Basics.elm:826 (Float -> Bool) | B1: vacuous (no function-capable position) | B2: no static/global/cache write | B3: no allocClosure | audited: 2026-08-20"
                }
          )
        , ( ( "Basics", "isNaN" )
          , TypeFaithful
                { scope = Inert
                , files = [ "elm-kernel-cpp/src/core/BasicsExports.cpp", "elm-kernel-cpp/src/core/Basics.cpp", "elm-kernel-cpp/src/ExportHelpers.hpp" ]
                , evidence = "class: vacuous | entry: BasicsExports.cpp:Elm_Kernel_Basics_isNaN:216-218 | helpers: Basics.cpp:isNaN:145-147, ExportHelpers.hpp:encodeBoxedBool:80-82 | type: elm/core/1.0.5/src/Basics.elm:811 (Float -> Bool) | B1: vacuous (no function-capable position) | B2: no static/global/cache write | B3: no allocClosure | audited: 2026-08-20"
                }
          )
        , ( ( "Basics", "log" )
          , TypeFaithful
                { scope = Inert
                , files = [ "elm-kernel-cpp/src/core/BasicsExports.cpp", "elm-kernel-cpp/src/core/Basics.cpp" ]
                , evidence = "class: vacuous | entry: BasicsExports.cpp:Elm_Kernel_Basics_log:45-47 | helpers: Basics.cpp:log | type: elm/core/1.0.5/src/Basics.elm (Float -> Float; INFERRED-FROM-USAGE via logBase, R5 vacuous class) | B1: vacuous (no function-capable position) | B2: no store at all | B3: no allocClosure/Tag_Closure | audited: 2026-08-25"
                }
          )
        , ( ( "Basics", "modBy" )
          , TypeFaithful
                { scope = Inert
                , files = [ "elm-kernel-cpp/src/core/BasicsExports.cpp", "elm-kernel-cpp/src/core/Basics.cpp" ]
                , evidence = "class: vacuous | entry: BasicsExports.cpp:Elm_Kernel_Basics_modBy:184-186 | helpers: Basics.cpp:modBy:92-103 | type: elm/core/1.0.5/src/Basics.elm:539 (Int -> Int -> Int) | B1: vacuous (no function-capable position) | B2: no static/global/cache write; throw at :96 uses a literal | B3: no allocClosure | audited: 2026-08-20"
                }
          )
        , ( ( "Basics", "mul" )
          , TypeFaithful
                { scope = Inert
                , files = [ "elm-kernel-cpp/src/core/BasicsExports.cpp" ]
                , evidence = "class: vacuous | entry: BasicsExports.cpp:Elm_Kernel_Basics_mul:109-114 (ABI instances :139-145) | helpers: BasicsExports.cpp anon-ns:70-91 | type: elm/core/1.0.5/src/Basics.elm:186 (number -> number -> number) | B1: vacuous (no function-capable position) | B2: no static/global/cache write | B3: no allocClosure | audited: 2026-08-20"
                }
          )
        , ( ( "Basics", "not" )
          , TypeFaithful
                { scope = Inert
                , files = [ "elm-kernel-cpp/src/core/BasicsExports.cpp", "elm-kernel-cpp/src/core/Basics.cpp", "elm-kernel-cpp/src/ExportHelpers.hpp" ]
                , evidence = "class: vacuous | entry: BasicsExports.cpp:Elm_Kernel_Basics_not:232-234 | helpers: Basics.cpp:not_:165-167, ExportHelpers.hpp:80-89 | type: elm/core/1.0.5/src/Basics.elm:452 (Bool -> Bool) | B1: vacuous (no function-capable position) | B2: no static/global/cache write | B3: no allocClosure/Tag_Closure | audited: 2026-08-20"
                }
          )
        , ( ( "Basics", "or" )
          , TypeFaithful
                { scope = Inert
                , files = [ "elm-kernel-cpp/src/core/BasicsExports.cpp", "elm-kernel-cpp/src/core/Basics.cpp", "elm-kernel-cpp/src/ExportHelpers.hpp" ]
                , evidence = "class: vacuous | entry: BasicsExports.cpp:Elm_Kernel_Basics_or:224-226 | helpers: Basics.cpp:or_:157-159, ExportHelpers.hpp:80-89 | type: elm/core/1.0.5/src/Basics.elm:484 (Bool -> Bool -> Bool) | B1: vacuous (no function-capable position) | B2: no static/global/cache write | B3: no allocClosure/Tag_Closure | audited: 2026-08-20"
                }
          )
        , ( ( "Basics", "pi" )
          , TypeFaithful
                { scope = Inert
                , files = [ "elm-kernel-cpp/src/core/BasicsExports.cpp", "elm-kernel-cpp/src/core/Basics.cpp" ]
                , evidence = "class: vacuous | entry: BasicsExports.cpp:Elm_Kernel_Basics_pi:172-174 | helpers: Basics.cpp:pi:64-66 | type: elm/core/1.0.5/src/Basics.elm:670 (Float, CAF arity 0) | B1: vacuous (no function-capable position) | B2: no static/global/cache write | B3: no allocClosure/Tag_Closure | audited: 2026-08-20"
                }
          )
        , ( ( "Basics", "pow" )
          , TypeFaithful
                { scope = Inert
                , files = [ "elm-kernel-cpp/src/core/BasicsExports.cpp" ]
                , evidence = "class: vacuous | entry: BasicsExports.cpp:Elm_Kernel_Basics_pow:116-121 (ABI instances :149-166) | helpers: BasicsExports.cpp anon-ns:70-91 | type: elm/core/1.0.5/src/Basics.elm:235 (number -> number -> number) | B1: vacuous (no function-capable position) | B2: no static/global/cache write | B3: no allocClosure | audited: 2026-08-20"
                }
          )
        , ( ( "Basics", "remainderBy" )
          , TypeFaithful
                { scope = Inert
                , files = [ "elm-kernel-cpp/src/core/BasicsExports.cpp", "elm-kernel-cpp/src/core/Basics.cpp" ]
                , evidence = "class: vacuous | entry: BasicsExports.cpp:Elm_Kernel_Basics_remainderBy:188-190 | helpers: Basics.cpp:remainderBy:105-107 | type: elm/core/1.0.5/src/Basics.elm:555 (Int -> Int -> Int) | B1: vacuous (no function-capable position) | B2: no static/global/cache write | B3: no allocClosure/Tag_Closure | audited: 2026-08-20"
                }
          )
        , ( ( "Basics", "round" )
          , TypeFaithful
                { scope = Inert
                , files = [ "elm-kernel-cpp/src/core/BasicsExports.cpp", "elm-kernel-cpp/src/core/Basics.cpp" ]
                , evidence = "class: vacuous | entry: BasicsExports.cpp:Elm_Kernel_Basics_round:200-202 | helpers: Basics.cpp:round:121-123 | type: elm/core/1.0.5/src/Basics.elm:268 (Float -> Int) | B1: vacuous (no function-capable position) | B2: no static/global/cache write | B3: no allocClosure/Tag_Closure | audited: 2026-08-20"
                }
          )
        , ( ( "Basics", "sin" )
          , TypeFaithful
                { scope = Inert
                , files = [ "elm-kernel-cpp/src/core/BasicsExports.cpp", "elm-kernel-cpp/src/core/Basics.cpp" ]
                , evidence = "class: vacuous | entry: BasicsExports.cpp:Elm_Kernel_Basics_sin:33-35 | helpers: Basics.cpp:sin:36-38 | type: elm/core/1.0.5/src/Basics.elm:696 (Float -> Float) | B1: vacuous (no function-capable position) | B2: no static/global/cache write | B3: no allocClosure/Tag_Closure | audited: 2026-08-20"
                }
          )
        , ( ( "Basics", "sqrt" )
          , TypeFaithful
                { scope = Inert
                , files = [ "elm-kernel-cpp/src/core/BasicsExports.cpp", "elm-kernel-cpp/src/core/Basics.cpp" ]
                , evidence = "class: vacuous | entry: BasicsExports.cpp:Elm_Kernel_Basics_sqrt:41-43 | helpers: Basics.cpp:sqrt:44-46 | type: elm/core/1.0.5/src/Basics.elm:609 (Float -> Float) | B1: vacuous (no function-capable position) | B2: no static/global/cache write | B3: no allocClosure/Tag_Closure | audited: 2026-08-20"
                }
          )
        , ( ( "Basics", "sub" )
          , TypeFaithful
                { scope = Inert
                , files = [ "elm-kernel-cpp/src/core/BasicsExports.cpp" ]
                , evidence = "class: vacuous | entry: BasicsExports.cpp:Elm_Kernel_Basics_sub:102-107 (ABI instances :131-137) | helpers: BasicsExports.cpp anon-ns:70-91 | type: elm/core/1.0.5/src/Basics.elm:177 (number -> number -> number) | B1: vacuous (no function-capable position) | B2: no static/global/cache write | B3: no allocClosure | audited: 2026-08-20"
                }
          )
        , ( ( "Basics", "tan" )
          , TypeFaithful
                { scope = Inert
                , files = [ "elm-kernel-cpp/src/core/BasicsExports.cpp", "elm-kernel-cpp/src/core/Basics.cpp" ]
                , evidence = "class: vacuous | entry: BasicsExports.cpp:Elm_Kernel_Basics_tan:37-39 | helpers: Basics.cpp:tan:40-42 | type: elm/core/1.0.5/src/Basics.elm:708 (Float -> Float) | B1: vacuous (no function-capable position) | B2: no static/global/cache write | B3: no allocClosure/Tag_Closure | audited: 2026-08-20"
                }
          )
        , ( ( "Basics", "toFloat" )
          , TypeFaithful
                { scope = Inert
                , files = [ "elm-kernel-cpp/src/core/BasicsExports.cpp", "elm-kernel-cpp/src/core/Basics.cpp" ]
                , evidence = "class: vacuous | entry: BasicsExports.cpp:Elm_Kernel_Basics_toFloat:208-210 | helpers: Basics.cpp:toFloat:133-135 | type: elm/core/1.0.5/src/Basics.elm:252 (Int -> Float) | B1: vacuous (no function-capable position) | B2: no static/global/cache write | B3: no allocClosure/Tag_Closure | audited: 2026-08-20"
                }
          )
        , ( ( "Basics", "truncate" )
          , TypeFaithful
                { scope = Inert
                , files = [ "elm-kernel-cpp/src/core/BasicsExports.cpp", "elm-kernel-cpp/src/core/Basics.cpp" ]
                , evidence = "class: vacuous | entry: BasicsExports.cpp:Elm_Kernel_Basics_truncate:204-206 | helpers: Basics.cpp:truncate:125-127 | type: elm/core/1.0.5/src/Basics.elm:316 (Float -> Int) | B1: vacuous (no function-capable position) | B2: no static/global/cache write | B3: no allocClosure/Tag_Closure | audited: 2026-08-20"
                }
          )
        , ( ( "Basics", "xor" )
          , TypeFaithful
                { scope = Inert
                , files = [ "elm-kernel-cpp/src/core/BasicsExports.cpp", "elm-kernel-cpp/src/core/Basics.cpp", "elm-kernel-cpp/src/ExportHelpers.hpp" ]
                , evidence = "class: vacuous | entry: BasicsExports.cpp:Elm_Kernel_Basics_xor:228-230 | helpers: Basics.cpp:xor_:161-163, ExportHelpers.hpp:80-89 | type: elm/core/1.0.5/src/Basics.elm:496 (Bool -> Bool -> Bool) | B1: vacuous (no function-capable position) | B2: no static/global/cache write | B3: no allocClosure/Tag_Closure | audited: 2026-08-20"
                }
          )
        , ( ( "Bitwise", "and" )
          , TypeFaithful
                { scope = Inert
                , files = [ "elm-kernel-cpp/src/core/BitwiseExports.cpp", "elm-kernel-cpp/src/core/Bitwise.cpp" ]
                , evidence = "class: vacuous | entry: BitwiseExports.cpp:Elm_Kernel_Bitwise_and:10-12 | helpers: Bitwise.cpp:and_:5-16 | type: elm/core/1.0.5/src/Bitwise.elm:23 (Int -> Int -> Int) | B1: vacuous (no function-capable position) | B2: no static/global/cache write | B3: no allocClosure/Tag_Closure | audited: 2026-08-20"
                }
          )
        , ( ( "Bitwise", "complement" )
          , TypeFaithful
                { scope = Inert
                , files = [ "elm-kernel-cpp/src/core/BitwiseExports.cpp", "elm-kernel-cpp/src/core/Bitwise.cpp" ]
                , evidence = "class: vacuous | entry: BitwiseExports.cpp:Elm_Kernel_Bitwise_complement:22-24 | helpers: Bitwise.cpp:complement:44-55 | type: elm/core/1.0.5/src/Bitwise.elm:44 (Int -> Int) | B1: vacuous (no function-capable position) | B2: no static/global/cache write | B3: no allocClosure/Tag_Closure | audited: 2026-08-20"
                }
          )
        , ( ( "Bitwise", "or" )
          , TypeFaithful
                { scope = Inert
                , files = [ "elm-kernel-cpp/src/core/BitwiseExports.cpp", "elm-kernel-cpp/src/core/Bitwise.cpp" ]
                , evidence = "class: vacuous | entry: BitwiseExports.cpp:Elm_Kernel_Bitwise_or:14-16 | helpers: Bitwise.cpp:or_:18-29 | type: elm/core/1.0.5/src/Bitwise.elm:30 (Int -> Int -> Int) | B1: vacuous (no function-capable position) | B2: no static/global/cache write | B3: no allocClosure/Tag_Closure | audited: 2026-08-20"
                }
          )
        , ( ( "Bitwise", "shiftLeftBy" )
          , TypeFaithful
                { scope = Inert
                , files = [ "elm-kernel-cpp/src/core/BitwiseExports.cpp", "elm-kernel-cpp/src/core/Bitwise.cpp" ]
                , evidence = "class: vacuous | entry: BitwiseExports.cpp:Elm_Kernel_Bitwise_shiftLeftBy:26-28 | helpers: Bitwise.cpp:shiftLeftBy:57-69 | type: elm/core/1.0.5/src/Bitwise.elm:55 (Int -> Int -> Int) | B1: vacuous (no function-capable position) | B2: no static/global/cache write | B3: no allocClosure/Tag_Closure | audited: 2026-08-20"
                }
          )
        , ( ( "Bitwise", "shiftRightBy" )
          , TypeFaithful
                { scope = Inert
                , files = [ "elm-kernel-cpp/src/core/BitwiseExports.cpp", "elm-kernel-cpp/src/core/Bitwise.cpp" ]
                , evidence = "class: vacuous | entry: BitwiseExports.cpp:Elm_Kernel_Bitwise_shiftRightBy:30-32 | helpers: Bitwise.cpp:shiftRightBy:71-83 | type: elm/core/1.0.5/src/Bitwise.elm:73 (Int -> Int -> Int) | B1: vacuous (no function-capable position) | B2: no static/global/cache write | B3: no allocClosure/Tag_Closure | audited: 2026-08-20"
                }
          )
        , ( ( "Bitwise", "shiftRightZfBy" )
          , TypeFaithful
                { scope = Inert
                , files = [ "elm-kernel-cpp/src/core/BitwiseExports.cpp", "elm-kernel-cpp/src/core/Bitwise.cpp" ]
                , evidence = "class: vacuous | entry: BitwiseExports.cpp:Elm_Kernel_Bitwise_shiftRightZfBy:34-36 | helpers: Bitwise.cpp:shiftRightZfBy:85-98 | type: elm/core/1.0.5/src/Bitwise.elm:90 (Int -> Int -> Int; uint64_t ret) | B1: vacuous (no function-capable position) | B2: no static/global write | B3: no allocClosure | audited: 2026-08-20"
                }
          )
        , ( ( "Bitwise", "xor" )
          , TypeFaithful
                { scope = Inert
                , files = [ "elm-kernel-cpp/src/core/BitwiseExports.cpp", "elm-kernel-cpp/src/core/Bitwise.cpp" ]
                , evidence = "class: vacuous | entry: BitwiseExports.cpp:Elm_Kernel_Bitwise_xor:18-20 | helpers: Bitwise.cpp:xor_:31-42 | type: elm/core/1.0.5/src/Bitwise.elm:37 (Int -> Int -> Int) | B1: vacuous (no function-capable position) | B2: no static/global/cache write | B3: no allocClosure/Tag_Closure | audited: 2026-08-20"
                }
          )
        , ( ( "Bytes", "decode" )
          , Positional
                { params = [ PSFApplies, PSFOpaque ]
                , result = PSFOpaque
                , evidence = "class: full | entry: BytesExports.cpp:Elm_Kernel_Bytes_decode:412-461 | B1: apply-only via eco_apply_closure_typed :425, decoder never stored or copied | result opaque: A2 — :432-435 routes on an out-of-band Nothing sentinel the callback's (Int, a) type does not describe | audited: 2026-08-20"
                }
          )
        , ( ( "Bytes", "decodeFailure" )
          , TypeFaithful
                { scope = Inert
                , files = [ "elm-kernel-cpp/src/bytes/BytesExports.cpp" ]
                , evidence = "class: vacuous | entry: BytesExports.cpp:Elm_Kernel_Bytes_decodeFailure:463-465 | type: elm/bytes/1.0.8/src/Bytes/Decode.elm (the failure marker behind `fail : Decoder a`) | B1: vacuous - NO arguments, returns a constant marker; `a` is phantom AND nothing can ever be written to it from here | B2: no store | B3: no allocClosure | audited: 2026-10-06 (re-audit, plans/ci-all-platforms-green.md issue 5b: the only C++ change is in Elm_Kernel_Bytes_read_string, whose legacy UTF-16 decode now zeroes the code units it reserved but did not write (u16 stores into its own fresh result string); BytesExports.cpp line citations from 704 on shift by 4; no application, retention, fabrication or type change)"
                }
          )
        , ( ( "Bytes", "encode" )
          , TypeFaithful
                { scope = Inert
                , files = [ "elm-kernel-cpp/src/bytes/BytesExports.cpp" ]
                , evidence = "class: vacuous | entry: BytesExports.cpp:Elm_Kernel_Bytes_encode:389-410 | helpers: encoderSize:118-136, writeEncoder:138-272 | type: elm/bytes/1.0.8/src/Bytes/Encode.elm:96 (Encoder -> Bytes) | B1: vacuous (no function-capable position) | B2: result alloc only :401-403 | B3: no closure alloc | audited: 2026-10-06 (re-audit, plans/ci-all-platforms-green.md issue 5b: the only C++ change is in Elm_Kernel_Bytes_read_string, whose legacy UTF-16 decode now zeroes the code units it reserved but did not write (u16 stores into its own fresh result string); BytesExports.cpp line citations from 704 on shift by 4; no application, retention, fabrication or type change)"
                }
          )
        , ( ( "Bytes", "getHostEndianness" )
          , TypeFaithful
                { scope = Inert
                , files = [ "elm-kernel-cpp/src/bytes/BytesExports.cpp" ]
                , evidence = "class: vacuous | entry: BytesExports.cpp:Elm_Kernel_Bytes_getHostEndianness:297-301 | type: elm/bytes/1.0.8/src/Bytes.elm (Endianness) | B1: vacuous - NO arguments; returns fromBits(isLE ? 0 : 1), a concrete enum | B2: no store | B3: no allocClosure | audited: 2026-10-06 (re-audit, plans/ci-all-platforms-green.md issue 5b: the only C++ change is in Elm_Kernel_Bytes_read_string, whose legacy UTF-16 decode now zeroes the code units it reserved but did not write (u16 stores into its own fresh result string); BytesExports.cpp line citations from 704 on shift by 4; no application, retention, fabrication or type change)"
                }
          )
        , ( ( "Bytes", "getStringWidth" )
          , TypeFaithful
                { scope = Inert
                , files = [ "elm-kernel-cpp/src/bytes/BytesExports.cpp" ]
                , evidence = "class: vacuous | entry: BytesExports.cpp:Elm_Kernel_Bytes_getStringWidth:303-360 | helpers: none | type: elm/bytes/1.0.8/src/Bytes/Encode.elm:250 (String -> Int) | B1: vacuous (no function-capable position) | B2: C++-stack u16string :331, no Elm retention | B3: no closure alloc | audited: 2026-10-06 (re-audit, plans/ci-all-platforms-green.md issue 5b: the only C++ change is in Elm_Kernel_Bytes_read_string, whose legacy UTF-16 decode now zeroes the code units it reserved but did not write (u16 stores into its own fresh result string); BytesExports.cpp line citations from 704 on shift by 4; no application, retention, fabrication or type change)"
                }
          )
        , ( ( "Bytes", "read_bytes" )
          , TypeFaithful
                { scope = Inert
                , files = [ "elm-kernel-cpp/src/bytes/BytesExports.cpp" ]
                , evidence = "class: vacuous | entry: BytesExports.cpp:Elm_Kernel_Bytes_read_bytes:567-578 | helpers: makeTuple2_ip:65-76 | type: INFERRED elm/bytes/1.0.8/src/Bytes/Decode.elm:146 (Int -> Bytes -> Int -> (Int, Bytes)) | B1: vacuous (no function-capable position) | B2: slice + Tuple2 result only | B3: no closure alloc | audited: 2026-10-06 (re-audit, plans/ci-all-platforms-green.md issue 5b: the only C++ change is in Elm_Kernel_Bytes_read_string, whose legacy UTF-16 decode now zeroes the code units it reserved but did not write (u16 stores into its own fresh result string); BytesExports.cpp line citations from 704 on shift by 4; no application, retention, fabrication or type change)"
                }
          )
        , ( ( "Bytes", "read_f32" )
          , TypeFaithful
                { scope = Inert
                , files = [ "elm-kernel-cpp/src/bytes/BytesExports.cpp" ]
                , evidence = "class: vacuous | entry: BytesExports.cpp:Elm_Kernel_Bytes_read_f32:543-553 | helpers: makeTuple2_if:55-63 | type: INFERRED elm/bytes/1.0.8/src/Bytes/Decode.elm:128 (Bool -> Bytes -> Int -> (Int, Float)) | B1: vacuous (no function-capable position) | B2: Tuple2 result only | B3: no closure alloc | audited: 2026-10-06 (re-audit, plans/ci-all-platforms-green.md issue 5b: the only C++ change is in Elm_Kernel_Bytes_read_string, whose legacy UTF-16 decode now zeroes the code units it reserved but did not write (u16 stores into its own fresh result string); BytesExports.cpp line citations from 704 on shift by 4; no application, retention, fabrication or type change)"
                }
          )
        , ( ( "Bytes", "read_f64" )
          , TypeFaithful
                { scope = Inert
                , files = [ "elm-kernel-cpp/src/bytes/BytesExports.cpp" ]
                , evidence = "class: vacuous | entry: BytesExports.cpp:Elm_Kernel_Bytes_read_f64:555-565 | helpers: makeTuple2_if:55-63 | type: INFERRED elm/bytes/1.0.8/src/Bytes/Decode.elm:135 (Bool -> Bytes -> Int -> (Int, Float)) | B1: vacuous (no function-capable position) | B2: Tuple2 result only | B3: no closure alloc | audited: 2026-10-06 (re-audit, plans/ci-all-platforms-green.md issue 5b: the only C++ change is in Elm_Kernel_Bytes_read_string, whose legacy UTF-16 decode now zeroes the code units it reserved but did not write (u16 stores into its own fresh result string); BytesExports.cpp line citations from 704 on shift by 4; no application, retention, fabrication or type change)"
                }
          )
        , ( ( "Bytes", "read_i16" )
          , TypeFaithful
                { scope = Inert
                , files = [ "elm-kernel-cpp/src/bytes/BytesExports.cpp" ]
                , evidence = "class: vacuous | entry: BytesExports.cpp:Elm_Kernel_Bytes_read_i16:501-510 | helpers: makeTuple2_ii:45-53 | type: INFERRED elm/bytes/1.0.8/src/Bytes/Decode.elm:85 (Bool -> Bytes -> Int -> (Int, Int)) | B1: vacuous (no function-capable position) | B2: Tuple2 result only | B3: no closure alloc | audited: 2026-10-06 (re-audit, plans/ci-all-platforms-green.md issue 5b: the only C++ change is in Elm_Kernel_Bytes_read_string, whose legacy UTF-16 decode now zeroes the code units it reserved but did not write (u16 stores into its own fresh result string); BytesExports.cpp line citations from 704 on shift by 4; no application, retention, fabrication or type change)"
                }
          )
        , ( ( "Bytes", "read_i32" )
          , TypeFaithful
                { scope = Inert
                , files = [ "elm-kernel-cpp/src/bytes/BytesExports.cpp" ]
                , evidence = "class: vacuous | entry: BytesExports.cpp:Elm_Kernel_Bytes_read_i32:512-521 | helpers: makeTuple2_ii:45-53 | type: INFERRED elm/bytes/1.0.8/src/Bytes/Decode.elm:92 (Bool -> Bytes -> Int -> (Int, Int)) | B1: vacuous (no function-capable position) | B2: Tuple2 result only | B3: no closure alloc | audited: 2026-10-06 (re-audit, plans/ci-all-platforms-green.md issue 5b: the only C++ change is in Elm_Kernel_Bytes_read_string, whose legacy UTF-16 decode now zeroes the code units it reserved but did not write (u16 stores into its own fresh result string); BytesExports.cpp line citations from 704 on shift by 4; no application, retention, fabrication or type change)"
                }
          )
        , ( ( "Bytes", "read_i8" )
          , TypeFaithful
                { scope = Inert
                , files = [ "elm-kernel-cpp/src/bytes/BytesExports.cpp" ]
                , evidence = "class: vacuous | entry: BytesExports.cpp:Elm_Kernel_Bytes_read_i8:486-491 | helpers: makeTuple2_ii:45-53 | type: INFERRED elm/bytes/1.0.8/src/Bytes/Decode.elm:78 (Bytes -> Int -> (Int, Int)) | B1: vacuous (no function-capable position) | B2: Tuple2 result only :46-47 | B3: no closure alloc | audited: 2026-10-06 (re-audit, plans/ci-all-platforms-green.md issue 5b: the only C++ change is in Elm_Kernel_Bytes_read_string, whose legacy UTF-16 decode now zeroes the code units it reserved but did not write (u16 stores into its own fresh result string); BytesExports.cpp line citations from 704 on shift by 4; no application, retention, fabrication or type change)"
                }
          )
        , ( ( "Bytes", "read_string" )
          , TypeFaithful
                { scope = Inert
                , files = [ "elm-kernel-cpp/src/bytes/BytesExports.cpp" ]
                , evidence = "class: vacuous | entry: BytesExports.cpp:Elm_Kernel_Bytes_read_string:580-711 | helpers: makeTuple2_ip:65-76 | type: INFERRED elm/bytes/1.0.8/src/Bytes/Decode.elm:175 (Int -> Bytes -> Int -> (Int, String)) | B1: vacuous (no function-capable position) | B2: body + Tuple2 result rooted :664-666 | B3: no closure alloc | audited: 2026-10-06 (re-audit, plans/ci-all-platforms-green.md issue 5b: the only C++ change is in Elm_Kernel_Bytes_read_string, whose legacy UTF-16 decode now zeroes the code units it reserved but did not write (u16 stores into its own fresh result string); BytesExports.cpp line citations from 704 on shift by 4; no application, retention, fabrication or type change)"
                }
          )
        , ( ( "Bytes", "read_u16" )
          , TypeFaithful
                { scope = Inert
                , files = [ "elm-kernel-cpp/src/bytes/BytesExports.cpp" ]
                , evidence = "class: vacuous | entry: BytesExports.cpp:Elm_Kernel_Bytes_read_u16:523-531 | helpers: makeTuple2_ii:45-53 | type: INFERRED elm/bytes/1.0.8/src/Bytes/Decode.elm:110 (Bool -> Bytes -> Int -> (Int, Int)) | B1: vacuous (no function-capable position) | B2: Tuple2 result only | B3: no closure alloc | audited: 2026-10-06 (re-audit, plans/ci-all-platforms-green.md issue 5b: the only C++ change is in Elm_Kernel_Bytes_read_string, whose legacy UTF-16 decode now zeroes the code units it reserved but did not write (u16 stores into its own fresh result string); BytesExports.cpp line citations from 704 on shift by 4; no application, retention, fabrication or type change)"
                }
          )
        , ( ( "Bytes", "read_u32" )
          , TypeFaithful
                { scope = Inert
                , files = [ "elm-kernel-cpp/src/bytes/BytesExports.cpp" ]
                , evidence = "class: vacuous | entry: BytesExports.cpp:Elm_Kernel_Bytes_read_u32:533-541 | helpers: makeTuple2_ii:45-53 | type: INFERRED elm/bytes/1.0.8/src/Bytes/Decode.elm:117 (Bool -> Bytes -> Int -> (Int, Int)) | B1: vacuous (no function-capable position) | B2: Tuple2 result only | B3: no closure alloc | audited: 2026-10-06 (re-audit, plans/ci-all-platforms-green.md issue 5b: the only C++ change is in Elm_Kernel_Bytes_read_string, whose legacy UTF-16 decode now zeroes the code units it reserved but did not write (u16 stores into its own fresh result string); BytesExports.cpp line citations from 704 on shift by 4; no application, retention, fabrication or type change)"
                }
          )
        , ( ( "Bytes", "read_u8" )
          , TypeFaithful
                { scope = Inert
                , files = [ "elm-kernel-cpp/src/bytes/BytesExports.cpp" ]
                , evidence = "class: vacuous | entry: BytesExports.cpp:Elm_Kernel_Bytes_read_u8:493-497 | helpers: makeTuple2_ii:45-53 | type: INFERRED elm/bytes/1.0.8/src/Bytes/Decode.elm:103 (Bytes -> Int -> (Int, Int)) | B1: vacuous (no function-capable position) | B2: Tuple2 result only | B3: no closure alloc | audited: 2026-10-06 (re-audit, plans/ci-all-platforms-green.md issue 5b: the only C++ change is in Elm_Kernel_Bytes_read_string, whose legacy UTF-16 decode now zeroes the code units it reserved but did not write (u16 stores into its own fresh result string); BytesExports.cpp line citations from 704 on shift by 4; no application, retention, fabrication or type change)"
                }
          )
        , ( ( "Bytes", "width" )
          , TypeFaithful
                { scope = Inert
                , files = [ "elm-kernel-cpp/src/bytes/BytesExports.cpp" ]
                , evidence = "class: vacuous | entry: BytesExports.cpp:Elm_Kernel_Bytes_width:293-295 | helpers: ElmBytesRuntime.cpp:elm_bytebuffer_len:78-85 | type: elm/bytes/1.0.8/src/Bytes.elm:77 (Bytes -> Int) | B1: vacuous (no function-capable position) | B2: read-only length probe, no statics | B3: no closure alloc | audited: 2026-10-06 (re-audit, plans/ci-all-platforms-green.md issue 5b: the only C++ change is in Elm_Kernel_Bytes_read_string, whose legacy UTF-16 decode now zeroes the code units it reserved but did not write (u16 stores into its own fresh result string); BytesExports.cpp line citations from 704 on shift by 4; no application, retention, fabrication or type change)"
                }
          )
        , ( ( "Bytes", "write_bytes" )
          , TypeFaithful
                { scope = Inert
                , files = [ "elm-kernel-cpp/src/bytes/BytesExports.cpp" ]
                , evidence = "class: vacuous | entry: BytesExports.cpp:Elm_Kernel_Bytes_write_bytes:869-871 | helpers: makeEncoderBytes:819-835 | type: INFERRED elm/bytes/1.0.8/src/Bytes/Encode.elm:298 (C++ Bytes -> Encoder; Elm ref discrepant, all concrete) | B1: vacuous (no function-capable position) | B2: arg into result :833, rooted :825-829 | B3: no closure alloc | audited: 2026-10-06 (re-audit, plans/ci-all-platforms-green.md issue 5b: the only C++ change is in Elm_Kernel_Bytes_read_string, whose legacy UTF-16 decode now zeroes the code units it reserved but did not write (u16 stores into its own fresh result string); BytesExports.cpp line citations from 704 on shift by 4; no application, retention, fabrication or type change)"
                }
          )
        , ( ( "Bytes", "write_f32" )
          , TypeFaithful
                { scope = Inert
                , files = [ "elm-kernel-cpp/src/bytes/BytesExports.cpp" ]
                , evidence = "class: vacuous | entry: BytesExports.cpp:Elm_Kernel_Bytes_write_f32:861-863 | helpers: makeEncoder2_pf:755-772 | type: INFERRED elm/bytes/1.0.8/src/Bytes/Encode.elm:294 (C++ Endianness -> Float -> Encoder; Elm ref discrepant, all concrete) | B1: vacuous (no function-capable position) | B2: result node only :761-765 | B3: no closure alloc | audited: 2026-10-06 (re-audit, plans/ci-all-platforms-green.md issue 5b: the only C++ change is in Elm_Kernel_Bytes_read_string, whose legacy UTF-16 decode now zeroes the code units it reserved but did not write (u16 stores into its own fresh result string); BytesExports.cpp line citations from 704 on shift by 4; no application, retention, fabrication or type change)"
                }
          )
        , ( ( "Bytes", "write_f64" )
          , TypeFaithful
                { scope = Inert
                , files = [ "elm-kernel-cpp/src/bytes/BytesExports.cpp" ]
                , evidence = "class: vacuous | entry: BytesExports.cpp:Elm_Kernel_Bytes_write_f64:865-867 | helpers: makeEncoder2_pf:755-772 | type: INFERRED elm/bytes/1.0.8/src/Bytes/Encode.elm:295 (C++ Endianness -> Float -> Encoder; Elm ref discrepant, all concrete) | B1: vacuous (no function-capable position) | B2: result node only :761-765 | B3: no closure alloc | audited: 2026-10-06 (re-audit, plans/ci-all-platforms-green.md issue 5b: the only C++ change is in Elm_Kernel_Bytes_read_string, whose legacy UTF-16 decode now zeroes the code units it reserved but did not write (u16 stores into its own fresh result string); BytesExports.cpp line citations from 704 on shift by 4; no application, retention, fabrication or type change)"
                }
          )
        , ( ( "Bytes", "write_i16" )
          , TypeFaithful
                { scope = Inert
                , files = [ "elm-kernel-cpp/src/bytes/BytesExports.cpp" ]
                , evidence = "class: vacuous | entry: BytesExports.cpp:Elm_Kernel_Bytes_write_i16:841-843 | helpers: makeEncoder2_pi:736-753 | type: INFERRED elm/bytes/1.0.8/src/Bytes/Encode.elm:289 (C++ Endianness -> Int -> Encoder; Elm ref discrepant, all concrete) | B1: vacuous (no function-capable position) | B2: result node only :742-746 | B3: no closure alloc | audited: 2026-10-06 (re-audit, plans/ci-all-platforms-green.md issue 5b: the only C++ change is in Elm_Kernel_Bytes_read_string, whose legacy UTF-16 decode now zeroes the code units it reserved but did not write (u16 stores into its own fresh result string); BytesExports.cpp line citations from 704 on shift by 4; no application, retention, fabrication or type change)"
                }
          )
        , ( ( "Bytes", "write_i32" )
          , TypeFaithful
                { scope = Inert
                , files = [ "elm-kernel-cpp/src/bytes/BytesExports.cpp" ]
                , evidence = "class: vacuous | entry: BytesExports.cpp:Elm_Kernel_Bytes_write_i32:845-847 | helpers: makeEncoder2_pi:736-753 | type: INFERRED elm/bytes/1.0.8/src/Bytes/Encode.elm:290 (C++ Endianness -> Int -> Encoder; Elm ref discrepant, all concrete) | B1: vacuous (no function-capable position) | B2: result node only :742-746 | B3: no closure alloc | audited: 2026-10-06 (re-audit, plans/ci-all-platforms-green.md issue 5b: the only C++ change is in Elm_Kernel_Bytes_read_string, whose legacy UTF-16 decode now zeroes the code units it reserved but did not write (u16 stores into its own fresh result string); BytesExports.cpp line citations from 704 on shift by 4; no application, retention, fabrication or type change)"
                }
          )
        , ( ( "Bytes", "write_i8" )
          , TypeFaithful
                { scope = Inert
                , files = [ "elm-kernel-cpp/src/bytes/BytesExports.cpp" ]
                , evidence = "class: vacuous | entry: BytesExports.cpp:Elm_Kernel_Bytes_write_i8:837-839 | helpers: makeEncoder1:717-727 | type: INFERRED elm/bytes/1.0.8/src/Bytes/Encode.elm:288 (C++ Int -> Encoder; Elm ref discrepant, all concrete) | B1: vacuous (no function-capable position) | B2: result node only :720-721 | B3: no closure alloc | audited: 2026-10-06 (re-audit, plans/ci-all-platforms-green.md issue 5b: the only C++ change is in Elm_Kernel_Bytes_read_string, whose legacy UTF-16 decode now zeroes the code units it reserved but did not write (u16 stores into its own fresh result string); BytesExports.cpp line citations from 704 on shift by 4; no application, retention, fabrication or type change)"
                }
          )
        , ( ( "Bytes", "write_string" )
          , TypeFaithful
                { scope = Inert
                , files = [ "elm-kernel-cpp/src/bytes/BytesExports.cpp" ]
                , evidence = "class: vacuous | entry: BytesExports.cpp:Elm_Kernel_Bytes_write_string:873-875 | helpers: makeEncoderUtf8:794-814 | type: INFERRED elm/bytes/1.0.8/src/Bytes/Encode.elm:297 (C++ String -> Encoder; Elm ref discrepant, all concrete) | B1: vacuous (no function-capable position) | B2: arg+width into result :811-812, rooted :802-807 | B3: no closure alloc | audited: 2026-10-06 (re-audit, plans/ci-all-platforms-green.md issue 5b: the only C++ change is in Elm_Kernel_Bytes_read_string, whose legacy UTF-16 decode now zeroes the code units it reserved but did not write (u16 stores into its own fresh result string); BytesExports.cpp line citations from 704 on shift by 4; no application, retention, fabrication or type change)"
                }
          )
        , ( ( "Bytes", "write_u16" )
          , TypeFaithful
                { scope = Inert
                , files = [ "elm-kernel-cpp/src/bytes/BytesExports.cpp" ]
                , evidence = "class: vacuous | entry: BytesExports.cpp:Elm_Kernel_Bytes_write_u16:853-855 | helpers: makeEncoder2_pi:736-753 | type: INFERRED elm/bytes/1.0.8/src/Bytes/Encode.elm:292 (C++ Endianness -> Int -> Encoder; Elm ref discrepant, all concrete) | B1: vacuous (no function-capable position) | B2: result node only :742-746 | B3: no closure alloc | audited: 2026-10-06 (re-audit, plans/ci-all-platforms-green.md issue 5b: the only C++ change is in Elm_Kernel_Bytes_read_string, whose legacy UTF-16 decode now zeroes the code units it reserved but did not write (u16 stores into its own fresh result string); BytesExports.cpp line citations from 704 on shift by 4; no application, retention, fabrication or type change)"
                }
          )
        , ( ( "Bytes", "write_u32" )
          , TypeFaithful
                { scope = Inert
                , files = [ "elm-kernel-cpp/src/bytes/BytesExports.cpp" ]
                , evidence = "class: vacuous | entry: BytesExports.cpp:Elm_Kernel_Bytes_write_u32:857-859 | helpers: makeEncoder2_pi:736-753 | type: INFERRED elm/bytes/1.0.8/src/Bytes/Encode.elm:293 (C++ Endianness -> Int -> Encoder; Elm ref discrepant, all concrete) | B1: vacuous (no function-capable position) | B2: result node only :742-746 | B3: no closure alloc | audited: 2026-10-06 (re-audit, plans/ci-all-platforms-green.md issue 5b: the only C++ change is in Elm_Kernel_Bytes_read_string, whose legacy UTF-16 decode now zeroes the code units it reserved but did not write (u16 stores into its own fresh result string); BytesExports.cpp line citations from 704 on shift by 4; no application, retention, fabrication or type change)"
                }
          )
        , ( ( "Bytes", "write_u8" )
          , TypeFaithful
                { scope = Inert
                , files = [ "elm-kernel-cpp/src/bytes/BytesExports.cpp" ]
                , evidence = "class: vacuous | entry: BytesExports.cpp:Elm_Kernel_Bytes_write_u8:849-851 | helpers: makeEncoder1:717-727 | type: INFERRED elm/bytes/1.0.8/src/Bytes/Encode.elm:291 (C++ Int -> Encoder; Elm ref discrepant, all concrete) | B1: vacuous (no function-capable position) | B2: result node only :720-721 | B3: no closure alloc | audited: 2026-10-06 (re-audit, plans/ci-all-platforms-green.md issue 5b: the only C++ change is in Elm_Kernel_Bytes_read_string, whose legacy UTF-16 decode now zeroes the code units it reserved but did not write (u16 stores into its own fresh result string); BytesExports.cpp line citations from 704 on shift by 4; no application, retention, fabrication or type change)"
                }
          )
        , ( ( "Char", "fromCode" )
          , TypeFaithful
                { scope = Inert
                , files = [ "elm-kernel-cpp/src/core/CharExports.cpp" ]
                , evidence = "class: vacuous | entry: CharExports.cpp:Elm_Kernel_Char_fromCode:11-15 | helpers: none (inline std::max/min clamp) | type: elm/core/1.0.5/src/Char.elm:255 (Int -> Char) | B1: vacuous (no function-capable position) | B2: no static/global/task write | B3: no closure alloc | audited: 2026-08-20"
                }
          )
        , ( ( "Char", "toCode" )
          , TypeFaithful
                { scope = Inert
                , files = [ "elm-kernel-cpp/src/core/CharExports.cpp" ]
                , evidence = "class: vacuous | entry: CharExports.cpp:Elm_Kernel_Char_toCode:28-30 | helpers: none | type: elm/core/1.0.5/src/Char.elm:235 (Char -> Int; u64 c_raw & 0xFFFF = statepoint ABI :17-27) | B1: vacuous (no function-capable position) | B2: no static/global/task write | B3: no closure alloc | audited: 2026-08-20"
                }
          )
        , ( ( "Char", "toLocaleLower" )
          , TypeFaithful
                { scope = Inert
                , files = [ "elm-kernel-cpp/src/core/CharExports.cpp", "elm-kernel-cpp/src/core/Char.cpp" ]
                , evidence = "class: vacuous | entry: CharExports.cpp:Elm_Kernel_Char_toLocaleLower:42-45 | helpers: Char.cpp:toLocaleLower:105-122 (-> toLower) | type: elm/core/1.0.5/src/Char.elm:220 (Char -> Char) | B1: vacuous (no function-capable position) | B2: no static/global/task write | B3: no closure alloc | audited: 2026-08-20"
                }
          )
        , ( ( "Char", "toLocaleUpper" )
          , TypeFaithful
                { scope = Inert
                , files = [ "elm-kernel-cpp/src/core/CharExports.cpp", "elm-kernel-cpp/src/core/Char.cpp" ]
                , evidence = "class: vacuous | entry: CharExports.cpp:Elm_Kernel_Char_toLocaleUpper:47-50 | helpers: Char.cpp:toLocaleUpper:124-141 (-> toUpper) | type: elm/core/1.0.5/src/Char.elm:214 (Char -> Char) | B1: vacuous (no function-capable position) | B2: no static/global/task write | B3: no closure alloc | audited: 2026-08-20"
                }
          )
        , ( ( "Char", "toLower" )
          , TypeFaithful
                { scope = Inert
                , files = [ "elm-kernel-cpp/src/core/CharExports.cpp", "elm-kernel-cpp/src/core/Char.cpp" ]
                , evidence = "class: vacuous | entry: CharExports.cpp:Elm_Kernel_Char_toLower:32-35 | helpers: Char.cpp:toLower:61-81 (pure, calls nothing) | type: elm/core/1.0.5/src/Char.elm:208 (Char -> Char) | B1: vacuous (no function-capable position) | B2: no static/global/task write | B3: no closure alloc | audited: 2026-08-20"
                }
          )
        , ( ( "Char", "toUpper" )
          , TypeFaithful
                { scope = Inert
                , files = [ "elm-kernel-cpp/src/core/CharExports.cpp", "elm-kernel-cpp/src/core/Char.cpp" ]
                , evidence = "class: vacuous | entry: CharExports.cpp:Elm_Kernel_Char_toUpper:37-40 | helpers: Char.cpp:toUpper:83-103 (pure, calls nothing) | type: elm/core/1.0.5/src/Char.elm:202 (Char -> Char) | B1: vacuous (no function-capable position) | B2: no static/global/task write | B3: no closure alloc | audited: 2026-08-20"
                }
          )
        , ( ( "Console", "log" )
          , TypeFaithful
                { scope = Transports
                , files = [ "eco-kernel-cpp/src/eco-kernel/ConsoleExports.cpp", "eco-kernel-cpp/src/eco-kernel/Console.cpp" ]
                , evidence = "class: cheap | entry: ConsoleExports.cpp:Eco_Kernel_Console_log:21-23 | helpers: Console.cpp:log:144-163 | type: Eco/Console.elm:81 (String -> a -> a, alias-seeded) | B1: B1(b)+B1(c) -- Console.cpp:162 `return value;` is the arg's ONLY use | B2: no static/global/task write in Console.cpp | B3: no allocClosure/Tag_Closure | audited: 2026-08-20"
                }
          )
        , ( ( "Console", "readAll" )
          , TypeFaithful
                { scope = Inert
                , files = [ "eco-kernel-cpp/src/eco-kernel/ConsoleExports.cpp", "eco-kernel-cpp/src/eco-kernel/Console.cpp" ]
                , evidence = "class: vacuous | entry: ConsoleExports.cpp:Eco_Kernel_Console_readAll:17-19 | helpers: Console.cpp:readAll:140-142 | type: Eco/Console.elm:71 | B1: vacuous (no function-capable position) | B2: nothing captured (unit(), :141) | B3: binding closure only | audited: 2026-08-20"
                }
          )
        , ( ( "Console", "readLine" )
          , TypeFaithful
                { scope = Inert
                , files = [ "eco-kernel-cpp/src/eco-kernel/ConsoleExports.cpp", "eco-kernel-cpp/src/eco-kernel/Console.cpp" ]
                , evidence = "class: vacuous | entry: ConsoleExports.cpp:Eco_Kernel_Console_readLine:13-15 | helpers: Console.cpp:readLine:136-138 | type: Eco/Console.elm:63 | B1: vacuous (no function-capable position) | B2: nothing captured (unit(), :137) | B3: binding closure only | audited: 2026-08-20"
                }
          )
        , ( ( "Console", "write" )
          , TypeFaithful
                { scope = Inert
                , files = [ "eco-kernel-cpp/src/eco-kernel/ConsoleExports.cpp", "eco-kernel-cpp/src/eco-kernel/Console.cpp" ]
                , evidence = "class: vacuous | entry: ConsoleExports.cpp:Eco_Kernel_Console_write:9-11 | helpers: Console.cpp:write:126-134 | type: Eco/Console.elm:55 | B1: vacuous (no function-capable position) | B2: String captured :129-133, set-flow inert | B3: binding closure only | audited: 2026-08-20"
                }
          )
        , ( ( "Crash", "crash" )
          , TypeFaithful
                { scope = Transports
                , files = [ "eco-kernel-cpp/src/eco-kernel/CrashExports.cpp", "eco-kernel-cpp/src/eco-kernel/Crash.cpp" ]
                , evidence = "class: cheap | entry: CrashExports.cpp:Eco_Kernel_Crash_crash:9-11 | helpers: Crash.cpp:crash:20-33 | type: Eco/Crash.elm:16 (String -> a, alias-seeded) | B1: no function value enters (param is String); result `a` never inhabited -- ::exit(1) :30 | B2: no storage | B3: no allocClosure/Tag_Closure | audited: 2026-08-20"
                }
          )
        , ( ( "Env", "lookup" )
          , TypeFaithful
                { scope = Inert
                , files = [ "eco-kernel-cpp/src/eco-kernel/EnvExports.cpp", "eco-kernel-cpp/src/eco-kernel/Env.cpp" ]
                , evidence = "class: vacuous | entry: EnvExports.cpp:Eco_Kernel_Env_lookup:9-11 | helpers: Env.cpp:lookup:52-55 | type: Eco/Env.elm:20 (String -> Task Never (Maybe String), alias-seeded) | B1: vacuous (no function-capable position) | B2: String captured :54, inert; s_argv:19-20 is char** | B3: binding closure only | audited: 2026-08-20"
                }
          )
        , ( ( "Env", "rawArgs" )
          , TypeFaithful
                { scope = Inert
                , files = [ "eco-kernel-cpp/src/eco-kernel/EnvExports.cpp", "eco-kernel-cpp/src/eco-kernel/Env.cpp" ]
                , evidence = "class: vacuous | entry: EnvExports.cpp:Eco_Kernel_Env_rawArgs:13-15 | helpers: Env.cpp:rawArgs:57-60 | type: Eco/Env.elm:27 (Task Never (List String), alias-seeded) | B1: vacuous (no function-capable position) | B2: nothing captured (unit(), :59) | B3: binding closure only | audited: 2026-08-20"
                }
          )
        , ( ( "File", "appDataDir" )
          , TypeFaithful
                { scope = Inert
                , files = [ "eco-kernel-cpp/src/eco-kernel/FileExports.cpp", "eco-kernel-cpp/src/eco-kernel/File.cpp" ]
                , evidence = "class: vacuous | entry: FileExports.cpp:Eco_Kernel_File_appDataDir:81-83 | helpers: File.cpp:appDataDir:823-826 | type: Eco/File.elm:271 (String -> Task Never String, alias-seeded) | B1: vacuous (no function-capable position) | B2: String captured :825 | B3: binding closure only | audited: 2026-10-03"
                }
          )
        , ( ( "File", "canonicalize" )
          , TypeFaithful
                { scope = Inert
                , files = [ "eco-kernel-cpp/src/eco-kernel/FileExports.cpp", "eco-kernel-cpp/src/eco-kernel/File.cpp" ]
                , evidence = "class: vacuous | entry: FileExports.cpp:Eco_Kernel_File_canonicalize:77-79 | helpers: File.cpp:canonicalize:818-821 | type: Eco/File.elm:263 (String -> Task IOError String) | B1: vacuous (no function-capable position) | B2: String captured :820 | B3: binding closure only | audited: 2026-10-03"
                }
          )
        , ( ( "File", "close" )
          , TypeFaithful
                { scope = Inert
                , files = [ "eco-kernel-cpp/src/eco-kernel/FileExports.cpp", "eco-kernel-cpp/src/eco-kernel/File.cpp" ]
                , evidence = "class: vacuous | entry: FileExports.cpp:Eco_Kernel_File_close:33-35 | helpers: File.cpp:close:747-753 | type: Eco/File.elm:149 (Handle -> Task IOError (); inferred Int -> ...) | B1: vacuous (no function-capable position) | B2: only an unboxed Int captured :752 | B3: binding closure only | audited: 2026-10-03"
                }
          )
        , ( ( "File", "createDir" )
          , TypeFaithful
                { scope = Inert
                , files = [ "eco-kernel-cpp/src/eco-kernel/FileExports.cpp", "eco-kernel-cpp/src/eco-kernel/File.cpp" ]
                , evidence = "class: vacuous | entry: FileExports.cpp:Eco_Kernel_File_createDir:85-87 | helpers: File.cpp:createDir:828-835 | type: Eco/File.elm:279 (Bool -> String -> Task IOError ()) | B1: vacuous (no function-capable position) | B2: both args in a tuple2 :834, Bool decoded :673 | B3: binding closure only | audited: 2026-10-03"
                }
          )
        , ( ( "File", "dirExists" )
          , TypeFaithful
                { scope = Inert
                , files = [ "eco-kernel-cpp/src/eco-kernel/FileExports.cpp", "eco-kernel-cpp/src/eco-kernel/File.cpp" ]
                , evidence = "class: vacuous | entry: FileExports.cpp:Eco_Kernel_File_dirExists:53-55 | helpers: File.cpp:dirExists:788-791 | type: Eco/File.elm:204 (String -> Task Never Bool, alias-seeded) | B1: vacuous (no function-capable position) | B2: String captured :790 | B3: binding closure only | audited: 2026-10-03"
                }
          )
        , ( ( "File", "fileExists" )
          , TypeFaithful
                { scope = Inert
                , files = [ "eco-kernel-cpp/src/eco-kernel/FileExports.cpp", "eco-kernel-cpp/src/eco-kernel/File.cpp" ]
                , evidence = "class: vacuous | entry: FileExports.cpp:Eco_Kernel_File_fileExists:49-51 | helpers: File.cpp:fileExists:783-786 | type: Eco/File.elm:197 (String -> Task Never Bool, alias-seeded) | B1: vacuous (no function-capable position) | B2: String captured :785 | B3: binding closure only | audited: 2026-10-03"
                }
          )
        , ( ( "File", "findExecutable" )
          , TypeFaithful
                { scope = Inert
                , files = [ "eco-kernel-cpp/src/eco-kernel/FileExports.cpp", "eco-kernel-cpp/src/eco-kernel/File.cpp" ]
                , evidence = "class: vacuous | entry: FileExports.cpp:Eco_Kernel_File_findExecutable:57-59 | helpers: File.cpp:findExecutable:793-796 | type: Eco/File.elm:211 | B1: vacuous (no function-capable position) | B2: String captured :795; :203/:209 are static FUNCTIONS | B3: binding closure only | audited: 2026-10-03"
                }
          )
        , ( ( "File", "getCwd" )
          , TypeFaithful
                { scope = Inert
                , files = [ "eco-kernel-cpp/src/eco-kernel/FileExports.cpp", "eco-kernel-cpp/src/eco-kernel/File.cpp" ]
                , evidence = "class: vacuous | entry: FileExports.cpp:Eco_Kernel_File_getCwd:69-71 | helpers: File.cpp:getCwd:808-811 | type: Eco/File.elm:248 (Task Never String, alias-seeded) | B1: vacuous (no function-capable position) | B2: nothing captured (unit(), :810) | B3: binding closure only | audited: 2026-10-03"
                }
          )
        , ( ( "File", "hWriteString" )
          , TypeFaithful
                { scope = Inert
                , files = [ "eco-kernel-cpp/src/eco-kernel/FileExports.cpp", "eco-kernel-cpp/src/eco-kernel/File.cpp" ]
                , evidence = "class: vacuous | entry: FileExports.cpp:Eco_Kernel_File_hWriteString:97-99 | helpers: File.cpp:hWriteString:755-763 | type: Eco/File.elm:157 | B1: vacuous (no function-capable position) | B2: String + unboxed fd in a tuple2 :762 | B3: binding closure only | audited: 2026-10-03"
                }
          )
        , ( ( "File", "list" )
          , TypeFaithful
                { scope = Inert
                , files = [ "eco-kernel-cpp/src/eco-kernel/FileExports.cpp", "eco-kernel-cpp/src/eco-kernel/File.cpp" ]
                , evidence = "class: vacuous | entry: FileExports.cpp:Eco_Kernel_File_list:61-63 | helpers: File.cpp:list:798-801 | type: Eco/File.elm:218 (String -> Task IOError (List String); element concrete) | B1: vacuous (no function-capable position) | B2: String captured :800; list built fresh | B3: binding closure only | audited: 2026-10-03"
                }
          )
        , ( ( "File", "lock" )
          , TypeFaithful
                { scope = Inert
                , files = [ "eco-kernel-cpp/src/eco-kernel/FileExports.cpp", "eco-kernel-cpp/src/eco-kernel/File.cpp" ]
                , evidence = "class: vacuous | entry: FileExports.cpp:Eco_Kernel_File_lock:41-43 | helpers: File.cpp:lock:773-776 | type: Eco/File.elm:177 (String -> Task IOError ()) | B1: vacuous (no function-capable position) | B2: String captured :775, never read | B3: binding closure only | audited: 2026-10-03"
                }
          )
        , ( ( "File", "mime" )
          , TypeFaithful
                { scope = Inert
                , files = [ "elm-kernel-cpp/src/file/FileExports.cpp" ]
                , evidence = "class: vacuous | entry: FileExports.cpp:Elm_Kernel_File_mime:31-35 | type: elm/file/1.0.5/src/File.elm:152 (File -> String; type File = File :41 -- no arrow, no tvar) | B1: vacuous (no function-capable position) | B2: vacuous, the body performs no writes (stub: :33 asserts) | B3: no closure allocation | audited: 2026-10-03"
                }
          )
        , ( ( "File", "modificationTime" )
          , TypeFaithful
                { scope = Inert
                , files = [ "eco-kernel-cpp/src/eco-kernel/FileExports.cpp", "eco-kernel-cpp/src/eco-kernel/File.cpp" ]
                , evidence = "class: vacuous | entry: FileExports.cpp:Eco_Kernel_File_modificationTime:65-67 | helpers: File.cpp:modificationTime:803-806 | type: Eco/File.elm:226 (String -> Task IOError Time.Posix; inferred ok Int) | B1: vacuous (no function-capable position) | B2: String captured :805 | B3: binding closure only | audited: 2026-10-03"
                }
          )
        , ( ( "File", "name" )
          , TypeFaithful
                { scope = Inert
                , files = [ "elm-kernel-cpp/src/file/FileExports.cpp" ]
                , evidence = "class: vacuous | entry: FileExports.cpp:Elm_Kernel_File_name:25-29 | type: elm/file/1.0.5/src/File.elm:142 (File -> String; type File = File :41 -- no arrow, no tvar) | B1: vacuous (no function-capable position) | B2: vacuous, the body performs no writes (stub: :27 asserts) | B3: no closure allocation | audited: 2026-10-03"
                }
          )
        , ( ( "File", "open" )
          , TypeFaithful
                { scope = Inert
                , files = [ "eco-kernel-cpp/src/eco-kernel/FileExports.cpp", "eco-kernel-cpp/src/eco-kernel/File.cpp" ]
                , evidence = "class: vacuous | entry: FileExports.cpp:Eco_Kernel_File_open:29-31 | helpers: File.cpp:open:734-745 | type: Eco/File.elm:118 | B1: vacuous (no function-capable position) | B2: tuple2 :744; fd returned as an Int :638 | B3: binding closure only | audited: 2026-10-03"
                }
          )
        , ( ( "File", "readBytes" )
          , TypeFaithful
                { scope = Inert
                , files = [ "eco-kernel-cpp/src/eco-kernel/FileExports.cpp", "eco-kernel-cpp/src/eco-kernel/File.cpp" ]
                , evidence = "class: vacuous | entry: FileExports.cpp:Eco_Kernel_File_readBytes:17-19 | helpers: File.cpp:readBytes:711-714 | type: Eco/File.elm:88 (String -> Task IOError Bytes) | B1: vacuous (no function-capable position) | B2: String captured :713 | B3: binding closure only | audited: 2026-10-03"
                }
          )
        , ( ( "File", "readString" )
          , TypeFaithful
                { scope = Inert
                , files = [ "eco-kernel-cpp/src/eco-kernel/FileExports.cpp", "eco-kernel-cpp/src/eco-kernel/File.cpp" ]
                , evidence = "class: vacuous | entry: FileExports.cpp:Eco_Kernel_File_readString:9-11 | helpers: File.cpp:readString:697-700 | type: Eco/File.elm:72 (String -> Task IOError String) | B1: vacuous (no function-capable position) | B2: String captured :699; no object statics in File.cpp | B3: binding closure only | audited: 2026-10-03"
                }
          )
        , ( ( "File", "removeDir" )
          , TypeFaithful
                { scope = Inert
                , files = [ "eco-kernel-cpp/src/eco-kernel/FileExports.cpp", "eco-kernel-cpp/src/eco-kernel/File.cpp" ]
                , evidence = "class: vacuous | entry: FileExports.cpp:Eco_Kernel_File_removeDir:93-95 | helpers: File.cpp:removeDir:842-845 | type: Eco/File.elm:295 (String -> Task IOError ()) | B1: vacuous (no function-capable position) | B2: String captured :844 | B3: binding closure only | audited: 2026-10-03"
                }
          )
        , ( ( "File", "removeFile" )
          , TypeFaithful
                { scope = Inert
                , files = [ "eco-kernel-cpp/src/eco-kernel/FileExports.cpp", "eco-kernel-cpp/src/eco-kernel/File.cpp" ]
                , evidence = "class: vacuous | entry: FileExports.cpp:Eco_Kernel_File_removeFile:89-91 | helpers: File.cpp:removeFile:837-840 | type: Eco/File.elm:287 (String -> Task IOError ()) | B1: vacuous (no function-capable position) | B2: String captured :839 | B3: binding closure only | audited: 2026-10-03"
                }
          )
        , ( ( "File", "setCwd" )
          , TypeFaithful
                { scope = Inert
                , files = [ "eco-kernel-cpp/src/eco-kernel/FileExports.cpp", "eco-kernel-cpp/src/eco-kernel/File.cpp" ]
                , evidence = "class: vacuous | entry: FileExports.cpp:Eco_Kernel_File_setCwd:73-75 | helpers: File.cpp:setCwd:813-816 | type: Eco/File.elm:255 (String -> Task IOError ()) | B1: vacuous (no function-capable position) | B2: String captured :815; CWD change is an OS effect | B3: binding closure only | audited: 2026-10-03"
                }
          )
        , ( ( "File", "size" )
          , TypeFaithful
                { scope = Inert
                , files = [ "eco-kernel-cpp/src/eco-kernel/File.cpp", "eco-kernel-cpp/src/eco-kernel/FileExports.cpp", "elm-kernel-cpp/src/file/FileExports.cpp" ]
                , evidence = "class: vacuous | entry: eco FileExports.cpp:37-39 + elm FileExports.cpp:37-41 (both _File_size) | type: SHARED KEY -- Eco/File.elm:165 (Handle -> Task IOError Int) AND elm/file/1.0.5/src/File.elm:163 (File -> Int); both arrow-free and variable-free | B1: vacuous (no function-capable position) | B2: eco captures an Int File.cpp:770; elm no writes | B3: eco binding closure only | audited: 2026-10-03"
                }
          )
        , ( ( "File", "touch" )
          , TypeFaithful
                { scope = Inert
                , files = [ "eco-kernel-cpp/src/eco-kernel/FileExports.cpp", "eco-kernel-cpp/src/eco-kernel/File.cpp" ]
                , evidence = "class: vacuous | entry: FileExports.cpp:Eco_Kernel_File_touch:101-103 | helpers: File.cpp:touch:847-850 | type: Eco/File.elm:236 (String -> Task IOError ()) | B1: vacuous (no function-capable position) | B2: String captured :849 | B3: binding closure only | audited: 2026-10-03"
                }
          )
        , ( ( "File", "unlock" )
          , TypeFaithful
                { scope = Inert
                , files = [ "eco-kernel-cpp/src/eco-kernel/FileExports.cpp", "eco-kernel-cpp/src/eco-kernel/File.cpp" ]
                , evidence = "class: vacuous | entry: FileExports.cpp:Eco_Kernel_File_unlock:45-47 | helpers: File.cpp:unlock:778-781 | type: Eco/File.elm:185 (String -> Task IOError ()) | B1: vacuous (no function-capable position) | B2: String captured :780, never read | B3: binding closure only | audited: 2026-10-03"
                }
          )
        , ( ( "File", "writeBytes" )
          , TypeFaithful
                { scope = Inert
                , files = [ "eco-kernel-cpp/src/eco-kernel/FileExports.cpp", "eco-kernel-cpp/src/eco-kernel/File.cpp" ]
                , evidence = "class: vacuous | entry: FileExports.cpp:Eco_Kernel_File_writeBytes:21-23 | helpers: File.cpp:writeBytes:716-723 | type: Eco/File.elm:96 (String -> Bytes -> Task IOError ()) | B1: vacuous (no function-capable position) | B2: both args in a tuple2 :722 | B3: binding closure only | audited: 2026-10-03"
                }
          )
        , ( ( "File", "writeBytesAtomic" )
          , TypeFaithful
                { scope = Inert
                , files = [ "eco-kernel-cpp/src/eco-kernel/FileExports.cpp", "eco-kernel-cpp/src/eco-kernel/File.cpp" ]
                , evidence = "class: vacuous | entry: FileExports.cpp:Eco_Kernel_File_writeBytesAtomic:25-27 | helpers: File.cpp:writeBytesAtomic:725-732, File.cpp:writeBytesAtomicBody:547-608 | type: Eco/File.elm:106 (String -> Bytes -> Task IOError ()) | B1: vacuous (no function-capable position) | B2: both args in a tuple2 :729; gAtomicWriteSeq :542 is a plain integer, not a heap value | B3: binding closure only | audited: 2026-10-03"
                }
          )
        , ( ( "File", "writeString" )
          , TypeFaithful
                { scope = Inert
                , files = [ "eco-kernel-cpp/src/eco-kernel/FileExports.cpp", "eco-kernel-cpp/src/eco-kernel/File.cpp" ]
                , evidence = "class: vacuous | entry: FileExports.cpp:Eco_Kernel_File_writeString:13-15 | helpers: File.cpp:writeString:702-709 | type: Eco/File.elm:80 (String -> String -> Task IOError ()) | B1: vacuous (no function-capable position) | B2: both Strings in a tuple2 :708 | B3: binding closure only | audited: 2026-10-03"
                }
          )
        , ( ( "Http", "emptyBody" )
          , TypeFaithful
                { scope = Inert
                , files = [ "elm-kernel-cpp/src/http/HttpExports.cpp" ]
                , evidence = "class: vacuous | entry: HttpExports.cpp:Elm_Kernel_Http_emptyBody:658-661 | type: elm/http/2.0.0/src/Http.elm:224 | B1: vacuous (no function-capable position) | B2: :659-660 is one custom(BODY_EMPTY) alloc + return; no static/global/task | B3: no allocClosure/Tag_Closure | audited: 2026-08-20"
                }
          )
        , ( ( "Http", "fetch" )
          , TypeFaithful
                { scope = Inert
                , files = [ "eco-kernel-cpp/src/eco-kernel/HttpExports.cpp", "eco-kernel-cpp/src/eco-kernel/Http.cpp" ]
                , evidence = "class: vacuous | entry: HttpExports.cpp:Eco_Kernel_Http_fetch:9-11 | type: Eco/Http.elm:22-26 | B1: vacuous (no function-capable position) | B2: three Strings in a tuple3 :415-418; parkBundle parks the runtime's OWN resume | B3: async binding closure only | audited: 2026-08-20 | re-audit 2026-10-06: plans/kernel-root-stack-bounded-rooting.md - Http.cpp rooting only (getArchive file tuples rooted by one all-ones record instead of one per element); no apply, no retention, no closure mint; B1/B2/B3 unchanged"
                }
          )
        , ( ( "Http", "getArchive" )
          , TypeFaithful
                { scope = Inert
                , files = [ "eco-kernel-cpp/src/eco-kernel/HttpExports.cpp", "eco-kernel-cpp/src/eco-kernel/Http.cpp" ]
                , evidence = "class: vacuous | entry: HttpExports.cpp:Eco_Kernel_Http_getArchive:13-15 | helpers: Http.cpp:getArchive:421-424, parkBundle:340-349 | type: Eco/Http.elm:35-37 | B1: vacuous (no function-capable position) | B2: url captured as the async payload :423 | B3: async binding closure only | audited: 2026-08-20 | re-audit 2026-10-06: plans/kernel-root-stack-bounded-rooting.md - Http.cpp rooting only (getArchive file tuples rooted by one all-ones record instead of one per element); no apply, no retention, no closure mint; B1/B2/B3 unchanged"
                }
          )
        , ( ( "Http", "pair" )
          , TypeFaithful
                { scope = Inert
                , files = [ "elm-kernel-cpp/src/http/HttpExports.cpp" ]
                , evidence = "class: vacuous | entry: HttpExports.cpp:Elm_Kernel_Http_pair:664-672 | type: elm/http/2.0.0/src/Http.elm:249,271,286,351,368 -- ALL FIVE visible types (string/bytes/fileBody, string/filePart) confirmed arrow-free AND variable-free | B1: vacuous (no function-capable position) | B2: :666-671 writes only into the returned custom(BODY_PAIR) | B3: none | audited: 2026-08-20"
                }
          )
        , ( ( "Http", "toFormData" )
          , TypeFaithful
                { scope = Inert
                , files = [ "elm-kernel-cpp/src/http/HttpExports.cpp" ]
                , evidence = "class: vacuous | entry: HttpExports.cpp:Elm_Kernel_Http_toFormData:771-777 | type: elm/http/2.0.0/src/Http.elm (List Part -> Body) | B1: vacuous - Part and Body are both CONCRETE, no type variable and no arrow anywhere | B2: no store outside result | B3: no allocClosure | audited: 2026-08-25"
                }
          )
        , ( ( "JsArray", "appendN" )
          , TypeFaithful
                { scope = Transports
                , files = [ "elm-kernel-cpp/src/core/JsArrayExports.cpp" ]
                , evidence = "class: cheap | entry: JsArrayExports.cpp:Elm_Kernel_JsArray_appendN:358-416 | helpers: elm_array_append_n:1036-1087 | type: elm/core/1.0.5/src/Elm/JsArray.elm:179 | B1: :382-387 copy element words verbatim, B1(b) along shared a | B2: writes confined to fresh resultArr | B3: no allocClosure/Tag_Closure | audited: 2026-10-05 (re-audit, plans/wide-object-tail-kind-words-phase-2.md 2.3/2.6: the only C++ changes are the EvalParamLayout encoding (hand-written byte arrays replaced by makeEvalParamLayout values with the same kinds; u16 num_params) and, in ListExports, closure kinds read from a ClosureKinds snapshot; no application, retention, fabrication or type change)"
                }
          )
        , ( ( "JsArray", "empty" )
          , TypeFaithful
                { scope = Transports
                , files = [ "elm-kernel-cpp/src/core/JsArrayExports.cpp" ]
                , evidence = "class: cheap | entry: JsArrayExports.cpp:Elm_Kernel_JsArray_empty:192-195 | type: elm/core/1.0.5/src/Elm/JsArray.elm:53 (JsArray a) | B1: no argument (zero-arg CAF) | B2: one allocation, no store outside result | B3: no allocClosure/Tag_Closure | audited: 2026-10-05 (re-audit, plans/wide-object-tail-kind-words-phase-2.md 2.3/2.6: the only C++ changes are the EvalParamLayout encoding (hand-written byte arrays replaced by makeEvalParamLayout values with the same kinds; u16 num_params) and, in ListExports, closure kinds read from a ClosureKinds snapshot; no application, retention, fabrication or type change)"
                }
          )
        , ( ( "JsArray", "foldl" )
          , TypeFaithful
                { scope = Transports
                , files = [ "elm-kernel-cpp/src/core/JsArrayExports.cpp" ]
                , evidence = "class: full | entry: JsArrayExports.cpp:Elm_Kernel_JsArray_foldl:651-653 | helpers: foldImpl:576-649 | type: elm/core/1.0.5/src/Elm/JsArray.elm:129 | B1: apply-only via eco_apply_closure_eval :184; acc by identity :638-639 | B2: roots + stack locals only :598-623 | B3: no allocClosure/Tag_Closure | audited: 2026-10-05 (re-audit, plans/wide-object-tail-kind-words-phase-2.md 2.3/2.6: the only C++ changes are the EvalParamLayout encoding (hand-written byte arrays replaced by makeEvalParamLayout values with the same kinds; u16 num_params) and, in ListExports, closure kinds read from a ClosureKinds snapshot; no application, retention, fabrication or type change)"
                }
          )
        , ( ( "JsArray", "foldr" )
          , TypeFaithful
                { scope = Transports
                , files = [ "elm-kernel-cpp/src/core/JsArrayExports.cpp" ]
                , evidence = "class: full | entry: JsArrayExports.cpp:Elm_Kernel_JsArray_foldr:655-657 | helpers: foldImpl:576-649 (dir :603) | type: elm/core/1.0.5/src/Elm/JsArray.elm:136 | B1: apply-only via eco_apply_closure_eval :184; acc by identity :638 | B2: roots + stack locals only :598-623 | B3: no allocClosure/Tag_Closure | audited: 2026-10-05 (re-audit, plans/wide-object-tail-kind-words-phase-2.md 2.3/2.6: the only C++ changes are the EvalParamLayout encoding (hand-written byte arrays replaced by makeEvalParamLayout values with the same kinds; u16 num_params) and, in ListExports, closure kinds read from a ClosureKinds snapshot; no application, retention, fabrication or type change)"
                }
          )
        , ( ( "JsArray", "indexedMap" )
          , TypeFaithful
                { scope = Transports
                , files = [ "elm-kernel-cpp/src/core/JsArrayExports.cpp" ]
                , evidence = "class: full | entry: JsArrayExports.cpp:Elm_Kernel_JsArray_indexedMap:519-560 | helpers: callBinaryIndexMapClosureTyped:152 | type: elm/core/1.0.5/src/Elm/JsArray.elm:153 | B1: apply-only via eco_apply_closure_eval :161; elems are args only | B2: no store outside result | B3: no allocClosure/Tag_Closure | audited: 2026-10-05 (re-audit, plans/wide-object-tail-kind-words-phase-2.md 2.3/2.6: the only C++ changes are the EvalParamLayout encoding (hand-written byte arrays replaced by makeEvalParamLayout values with the same kinds; u16 num_params) and, in ListExports, closure kinds read from a ClosureKinds snapshot; no application, retention, fabrication or type change)"
                }
          )
        , ( ( "JsArray", "initialize" )
          , TypeFaithful
                { scope = Transports
                , files = [ "elm-kernel-cpp/src/core/JsArrayExports.cpp" ]
                , evidence = "class: full | entry: JsArrayExports.cpp:Elm_Kernel_JsArray_initialize:422-455 | helpers: callUnaryInitClosureTyped:80, pushTypedResult:126 | type: elm/core/1.0.5/src/Elm/JsArray.elm:80 | B1: apply-only via eco_apply_closure_eval :89 | B2: only the result builder mutated | B3: no allocClosure/Tag_Closure | audited: 2026-10-05 (re-audit, plans/wide-object-tail-kind-words-phase-2.md 2.3/2.6: the only C++ changes are the EvalParamLayout encoding (hand-written byte arrays replaced by makeEvalParamLayout values with the same kinds; u16 num_params) and, in ListExports, closure kinds read from a ClosureKinds snapshot; no application, retention, fabrication or type change)"
                }
          )
        , ( ( "JsArray", "initializeFromList" )
          , TypeFaithful
                { scope = Transports
                , files = [ "elm-kernel-cpp/src/core/JsArrayExports.cpp", "elm-kernel-cpp/src/core/JsArray.cpp", "elm-kernel-cpp/src/core/JsArray.hpp" ]
                , evidence = "class: cheap | entry: JsArrayExports.cpp:Elm_Kernel_JsArray_initializeFromList:457-461 | helpers: JsArray.cpp:initializeFromList:14 | type: elm/core/1.0.5/src/Elm/JsArray.elm:95 | B1: no closure param; heads by identity :40, suffix view :54-72 | B2: writes only fresh arr | B3: no allocClosure/Tag_Closure | audited: 2026-10-05 (re-audit, plans/wide-object-tail-kind-words-phase-2.md 2.3/2.6: the only C++ changes are the EvalParamLayout encoding (hand-written byte arrays replaced by makeEvalParamLayout values with the same kinds; u16 num_params) and, in ListExports, closure kinds read from a ClosureKinds snapshot; no application, retention, fabrication or type change)"
                }
          )
        , ( ( "JsArray", "length" )
          , TypeFaithful
                { scope = Transports
                , files = [ "elm-kernel-cpp/src/core/JsArrayExports.cpp" ]
                , evidence = "class: cheap | entry: JsArrayExports.cpp:Elm_Kernel_JsArray_length:204-208 | type: elm/core/1.0.5/src/Elm/JsArray.elm:67 (JsArray a -> Int) | B1: elements never read, only ElmArray::length :207 | B2: no writes of any kind | B3: no allocClosure/Tag_Closure | audited: 2026-10-05 (re-audit, plans/wide-object-tail-kind-words-phase-2.md 2.3/2.6: the only C++ changes are the EvalParamLayout encoding (hand-written byte arrays replaced by makeEvalParamLayout values with the same kinds; u16 num_params) and, in ListExports, closure kinds read from a ClosureKinds snapshot; no application, retention, fabrication or type change)"
                }
          )
        , ( ( "JsArray", "map" )
          , TypeFaithful
                { scope = Transports
                , files = [ "elm-kernel-cpp/src/core/JsArrayExports.cpp" ]
                , evidence = "class: full | entry: JsArrayExports.cpp:Elm_Kernel_JsArray_map:463-517 | helpers: pushTypedResult:126 | type: elm/core/1.0.5/src/Elm/JsArray.elm:143 | B1: apply-only via eco_apply_closure_eval :509; elems are args only :494-497 | B2: no store outside result | B3: no allocClosure/Tag_Closure | audited: 2026-10-05 (re-audit, plans/wide-object-tail-kind-words-phase-2.md 2.3/2.6: the only C++ changes are the EvalParamLayout encoding (hand-written byte arrays replaced by makeEvalParamLayout values with the same kinds; u16 num_params) and, in ListExports, closure kinds read from a ClosureKinds snapshot; no application, retention, fabrication or type change)"
                }
          )
        , ( ( "JsArray", "push" )
          , TypeFaithful
                { scope = Transports
                , files = [ "elm-kernel-cpp/src/core/JsArrayExports.cpp" ]
                , evidence = "class: cheap | entry: JsArrayExports.cpp:Elm_Kernel_JsArray_push:268-318 | helpers: copyAndExtendForPush:711 | type: elm/core/1.0.5/src/Elm/JsArray.elm:122 | B1: :297-299 copy words verbatim, :306 stores value unchanged | B2: writes confined to fresh dst | B3: no allocClosure/Tag_Closure | audited: 2026-10-05 (re-audit, plans/wide-object-tail-kind-words-phase-2.md 2.3/2.6: the only C++ changes are the EvalParamLayout encoding (hand-written byte arrays replaced by makeEvalParamLayout values with the same kinds; u16 num_params) and, in ListExports, closure kinds read from a ClosureKinds snapshot; no application, retention, fabrication or type change)"
                }
          )
        , ( ( "JsArray", "singleton" )
          , TypeFaithful
                { scope = Transports
                , files = [ "elm-kernel-cpp/src/core/JsArrayExports.cpp" ]
                , evidence = "class: cheap | entry: JsArrayExports.cpp:Elm_Kernel_JsArray_singleton:197-202 | helpers: elm_array_singleton_box:694 | type: elm/core/1.0.5/src/Elm/JsArray.elm:60 (a -> JsArray a) | B1: :199-200 move the arg word unchanged into elements[0] | B2: no store outside result | B3: no allocClosure/Tag_Closure | audited: 2026-10-05 (re-audit, plans/wide-object-tail-kind-words-phase-2.md 2.3/2.6: the only C++ changes are the EvalParamLayout encoding (hand-written byte arrays replaced by makeEvalParamLayout values with the same kinds; u16 num_params) and, in ListExports, closure kinds read from a ClosureKinds snapshot; no application, retention, fabrication or type change)"
                }
          )
        , ( ( "JsArray", "slice" )
          , TypeFaithful
                { scope = Transports
                , files = [ "elm-kernel-cpp/src/core/JsArrayExports.cpp" ]
                , evidence = "class: cheap | entry: JsArrayExports.cpp:Elm_Kernel_JsArray_slice:320-356 | helpers: elm_array_slice:800-833 | type: elm/core/1.0.5/src/Elm/JsArray.elm:169 | B1: :342-344 copy a contiguous run of element words verbatim, B1(b) | B2: writes confined to fresh dst | B3: no allocClosure/Tag_Closure | audited: 2026-10-05 (re-audit, plans/wide-object-tail-kind-words-phase-2.md 2.3/2.6: the only C++ changes are the EvalParamLayout encoding (hand-written byte arrays replaced by makeEvalParamLayout values with the same kinds; u16 num_params) and, in ListExports, closure kinds read from a ClosureKinds snapshot; no application, retention, fabrication or type change)"
                }
          )
        , ( ( "JsArray", "unsafeGet" )
          , TypeFaithful
                { scope = Transports
                , files = [ "elm-kernel-cpp/src/core/JsArrayExports.cpp" ]
                , evidence = "class: cheap | entry: JsArrayExports.cpp:Elm_Kernel_JsArray_unsafeGet:210-223 | type: elm/core/1.0.5/src/Elm/JsArray.elm:105 (Int -> JsArray a -> a) | B1: :215 reads the slot, :221 returns the stored word unchanged, B1(b) | B2: read-only apart from primitive boxing | B3: no allocClosure/Tag_Closure | audited: 2026-10-05 (re-audit, plans/wide-object-tail-kind-words-phase-2.md 2.3/2.6: the only C++ changes are the EvalParamLayout encoding (hand-written byte arrays replaced by makeEvalParamLayout values with the same kinds; u16 num_params) and, in ListExports, closure kinds read from a ClosureKinds snapshot; no application, retention, fabrication or type change)"
                }
          )
        , ( ( "JsArray", "unsafeSet" )
          , TypeFaithful
                { scope = Transports
                , files = [ "elm-kernel-cpp/src/core/JsArrayExports.cpp" ]
                , evidence = "class: cheap | entry: JsArrayExports.cpp:Elm_Kernel_JsArray_unsafeSet:225-266 | helpers: copyForUnsafeSet:888 | type: elm/core/1.0.5/src/Elm/JsArray.elm:115 | B1: :244-246 copy words verbatim, :253 stores value unchanged, B1(b) | B2: writes confined to fresh dst | B3: no allocClosure/Tag_Closure | audited: 2026-10-05 (re-audit, plans/wide-object-tail-kind-words-phase-2.md 2.3/2.6: the only C++ changes are the EvalParamLayout encoding (hand-written byte arrays replaced by makeEvalParamLayout values with the same kinds; u16 num_params) and, in ListExports, closure kinds read from a ClosureKinds snapshot; no application, retention, fabrication or type change)"
                }
          )
        , ( ( "Json", "addField" )
          , TypeFaithful
                { scope = Inert
                , files = [ "elm-kernel-cpp/src/json/JsonExports.cpp" ]
                , evidence = "class: vacuous | entry: JsonExports.cpp:Elm_Kernel_Json_addField:1876-1924 | helpers: none | type: INFERRED elm/json/1.1.4/src/Json/Encode.elm:202 (String -> Value -> Value -> Value); Value nullary | B1: vacuous (no function-capable position) | B2: result-only writes :1896-1921 | B3: no closure alloc | audited: 2026-08-29 | re-audit 2026-08-29: rewrapEscapingResult escape rewrap added at Json_run/runOnString (MONO_013 Ok-payload re-store only; no apply, no retention, no closure mint; B1/B2/B3 unchanged); Json_run additionally bridges ENC_*→CTOR_JSON_* values via the existing elmToJson/jsonToHeap converters (read-then-rebuild, no apply/retention/closure) | re-audit 2026-09-26: threaded-gc-04b GC-safety fixes only - DEC_ARRAY now builds a proper Elm Array tree (buildElmArrayFromElements: fresh JsArray/Custom nodes over the decoded Ok payloads, returned by THIS call) and runDecoder's recursive calls re-encode the rooted jvalHP instead of the unrooted parameter copy; JSON arrays over jsonArrayChunkSize() elements are stored chunked (CTOR_JSON_ARRAY_CHUNKED: fresh chunk ElmArrays + an index, built and returned by the same jsonToHeap call) and every reader goes through the allocation-free jsonArrayLength/jsonArrayAt accessors; no apply, no retention, no closure mint; B1/B2/B3 unchanged | re-audit 2026-10-06: plans/kernel-root-stack-bounded-rooting.md - JsonExports.cpp rooting only (rootInChunks -> rootBuffer: one all-ones shadow-root record per decode buffer instead of one per 64 slots); no apply, no retention, no closure mint; B1/B2/B3 unchanged"
                }
          )
        , ( ( "Json", "addEntry" )
          , TypeFaithful
                { scope =
                    -- The same type as the kernel's annotation in
                    -- Compiler.Type.KernelIntrinsics: the encoder takes the
                    -- folded element, and the accumulator, the encoder's result
                    -- and the kernel's result are all one Value.
                    TransportsAs
                        (TsFun (TsFun (TsVar "a") tsValue)
                            (TsFun (TsVar "a") (TsFun tsValue tsValue))
                        )
                , files = [ "elm-kernel-cpp/src/json/JsonExports.cpp" ]
                , evidence = "class: full | entry: JsonExports.cpp:Elm_Kernel_Json_addEntry:1835-1867 | type: DECLARED (a -> Value) -> a -> Value -> Value, pinned equal to the intrinsic annotation by KernelLicenseTest; no aliasing def, used partially applied at Json/Encode.elm:162/170/178 | B1: apply-only, eco_apply_closure :1846 is func's ONLY use; entry passed as its arg :1845 | B2: no static/global/task write; arrayHP/encodedHP are StackRootGuard locals :1843-1857 | B3: cons :1856 allocates a LIST CELL over the callback's RETURN, never a closure; no allocClosure/Tag_Closure in file | audited: 2026-08-29 | re-audit 2026-08-29: rewrapEscapingResult escape rewrap added at Json_run/runOnString (MONO_013 Ok-payload re-store only; no apply, no retention, no closure mint; B1/B2/B3 unchanged); Json_run additionally bridges ENC_*→CTOR_JSON_* values via the existing elmToJson/jsonToHeap converters (read-then-rebuild, no apply/retention/closure) | re-audit 2026-09-26: threaded-gc-04b GC-safety fixes only - DEC_ARRAY now builds a proper Elm Array tree (buildElmArrayFromElements: fresh JsArray/Custom nodes over the decoded Ok payloads, returned by THIS call) and runDecoder's recursive calls re-encode the rooted jvalHP instead of the unrooted parameter copy; JSON arrays over jsonArrayChunkSize() elements are stored chunked (CTOR_JSON_ARRAY_CHUNKED: fresh chunk ElmArrays + an index, built and returned by the same jsonToHeap call) and every reader goes through the allocation-free jsonArrayLength/jsonArrayAt accessors; no apply, no retention, no closure mint; B1/B2/B3 unchanged | re-audit 2026-10-06: plans/kernel-root-stack-bounded-rooting.md - JsonExports.cpp rooting only (rootInChunks -> rootBuffer: one all-ones shadow-root record per decode buffer instead of one per 64 slots); no apply, no retention, no closure mint; B1/B2/B3 unchanged"
                }
          )
        , ( ( "Json", "decodeArray" )
          , TypeFaithful
                { scope = Transports
                , files = [ "elm-kernel-cpp/src/json/JsonExports.cpp" ]
                , evidence = "class: full | entry: JsonExports.cpp:Elm_Kernel_Json_decodeArray:1422-1424 | helpers: JsonExports.cpp:makeDecoder1:479-493, makeDecoder2:507-525 | type: elm/json/1.1.4/src/Json/Decode.elm (Decoder a -> Decoder (Array a)) | B1: arguments stored VERBATIM into the DEC_ARRAY decoder Custom; the decoder is then consumed by Json.run/runOnString, which take it AS AN ARGUMENT and drive the decode SYNCHRONOUSLY in that same call (JsonExports.cpp:1589-1645) - so every hop is threaded through shared type variables and there is no cross-call edge. Structurally identical to Scheduler.andThen and to JsArray.singleton | B2: the only store is into the value THIS call returns - no static, no mailbox, no other call's object | B3: no allocClosure - makeDecoder* is a record constructor, not a closure mint | audited: 2026-08-29 | re-audit 2026-08-29: rewrapEscapingResult escape rewrap added at Json_run/runOnString (MONO_013 Ok-payload re-store only; no apply, no retention, no closure mint; B1/B2/B3 unchanged); Json_run additionally bridges ENC_*→CTOR_JSON_* values via the existing elmToJson/jsonToHeap converters (read-then-rebuild, no apply/retention/closure) | re-audit 2026-09-26: threaded-gc-04b GC-safety fixes only - DEC_ARRAY now builds a proper Elm Array tree (buildElmArrayFromElements: fresh JsArray/Custom nodes over the decoded Ok payloads, returned by THIS call) and runDecoder's recursive calls re-encode the rooted jvalHP instead of the unrooted parameter copy; JSON arrays over jsonArrayChunkSize() elements are stored chunked (CTOR_JSON_ARRAY_CHUNKED: fresh chunk ElmArrays + an index, built and returned by the same jsonToHeap call) and every reader goes through the allocation-free jsonArrayLength/jsonArrayAt accessors; no apply, no retention, no closure mint; B1/B2/B3 unchanged | re-audit 2026-10-06: plans/kernel-root-stack-bounded-rooting.md - JsonExports.cpp rooting only (rootInChunks -> rootBuffer: one all-ones shadow-root record per decode buffer instead of one per 64 slots); no apply, no retention, no closure mint; B1/B2/B3 unchanged"
                }
          )
        , ( ( "Json", "andThen" )
          , TypeFaithful
                { scope = Transports
                , files = [ "elm-kernel-cpp/src/json/JsonExports.cpp" ]
                , evidence = "class: full | entry: JsonExports.cpp:Elm_Kernel_Json_andThen:1454-1456 | helpers: JsonExports.cpp:makeDecoder1:479-493, makeDecoder2:507-525 | type: elm/json/1.1.4/src/Json/Decode.elm ((a -> Decoder b) -> Decoder a -> Decoder b) | B1: arguments stored VERBATIM into the DEC_ANDTHEN decoder Custom; the decoder is then consumed by Json.run/runOnString, which take it AS AN ARGUMENT and drive the decode SYNCHRONOUSLY in that same call (JsonExports.cpp:1589-1645) - so every hop is threaded through shared type variables and there is no cross-call edge. Structurally identical to Scheduler.andThen and to JsArray.singleton | B2: the only store is into the value THIS call returns - no static, no mailbox, no other call's object | B3: no allocClosure - makeDecoder* is a record constructor, not a closure mint | audited: 2026-08-29 | re-audit 2026-08-29: rewrapEscapingResult escape rewrap added at Json_run/runOnString (MONO_013 Ok-payload re-store only; no apply, no retention, no closure mint; B1/B2/B3 unchanged); Json_run additionally bridges ENC_*→CTOR_JSON_* values via the existing elmToJson/jsonToHeap converters (read-then-rebuild, no apply/retention/closure) | re-audit 2026-09-26: threaded-gc-04b GC-safety fixes only - DEC_ARRAY now builds a proper Elm Array tree (buildElmArrayFromElements: fresh JsArray/Custom nodes over the decoded Ok payloads, returned by THIS call) and runDecoder's recursive calls re-encode the rooted jvalHP instead of the unrooted parameter copy; JSON arrays over jsonArrayChunkSize() elements are stored chunked (CTOR_JSON_ARRAY_CHUNKED: fresh chunk ElmArrays + an index, built and returned by the same jsonToHeap call) and every reader goes through the allocation-free jsonArrayLength/jsonArrayAt accessors; no apply, no retention, no closure mint; B1/B2/B3 unchanged | re-audit 2026-10-06: plans/kernel-root-stack-bounded-rooting.md - JsonExports.cpp rooting only (rootInChunks -> rootBuffer: one all-ones shadow-root record per decode buffer instead of one per 64 slots); no apply, no retention, no closure mint; B1/B2/B3 unchanged"
                }
          )
        , ( ( "Json", "decodeBool" )
          , TypeFaithful
                { scope = Inert
                , files = [ "elm-kernel-cpp/src/json/JsonExports.cpp" ]
                , evidence = "class: vacuous | entry: JsonExports.cpp:Elm_Kernel_Json_decodeBool:1402-1404 | helpers: makeDecoder0:466-468 | type: elm/json/1.1.4/src/Json/Decode.elm:86 (Decoder Bool) | B1: vacuous (no function-capable position) | B2: embedded constant, stores nothing | B3: no closure alloc | audited: 2026-08-29 | re-audit 2026-08-29: rewrapEscapingResult escape rewrap added at Json_run/runOnString (MONO_013 Ok-payload re-store only; no apply, no retention, no closure mint; B1/B2/B3 unchanged); Json_run additionally bridges ENC_*→CTOR_JSON_* values via the existing elmToJson/jsonToHeap converters (read-then-rebuild, no apply/retention/closure) | re-audit 2026-09-26: threaded-gc-04b GC-safety fixes only - DEC_ARRAY now builds a proper Elm Array tree (buildElmArrayFromElements: fresh JsArray/Custom nodes over the decoded Ok payloads, returned by THIS call) and runDecoder's recursive calls re-encode the rooted jvalHP instead of the unrooted parameter copy; JSON arrays over jsonArrayChunkSize() elements are stored chunked (CTOR_JSON_ARRAY_CHUNKED: fresh chunk ElmArrays + an index, built and returned by the same jsonToHeap call) and every reader goes through the allocation-free jsonArrayLength/jsonArrayAt accessors; no apply, no retention, no closure mint; B1/B2/B3 unchanged | re-audit 2026-10-06: plans/kernel-root-stack-bounded-rooting.md - JsonExports.cpp rooting only (rootInChunks -> rootBuffer: one all-ones shadow-root record per decode buffer instead of one per 64 slots); no apply, no retention, no closure mint; B1/B2/B3 unchanged"
                }
          )
        , ( ( "Json", "decodeField" )
          , TypeFaithful
                { scope = Transports
                , files = [ "elm-kernel-cpp/src/json/JsonExports.cpp" ]
                , evidence = "class: full | entry: JsonExports.cpp:Elm_Kernel_Json_decodeField:1426-1428 | helpers: JsonExports.cpp:makeDecoder1:479-493, makeDecoder2:507-525 | type: elm/json/1.1.4/src/Json/Decode.elm (String -> Decoder a -> Decoder a) | B1: arguments stored VERBATIM into the DEC_FIELD decoder Custom; the decoder is then consumed by Json.run/runOnString, which take it AS AN ARGUMENT and drive the decode SYNCHRONOUSLY in that same call (JsonExports.cpp:1589-1645) - so every hop is threaded through shared type variables and there is no cross-call edge. Structurally identical to Scheduler.andThen and to JsArray.singleton | B2: the only store is into the value THIS call returns - no static, no mailbox, no other call's object | B3: no allocClosure - makeDecoder* is a record constructor, not a closure mint | audited: 2026-08-29 | re-audit 2026-08-29: rewrapEscapingResult escape rewrap added at Json_run/runOnString (MONO_013 Ok-payload re-store only; no apply, no retention, no closure mint; B1/B2/B3 unchanged); Json_run additionally bridges ENC_*→CTOR_JSON_* values via the existing elmToJson/jsonToHeap converters (read-then-rebuild, no apply/retention/closure) | re-audit 2026-09-26: threaded-gc-04b GC-safety fixes only - DEC_ARRAY now builds a proper Elm Array tree (buildElmArrayFromElements: fresh JsArray/Custom nodes over the decoded Ok payloads, returned by THIS call) and runDecoder's recursive calls re-encode the rooted jvalHP instead of the unrooted parameter copy; JSON arrays over jsonArrayChunkSize() elements are stored chunked (CTOR_JSON_ARRAY_CHUNKED: fresh chunk ElmArrays + an index, built and returned by the same jsonToHeap call) and every reader goes through the allocation-free jsonArrayLength/jsonArrayAt accessors; no apply, no retention, no closure mint; B1/B2/B3 unchanged | re-audit 2026-10-06: plans/kernel-root-stack-bounded-rooting.md - JsonExports.cpp rooting only (rootInChunks -> rootBuffer: one all-ones shadow-root record per decode buffer instead of one per 64 slots); no apply, no retention, no closure mint; B1/B2/B3 unchanged"
                }
          )
        , ( ( "Json", "decodeFloat" )
          , TypeFaithful
                { scope = Inert
                , files = [ "elm-kernel-cpp/src/json/JsonExports.cpp" ]
                , evidence = "class: vacuous | entry: JsonExports.cpp:Elm_Kernel_Json_decodeFloat:1410-1412 | helpers: makeDecoder0:466-468 | type: elm/json/1.1.4/src/Json/Decode.elm:112 (Decoder Float) | B1: vacuous (no function-capable position) | B2: embedded constant, stores nothing | B3: no closure alloc | audited: 2026-08-29 | re-audit 2026-08-29: rewrapEscapingResult escape rewrap added at Json_run/runOnString (MONO_013 Ok-payload re-store only; no apply, no retention, no closure mint; B1/B2/B3 unchanged); Json_run additionally bridges ENC_*→CTOR_JSON_* values via the existing elmToJson/jsonToHeap converters (read-then-rebuild, no apply/retention/closure) | re-audit 2026-09-26: threaded-gc-04b GC-safety fixes only - DEC_ARRAY now builds a proper Elm Array tree (buildElmArrayFromElements: fresh JsArray/Custom nodes over the decoded Ok payloads, returned by THIS call) and runDecoder's recursive calls re-encode the rooted jvalHP instead of the unrooted parameter copy; JSON arrays over jsonArrayChunkSize() elements are stored chunked (CTOR_JSON_ARRAY_CHUNKED: fresh chunk ElmArrays + an index, built and returned by the same jsonToHeap call) and every reader goes through the allocation-free jsonArrayLength/jsonArrayAt accessors; no apply, no retention, no closure mint; B1/B2/B3 unchanged | re-audit 2026-10-06: plans/kernel-root-stack-bounded-rooting.md - JsonExports.cpp rooting only (rootInChunks -> rootBuffer: one all-ones shadow-root record per decode buffer instead of one per 64 slots); no apply, no retention, no closure mint; B1/B2/B3 unchanged"
                }
          )
        , ( ( "Json", "decodeIndex" )
          , TypeFaithful
                { scope = Transports
                , files = [ "elm-kernel-cpp/src/json/JsonExports.cpp" ]
                , evidence = "class: full | entry: JsonExports.cpp:Elm_Kernel_Json_decodeIndex:1430-1432 | helpers: JsonExports.cpp:makeDecoder1:479-493, makeDecoder2:507-525 | type: elm/json/1.1.4/src/Json/Decode.elm (Int -> Decoder a -> Decoder a) | B1: arguments stored VERBATIM into the DEC_INDEX decoder Custom; the decoder is then consumed by Json.run/runOnString, which take it AS AN ARGUMENT and drive the decode SYNCHRONOUSLY in that same call (JsonExports.cpp:1589-1645) - so every hop is threaded through shared type variables and there is no cross-call edge. Structurally identical to Scheduler.andThen and to JsArray.singleton | B2: the only store is into the value THIS call returns - no static, no mailbox, no other call's object | B3: no allocClosure - makeDecoder* is a record constructor, not a closure mint | audited: 2026-08-29 | re-audit 2026-08-29: rewrapEscapingResult escape rewrap added at Json_run/runOnString (MONO_013 Ok-payload re-store only; no apply, no retention, no closure mint; B1/B2/B3 unchanged); Json_run additionally bridges ENC_*→CTOR_JSON_* values via the existing elmToJson/jsonToHeap converters (read-then-rebuild, no apply/retention/closure) | re-audit 2026-09-26: threaded-gc-04b GC-safety fixes only - DEC_ARRAY now builds a proper Elm Array tree (buildElmArrayFromElements: fresh JsArray/Custom nodes over the decoded Ok payloads, returned by THIS call) and runDecoder's recursive calls re-encode the rooted jvalHP instead of the unrooted parameter copy; JSON arrays over jsonArrayChunkSize() elements are stored chunked (CTOR_JSON_ARRAY_CHUNKED: fresh chunk ElmArrays + an index, built and returned by the same jsonToHeap call) and every reader goes through the allocation-free jsonArrayLength/jsonArrayAt accessors; no apply, no retention, no closure mint; B1/B2/B3 unchanged | re-audit 2026-10-06: plans/kernel-root-stack-bounded-rooting.md - JsonExports.cpp rooting only (rootInChunks -> rootBuffer: one all-ones shadow-root record per decode buffer instead of one per 64 slots); no apply, no retention, no closure mint; B1/B2/B3 unchanged"
                }
          )
        , ( ( "Json", "decodeInt" )
          , TypeFaithful
                { scope = Inert
                , files = [ "elm-kernel-cpp/src/json/JsonExports.cpp" ]
                , evidence = "class: vacuous | entry: JsonExports.cpp:Elm_Kernel_Json_decodeInt:1406-1408 | helpers: makeDecoder0:466-468 | type: elm/json/1.1.4/src/Json/Decode.elm:99 (Decoder Int) | B1: vacuous (no function-capable position) | B2: embedded constant, stores nothing | B3: no closure alloc | audited: 2026-08-29 | re-audit 2026-08-29: rewrapEscapingResult escape rewrap added at Json_run/runOnString (MONO_013 Ok-payload re-store only; no apply, no retention, no closure mint; B1/B2/B3 unchanged); Json_run additionally bridges ENC_*→CTOR_JSON_* values via the existing elmToJson/jsonToHeap converters (read-then-rebuild, no apply/retention/closure) | re-audit 2026-09-26: threaded-gc-04b GC-safety fixes only - DEC_ARRAY now builds a proper Elm Array tree (buildElmArrayFromElements: fresh JsArray/Custom nodes over the decoded Ok payloads, returned by THIS call) and runDecoder's recursive calls re-encode the rooted jvalHP instead of the unrooted parameter copy; JSON arrays over jsonArrayChunkSize() elements are stored chunked (CTOR_JSON_ARRAY_CHUNKED: fresh chunk ElmArrays + an index, built and returned by the same jsonToHeap call) and every reader goes through the allocation-free jsonArrayLength/jsonArrayAt accessors; no apply, no retention, no closure mint; B1/B2/B3 unchanged | re-audit 2026-10-06: plans/kernel-root-stack-bounded-rooting.md - JsonExports.cpp rooting only (rootInChunks -> rootBuffer: one all-ones shadow-root record per decode buffer instead of one per 64 slots); no apply, no retention, no closure mint; B1/B2/B3 unchanged"
                }
          )
        , ( ( "Json", "decodeList" )
          , TypeFaithful
                { scope = Transports
                , files = [ "elm-kernel-cpp/src/json/JsonExports.cpp" ]
                , evidence = "class: full | entry: JsonExports.cpp:Elm_Kernel_Json_decodeList:1418-1420 | helpers: JsonExports.cpp:makeDecoder1:479-493, makeDecoder2:507-525 | type: elm/json/1.1.4/src/Json/Decode.elm (Decoder a -> Decoder (List a)) | B1: arguments stored VERBATIM into the DEC_LIST decoder Custom; the decoder is then consumed by Json.run/runOnString, which take it AS AN ARGUMENT and drive the decode SYNCHRONOUSLY in that same call (JsonExports.cpp:1589-1645) - so every hop is threaded through shared type variables and there is no cross-call edge. Structurally identical to Scheduler.andThen and to JsArray.singleton | B2: the only store is into the value THIS call returns - no static, no mailbox, no other call's object | B3: no allocClosure - makeDecoder* is a record constructor, not a closure mint | audited: 2026-08-29 | re-audit 2026-08-29: rewrapEscapingResult escape rewrap added at Json_run/runOnString (MONO_013 Ok-payload re-store only; no apply, no retention, no closure mint; B1/B2/B3 unchanged); Json_run additionally bridges ENC_*→CTOR_JSON_* values via the existing elmToJson/jsonToHeap converters (read-then-rebuild, no apply/retention/closure) | re-audit 2026-09-26: threaded-gc-04b GC-safety fixes only - DEC_ARRAY now builds a proper Elm Array tree (buildElmArrayFromElements: fresh JsArray/Custom nodes over the decoded Ok payloads, returned by THIS call) and runDecoder's recursive calls re-encode the rooted jvalHP instead of the unrooted parameter copy; JSON arrays over jsonArrayChunkSize() elements are stored chunked (CTOR_JSON_ARRAY_CHUNKED: fresh chunk ElmArrays + an index, built and returned by the same jsonToHeap call) and every reader goes through the allocation-free jsonArrayLength/jsonArrayAt accessors; no apply, no retention, no closure mint; B1/B2/B3 unchanged | re-audit 2026-10-06: plans/kernel-root-stack-bounded-rooting.md - JsonExports.cpp rooting only (rootInChunks -> rootBuffer: one all-ones shadow-root record per decode buffer instead of one per 64 slots); no apply, no retention, no closure mint; B1/B2/B3 unchanged"
                }
          )
        , ( ( "Json", "decodeKeyValuePairs" )
          , TypeFaithful
                { scope = Transports
                , files = [ "elm-kernel-cpp/src/json/JsonExports.cpp" ]
                , evidence = "class: full | entry: JsonExports.cpp:Elm_Kernel_Json_decodeKeyValuePairs:1434-1436 | helpers: JsonExports.cpp:makeDecoder1:479-493, makeDecoder2:507-525 | type: elm/json/1.1.4/src/Json/Decode.elm (Decoder a -> Decoder (List (String, a))) | B1: arguments stored VERBATIM into the DEC_KEYVALUEPAIRS decoder Custom; the decoder is then consumed by Json.run/runOnString, which take it AS AN ARGUMENT and drive the decode SYNCHRONOUSLY in that same call (JsonExports.cpp:1589-1645) - so every hop is threaded through shared type variables and there is no cross-call edge. Structurally identical to Scheduler.andThen and to JsArray.singleton | B2: the only store is into the value THIS call returns - no static, no mailbox, no other call's object | B3: no allocClosure - makeDecoder* is a record constructor, not a closure mint | audited: 2026-08-29 | re-audit 2026-08-29: rewrapEscapingResult escape rewrap added at Json_run/runOnString (MONO_013 Ok-payload re-store only; no apply, no retention, no closure mint; B1/B2/B3 unchanged); Json_run additionally bridges ENC_*→CTOR_JSON_* values via the existing elmToJson/jsonToHeap converters (read-then-rebuild, no apply/retention/closure) | re-audit 2026-09-26: threaded-gc-04b GC-safety fixes only - DEC_ARRAY now builds a proper Elm Array tree (buildElmArrayFromElements: fresh JsArray/Custom nodes over the decoded Ok payloads, returned by THIS call) and runDecoder's recursive calls re-encode the rooted jvalHP instead of the unrooted parameter copy; JSON arrays over jsonArrayChunkSize() elements are stored chunked (CTOR_JSON_ARRAY_CHUNKED: fresh chunk ElmArrays + an index, built and returned by the same jsonToHeap call) and every reader goes through the allocation-free jsonArrayLength/jsonArrayAt accessors; no apply, no retention, no closure mint; B1/B2/B3 unchanged | re-audit 2026-10-06: plans/kernel-root-stack-bounded-rooting.md - JsonExports.cpp rooting only (rootInChunks -> rootBuffer: one all-ones shadow-root record per decode buffer instead of one per 64 slots); no apply, no retention, no closure mint; B1/B2/B3 unchanged"
                }
          )
        , ( ( "Json", "decodeNull" )
          , TypeFaithful
                { scope = Transports
                , files = [ "elm-kernel-cpp/src/json/JsonExports.cpp" ]
                , evidence = "class: full | entry: JsonExports.cpp:Elm_Kernel_Json_decodeNull:1414-1416 | helpers: JsonExports.cpp:makeDecoder1:479-493, makeDecoder2:507-525 | type: elm/json/1.1.4/src/Json/Decode.elm (a -> Decoder a) | B1: arguments stored VERBATIM into the DEC_NULL decoder Custom; the decoder is then consumed by Json.run/runOnString, which take it AS AN ARGUMENT and drive the decode SYNCHRONOUSLY in that same call (JsonExports.cpp:1589-1645) - so every hop is threaded through shared type variables and there is no cross-call edge. Structurally identical to Scheduler.andThen and to JsArray.singleton | B2: the only store is into the value THIS call returns - no static, no mailbox, no other call's object | B3: no allocClosure - makeDecoder* is a record constructor, not a closure mint | audited: 2026-08-29 | re-audit 2026-08-29: rewrapEscapingResult escape rewrap added at Json_run/runOnString (MONO_013 Ok-payload re-store only; no apply, no retention, no closure mint; B1/B2/B3 unchanged); Json_run additionally bridges ENC_*→CTOR_JSON_* values via the existing elmToJson/jsonToHeap converters (read-then-rebuild, no apply/retention/closure) | re-audit 2026-09-26: threaded-gc-04b GC-safety fixes only - DEC_ARRAY now builds a proper Elm Array tree (buildElmArrayFromElements: fresh JsArray/Custom nodes over the decoded Ok payloads, returned by THIS call) and runDecoder's recursive calls re-encode the rooted jvalHP instead of the unrooted parameter copy; JSON arrays over jsonArrayChunkSize() elements are stored chunked (CTOR_JSON_ARRAY_CHUNKED: fresh chunk ElmArrays + an index, built and returned by the same jsonToHeap call) and every reader goes through the allocation-free jsonArrayLength/jsonArrayAt accessors; no apply, no retention, no closure mint; B1/B2/B3 unchanged | re-audit 2026-10-06: plans/kernel-root-stack-bounded-rooting.md - JsonExports.cpp rooting only (rootInChunks -> rootBuffer: one all-ones shadow-root record per decode buffer instead of one per 64 slots); no apply, no retention, no closure mint; B1/B2/B3 unchanged"
                }
          )
        , ( ( "Json", "decodeString" )
          , TypeFaithful
                { scope = Inert
                , files = [ "elm-kernel-cpp/src/json/JsonExports.cpp" ]
                , evidence = "class: vacuous | entry: JsonExports.cpp:Elm_Kernel_Json_decodeString:1398-1400 | helpers: makeDecoder0:466-468 | type: elm/json/1.1.4/src/Json/Decode.elm:73 (Decoder String) | B1: vacuous (no function-capable position) | B2: embedded constant, stores nothing | B3: no closure alloc | audited: 2026-08-29 | re-audit 2026-08-29: rewrapEscapingResult escape rewrap added at Json_run/runOnString (MONO_013 Ok-payload re-store only; no apply, no retention, no closure mint; B1/B2/B3 unchanged); Json_run additionally bridges ENC_*→CTOR_JSON_* values via the existing elmToJson/jsonToHeap converters (read-then-rebuild, no apply/retention/closure) | re-audit 2026-09-26: threaded-gc-04b GC-safety fixes only - DEC_ARRAY now builds a proper Elm Array tree (buildElmArrayFromElements: fresh JsArray/Custom nodes over the decoded Ok payloads, returned by THIS call) and runDecoder's recursive calls re-encode the rooted jvalHP instead of the unrooted parameter copy; JSON arrays over jsonArrayChunkSize() elements are stored chunked (CTOR_JSON_ARRAY_CHUNKED: fresh chunk ElmArrays + an index, built and returned by the same jsonToHeap call) and every reader goes through the allocation-free jsonArrayLength/jsonArrayAt accessors; no apply, no retention, no closure mint; B1/B2/B3 unchanged | re-audit 2026-10-06: plans/kernel-root-stack-bounded-rooting.md - JsonExports.cpp rooting only (rootInChunks -> rootBuffer: one all-ones shadow-root record per decode buffer instead of one per 64 slots); no apply, no retention, no closure mint; B1/B2/B3 unchanged"
                }
          )
        , ( ( "Json", "decodeValue" )
          , TypeFaithful
                { scope = Inert
                , files = [ "elm-kernel-cpp/src/json/JsonExports.cpp" ]
                , evidence = "class: vacuous | entry: JsonExports.cpp:Elm_Kernel_Json_decodeValue:1438-1440 | helpers: makeDecoder0:466-468 | type: elm/json/1.1.4/src/Json/Decode.elm:685 (Decoder Value); Value nullary | B1: vacuous (no function-capable position) | B2: embedded constant, stores nothing | B3: no closure alloc | audited: 2026-08-29 | re-audit 2026-08-29: rewrapEscapingResult escape rewrap added at Json_run/runOnString (MONO_013 Ok-payload re-store only; no apply, no retention, no closure mint; B1/B2/B3 unchanged); Json_run additionally bridges ENC_*→CTOR_JSON_* values via the existing elmToJson/jsonToHeap converters (read-then-rebuild, no apply/retention/closure) | re-audit 2026-09-26: threaded-gc-04b GC-safety fixes only - DEC_ARRAY now builds a proper Elm Array tree (buildElmArrayFromElements: fresh JsArray/Custom nodes over the decoded Ok payloads, returned by THIS call) and runDecoder's recursive calls re-encode the rooted jvalHP instead of the unrooted parameter copy; JSON arrays over jsonArrayChunkSize() elements are stored chunked (CTOR_JSON_ARRAY_CHUNKED: fresh chunk ElmArrays + an index, built and returned by the same jsonToHeap call) and every reader goes through the allocation-free jsonArrayLength/jsonArrayAt accessors; no apply, no retention, no closure mint; B1/B2/B3 unchanged | re-audit 2026-10-06: plans/kernel-root-stack-bounded-rooting.md - JsonExports.cpp rooting only (rootInChunks -> rootBuffer: one all-ones shadow-root record per decode buffer instead of one per 64 slots); no apply, no retention, no closure mint; B1/B2/B3 unchanged"
                }
          )
        , ( ( "Json", "emptyArray" )
          , TypeFaithful
                { scope = Inert
                , files = [ "elm-kernel-cpp/src/json/JsonExports.cpp" ]
                , evidence = "class: vacuous | entry: JsonExports.cpp:Elm_Kernel_Json_emptyArray:1811-1821 | helpers: none | type: INFERRED elm/json/1.1.4/src/Json/Encode.elm:162 (() -> Value); A3: Elm applies (), C++ 0 params; inert, arity-agnostic unify | B1: vacuous (no function-capable position) | B2: fresh ENC_ARRAY, listNil :1819 | B3: no closure alloc | audited: 2026-08-29 | re-audit 2026-08-29: rewrapEscapingResult escape rewrap added at Json_run/runOnString (MONO_013 Ok-payload re-store only; no apply, no retention, no closure mint; B1/B2/B3 unchanged); Json_run additionally bridges ENC_*→CTOR_JSON_* values via the existing elmToJson/jsonToHeap converters (read-then-rebuild, no apply/retention/closure) | re-audit 2026-09-26: threaded-gc-04b GC-safety fixes only - DEC_ARRAY now builds a proper Elm Array tree (buildElmArrayFromElements: fresh JsArray/Custom nodes over the decoded Ok payloads, returned by THIS call) and runDecoder's recursive calls re-encode the rooted jvalHP instead of the unrooted parameter copy; JSON arrays over jsonArrayChunkSize() elements are stored chunked (CTOR_JSON_ARRAY_CHUNKED: fresh chunk ElmArrays + an index, built and returned by the same jsonToHeap call) and every reader goes through the allocation-free jsonArrayLength/jsonArrayAt accessors; no apply, no retention, no closure mint; B1/B2/B3 unchanged | re-audit 2026-10-06: plans/kernel-root-stack-bounded-rooting.md - JsonExports.cpp rooting only (rootInChunks -> rootBuffer: one all-ones shadow-root record per decode buffer instead of one per 64 slots); no apply, no retention, no closure mint; B1/B2/B3 unchanged"
                }
          )
        , ( ( "Json", "emptyObject" )
          , TypeFaithful
                { scope = Inert
                , files = [ "elm-kernel-cpp/src/json/JsonExports.cpp" ]
                , evidence = "class: vacuous | entry: JsonExports.cpp:Elm_Kernel_Json_emptyObject:1823-1833 | helpers: none | type: INFERRED elm/json/1.1.4/src/Json/Encode.elm:203 (() -> Value); A3: Elm applies (), C++ 0 params; inert, arity-agnostic unify | B1: vacuous (no function-capable position) | B2: fresh ENC_OBJECT, listNil :1831 | B3: no closure alloc | audited: 2026-08-29 | re-audit 2026-08-29: rewrapEscapingResult escape rewrap added at Json_run/runOnString (MONO_013 Ok-payload re-store only; no apply, no retention, no closure mint; B1/B2/B3 unchanged); Json_run additionally bridges ENC_*→CTOR_JSON_* values via the existing elmToJson/jsonToHeap converters (read-then-rebuild, no apply/retention/closure) | re-audit 2026-09-26: threaded-gc-04b GC-safety fixes only - DEC_ARRAY now builds a proper Elm Array tree (buildElmArrayFromElements: fresh JsArray/Custom nodes over the decoded Ok payloads, returned by THIS call) and runDecoder's recursive calls re-encode the rooted jvalHP instead of the unrooted parameter copy; JSON arrays over jsonArrayChunkSize() elements are stored chunked (CTOR_JSON_ARRAY_CHUNKED: fresh chunk ElmArrays + an index, built and returned by the same jsonToHeap call) and every reader goes through the allocation-free jsonArrayLength/jsonArrayAt accessors; no apply, no retention, no closure mint; B1/B2/B3 unchanged | re-audit 2026-10-06: plans/kernel-root-stack-bounded-rooting.md - JsonExports.cpp rooting only (rootInChunks -> rootBuffer: one all-ones shadow-root record per decode buffer instead of one per 64 slots); no apply, no retention, no closure mint; B1/B2/B3 unchanged"
                }
          )
        , ( ( "Json", "encode" )
          , TypeFaithful
                { scope = Inert
                , files = [ "elm-kernel-cpp/src/json/JsonExports.cpp" ]
                , evidence = "class: vacuous | entry: JsonExports.cpp:Elm_Kernel_Json_encode:1651-1662 | helpers: elmToJson:1290-1386 | type: elm/json/1.1.4/src/Json/Encode.elm:61 (Int -> Value -> String) | B1: vacuous (no function-capable position) | B2: fresh String result only :1660 | B3: no closure alloc | audited: 2026-08-29 | re-audit 2026-08-29: rewrapEscapingResult escape rewrap added at Json_run/runOnString (MONO_013 Ok-payload re-store only; no apply, no retention, no closure mint; B1/B2/B3 unchanged); Json_run additionally bridges ENC_*→CTOR_JSON_* values via the existing elmToJson/jsonToHeap converters (read-then-rebuild, no apply/retention/closure) | re-audit 2026-09-26: threaded-gc-04b GC-safety fixes only - DEC_ARRAY now builds a proper Elm Array tree (buildElmArrayFromElements: fresh JsArray/Custom nodes over the decoded Ok payloads, returned by THIS call) and runDecoder's recursive calls re-encode the rooted jvalHP instead of the unrooted parameter copy; JSON arrays over jsonArrayChunkSize() elements are stored chunked (CTOR_JSON_ARRAY_CHUNKED: fresh chunk ElmArrays + an index, built and returned by the same jsonToHeap call) and every reader goes through the allocation-free jsonArrayLength/jsonArrayAt accessors; no apply, no retention, no closure mint; B1/B2/B3 unchanged | re-audit 2026-10-06: plans/kernel-root-stack-bounded-rooting.md - JsonExports.cpp rooting only (rootInChunks -> rootBuffer: one all-ones shadow-root record per decode buffer instead of one per 64 slots); no apply, no retention, no closure mint; B1/B2/B3 unchanged"
                }
          )
        , ( ( "Json", "encodeNull" )
          , TypeFaithful
                { scope = Inert
                , files = [ "elm-kernel-cpp/src/json/JsonExports.cpp" ]
                , evidence = "class: vacuous | entry: JsonExports.cpp:Elm_Kernel_Json_encodeNull:1804-1809 | helpers: none | type: elm/json/1.1.4/src/Json/Encode.elm:141 (Value), nullary, no param | B1: vacuous (no function-capable position) | B2: embedded constant, no alloc | B3: no closure alloc | audited: 2026-08-29 | re-audit 2026-08-29: rewrapEscapingResult escape rewrap added at Json_run/runOnString (MONO_013 Ok-payload re-store only; no apply, no retention, no closure mint; B1/B2/B3 unchanged); Json_run additionally bridges ENC_*→CTOR_JSON_* values via the existing elmToJson/jsonToHeap converters (read-then-rebuild, no apply/retention/closure) | re-audit 2026-09-26: threaded-gc-04b GC-safety fixes only - DEC_ARRAY now builds a proper Elm Array tree (buildElmArrayFromElements: fresh JsArray/Custom nodes over the decoded Ok payloads, returned by THIS call) and runDecoder's recursive calls re-encode the rooted jvalHP instead of the unrooted parameter copy; JSON arrays over jsonArrayChunkSize() elements are stored chunked (CTOR_JSON_ARRAY_CHUNKED: fresh chunk ElmArrays + an index, built and returned by the same jsonToHeap call) and every reader goes through the allocation-free jsonArrayLength/jsonArrayAt accessors; no apply, no retention, no closure mint; B1/B2/B3 unchanged | re-audit 2026-10-06: plans/kernel-root-stack-bounded-rooting.md - JsonExports.cpp rooting only (rootInChunks -> rootBuffer: one all-ones shadow-root record per decode buffer instead of one per 64 slots); no apply, no retention, no closure mint; B1/B2/B3 unchanged"
                }
          )
        , ( ( "Json", "runOnString" )
          , TypeFaithful
                { scope = Transports
                , files = [ "elm-kernel-cpp/src/json/JsonExports.cpp" ]
                , evidence = "class: full | entry: JsonExports.cpp:Elm_Kernel_Json_runOnString:1624-1645 | type: elm/json/1.1.4/src/Json/Decode.elm (Decoder a -> String -> Result Error a) | B1: as Json.run, parsing the string first; same argument-threaded, same-call decode | B2: the only store is into the value THIS call returns - no static, no mailbox, no other call's object | B3: no allocClosure | audited: 2026-08-29 | re-audit 2026-08-29: rewrapEscapingResult escape rewrap added at Json_run/runOnString (MONO_013 Ok-payload re-store only; no apply, no retention, no closure mint; B1/B2/B3 unchanged); Json_run additionally bridges ENC_*→CTOR_JSON_* values via the existing elmToJson/jsonToHeap converters (read-then-rebuild, no apply/retention/closure) | re-audit 2026-09-26: threaded-gc-04b GC-safety fixes only - DEC_ARRAY now builds a proper Elm Array tree (buildElmArrayFromElements: fresh JsArray/Custom nodes over the decoded Ok payloads, returned by THIS call) and runDecoder's recursive calls re-encode the rooted jvalHP instead of the unrooted parameter copy; JSON arrays over jsonArrayChunkSize() elements are stored chunked (CTOR_JSON_ARRAY_CHUNKED: fresh chunk ElmArrays + an index, built and returned by the same jsonToHeap call) and every reader goes through the allocation-free jsonArrayLength/jsonArrayAt accessors; no apply, no retention, no closure mint; B1/B2/B3 unchanged | re-audit 2026-10-06: plans/kernel-root-stack-bounded-rooting.md - JsonExports.cpp rooting only (rootInChunks -> rootBuffer: one all-ones shadow-root record per decode buffer instead of one per 64 slots); no apply, no retention, no closure mint; B1/B2/B3 unchanged"
                }
          )
        , ( ( "Json", "run" )
          , TypeFaithful
                { scope = Transports
                , files = [ "elm-kernel-cpp/src/json/JsonExports.cpp" ]
                , evidence = "class: full | entry: JsonExports.cpp:Elm_Kernel_Json_run:1589-1622 | type: elm/json/1.1.4/src/Json/Decode.elm (Decoder a -> Value -> Result Error a) | B1: THE consumer that closes the chain - it drives the decode over a decoder passed AS AN ARGUMENT, in THIS call, and the `a` in Decoder a is the `a` in Result Error a. Every callback a combinator stored is applied here, under an argument-threaded type edge | B2: the only store is into the value THIS call returns - no static, no mailbox, no other call's object | B3: no allocClosure | audited: 2026-08-29 | re-audit 2026-08-29: rewrapEscapingResult escape rewrap added at Json_run/runOnString (MONO_013 Ok-payload re-store only; no apply, no retention, no closure mint; B1/B2/B3 unchanged); Json_run additionally bridges ENC_*→CTOR_JSON_* values via the existing elmToJson/jsonToHeap converters (read-then-rebuild, no apply/retention/closure) | re-audit 2026-09-26: threaded-gc-04b GC-safety fixes only - DEC_ARRAY now builds a proper Elm Array tree (buildElmArrayFromElements: fresh JsArray/Custom nodes over the decoded Ok payloads, returned by THIS call) and runDecoder's recursive calls re-encode the rooted jvalHP instead of the unrooted parameter copy; JSON arrays over jsonArrayChunkSize() elements are stored chunked (CTOR_JSON_ARRAY_CHUNKED: fresh chunk ElmArrays + an index, built and returned by the same jsonToHeap call) and every reader goes through the allocation-free jsonArrayLength/jsonArrayAt accessors; no apply, no retention, no closure mint; B1/B2/B3 unchanged | re-audit 2026-10-06: plans/kernel-root-stack-bounded-rooting.md - JsonExports.cpp rooting only (rootInChunks -> rootBuffer: one all-ones shadow-root record per decode buffer instead of one per 64 slots); no apply, no retention, no closure mint; B1/B2/B3 unchanged"
                }
          )
        , ( ( "Json", "oneOf" )
          , TypeFaithful
                { scope = Transports
                , files = [ "elm-kernel-cpp/src/json/JsonExports.cpp" ]
                , evidence = "class: full | entry: JsonExports.cpp:Elm_Kernel_Json_oneOf:1458-1460 | helpers: JsonExports.cpp:makeDecoder1:479-493, makeDecoder2:507-525 | type: elm/json/1.1.4/src/Json/Decode.elm (List (Decoder a) -> Decoder a) | B1: arguments stored VERBATIM into the DEC_ONEOF decoder Custom; the decoder is then consumed by Json.run/runOnString, which take it AS AN ARGUMENT and drive the decode SYNCHRONOUSLY in that same call (JsonExports.cpp:1589-1645) - so every hop is threaded through shared type variables and there is no cross-call edge. Structurally identical to Scheduler.andThen and to JsArray.singleton | B2: the only store is into the value THIS call returns - no static, no mailbox, no other call's object | B3: no allocClosure - makeDecoder* is a record constructor, not a closure mint | audited: 2026-08-29 | re-audit 2026-08-29: rewrapEscapingResult escape rewrap added at Json_run/runOnString (MONO_013 Ok-payload re-store only; no apply, no retention, no closure mint; B1/B2/B3 unchanged); Json_run additionally bridges ENC_*→CTOR_JSON_* values via the existing elmToJson/jsonToHeap converters (read-then-rebuild, no apply/retention/closure) | re-audit 2026-09-26: threaded-gc-04b GC-safety fixes only - DEC_ARRAY now builds a proper Elm Array tree (buildElmArrayFromElements: fresh JsArray/Custom nodes over the decoded Ok payloads, returned by THIS call) and runDecoder's recursive calls re-encode the rooted jvalHP instead of the unrooted parameter copy; JSON arrays over jsonArrayChunkSize() elements are stored chunked (CTOR_JSON_ARRAY_CHUNKED: fresh chunk ElmArrays + an index, built and returned by the same jsonToHeap call) and every reader goes through the allocation-free jsonArrayLength/jsonArrayAt accessors; no apply, no retention, no closure mint; B1/B2/B3 unchanged | re-audit 2026-10-06: plans/kernel-root-stack-bounded-rooting.md - JsonExports.cpp rooting only (rootInChunks -> rootBuffer: one all-ones shadow-root record per decode buffer instead of one per 64 slots); no apply, no retention, no closure mint; B1/B2/B3 unchanged"
                }
          )
        , ( ( "Json", "fail" )
          , TypeFaithful
                { scope = Transports
                , files = [ "elm-kernel-cpp/src/json/JsonExports.cpp" ]
                , evidence = "class: full | entry: JsonExports.cpp:Elm_Kernel_Json_fail:1450-1452 | helpers: JsonExports.cpp:makeDecoder1:479-493, makeDecoder2:507-525 | type: elm/json/1.1.4/src/Json/Decode.elm (String -> Decoder a) | B1: arguments stored VERBATIM into the DEC_FAIL decoder Custom; the decoder is then consumed by Json.run/runOnString, which take it AS AN ARGUMENT and drive the decode SYNCHRONOUSLY in that same call (JsonExports.cpp:1589-1645) - so every hop is threaded through shared type variables and there is no cross-call edge. Structurally identical to Scheduler.andThen and to JsArray.singleton | B2: the only store is into the value THIS call returns - no static, no mailbox, no other call's object | B3: no allocClosure - makeDecoder* is a record constructor, not a closure mint | audited: 2026-08-29 | re-audit 2026-08-29: rewrapEscapingResult escape rewrap added at Json_run/runOnString (MONO_013 Ok-payload re-store only; no apply, no retention, no closure mint; B1/B2/B3 unchanged); Json_run additionally bridges ENC_*→CTOR_JSON_* values via the existing elmToJson/jsonToHeap converters (read-then-rebuild, no apply/retention/closure) | re-audit 2026-09-26: threaded-gc-04b GC-safety fixes only - DEC_ARRAY now builds a proper Elm Array tree (buildElmArrayFromElements: fresh JsArray/Custom nodes over the decoded Ok payloads, returned by THIS call) and runDecoder's recursive calls re-encode the rooted jvalHP instead of the unrooted parameter copy; JSON arrays over jsonArrayChunkSize() elements are stored chunked (CTOR_JSON_ARRAY_CHUNKED: fresh chunk ElmArrays + an index, built and returned by the same jsonToHeap call) and every reader goes through the allocation-free jsonArrayLength/jsonArrayAt accessors; no apply, no retention, no closure mint; B1/B2/B3 unchanged | re-audit 2026-10-06: plans/kernel-root-stack-bounded-rooting.md - JsonExports.cpp rooting only (rootInChunks -> rootBuffer: one all-ones shadow-root record per decode buffer instead of one per 64 slots); no apply, no retention, no closure mint; B1/B2/B3 unchanged"
                }
          )
        , ( ( "Json", "succeed" )
          , TypeFaithful
                { scope = Transports
                , files = [ "elm-kernel-cpp/src/json/JsonExports.cpp" ]
                , evidence = "class: full | entry: JsonExports.cpp:Elm_Kernel_Json_succeed:1446-1448 | helpers: JsonExports.cpp:makeDecoder1:479-493, makeDecoder2:507-525 | type: elm/json/1.1.4/src/Json/Decode.elm (a -> Decoder a) | B1: arguments stored VERBATIM into the DEC_SUCCEED decoder Custom; the decoder is then consumed by Json.run/runOnString, which take it AS AN ARGUMENT and drive the decode SYNCHRONOUSLY in that same call (JsonExports.cpp:1589-1645) - so every hop is threaded through shared type variables and there is no cross-call edge. Structurally identical to Scheduler.andThen and to JsArray.singleton | B2: the only store is into the value THIS call returns - no static, no mailbox, no other call's object | B3: no allocClosure - makeDecoder* is a record constructor, not a closure mint | audited: 2026-08-29 | re-audit 2026-08-29: rewrapEscapingResult escape rewrap added at Json_run/runOnString (MONO_013 Ok-payload re-store only; no apply, no retention, no closure mint; B1/B2/B3 unchanged); Json_run additionally bridges ENC_*→CTOR_JSON_* values via the existing elmToJson/jsonToHeap converters (read-then-rebuild, no apply/retention/closure) | re-audit 2026-09-26: threaded-gc-04b GC-safety fixes only - DEC_ARRAY now builds a proper Elm Array tree (buildElmArrayFromElements: fresh JsArray/Custom nodes over the decoded Ok payloads, returned by THIS call) and runDecoder's recursive calls re-encode the rooted jvalHP instead of the unrooted parameter copy; JSON arrays over jsonArrayChunkSize() elements are stored chunked (CTOR_JSON_ARRAY_CHUNKED: fresh chunk ElmArrays + an index, built and returned by the same jsonToHeap call) and every reader goes through the allocation-free jsonArrayLength/jsonArrayAt accessors; no apply, no retention, no closure mint; B1/B2/B3 unchanged | re-audit 2026-10-06: plans/kernel-root-stack-bounded-rooting.md - JsonExports.cpp rooting only (rootInChunks -> rootBuffer: one all-ones shadow-root record per decode buffer instead of one per 64 slots); no apply, no retention, no closure mint; B1/B2/B3 unchanged"
                }
          )
        , ( ( "Json", "map8" )
          , TypeFaithful
                { scope = Transports
                , files = [ "elm-kernel-cpp/src/json/JsonExports.cpp" ]
                , evidence = "class: full | entry: JsonExports.cpp:Elm_Kernel_Json_map8:1529-1532 | helpers: JsonExports.cpp:makeDecoder1:479-493, makeDecoder2:507-525 | type: elm/json/1.1.4/src/Json/Decode.elm ((a -> b -> c -> d -> e -> f -> g -> h -> value) -> Decoder a -> Decoder b -> Decoder c -> Decoder d -> Decoder e -> Decoder f -> Decoder g -> Decoder h -> Decoder value) | B1: arguments stored VERBATIM into the DEC_MAP8 decoder Custom; the decoder is then consumed by Json.run/runOnString, which take it AS AN ARGUMENT and drive the decode SYNCHRONOUSLY in that same call (JsonExports.cpp:1589-1645) - so every hop is threaded through shared type variables and there is no cross-call edge. Structurally identical to Scheduler.andThen and to JsArray.singleton | B2: the only store is into the value THIS call returns - no static, no mailbox, no other call's object | B3: no allocClosure - makeDecoder* is a record constructor, not a closure mint | audited: 2026-08-29 | re-audit 2026-08-29: rewrapEscapingResult escape rewrap added at Json_run/runOnString (MONO_013 Ok-payload re-store only; no apply, no retention, no closure mint; B1/B2/B3 unchanged); Json_run additionally bridges ENC_*→CTOR_JSON_* values via the existing elmToJson/jsonToHeap converters (read-then-rebuild, no apply/retention/closure) | re-audit 2026-09-26: threaded-gc-04b GC-safety fixes only - DEC_ARRAY now builds a proper Elm Array tree (buildElmArrayFromElements: fresh JsArray/Custom nodes over the decoded Ok payloads, returned by THIS call) and runDecoder's recursive calls re-encode the rooted jvalHP instead of the unrooted parameter copy; JSON arrays over jsonArrayChunkSize() elements are stored chunked (CTOR_JSON_ARRAY_CHUNKED: fresh chunk ElmArrays + an index, built and returned by the same jsonToHeap call) and every reader goes through the allocation-free jsonArrayLength/jsonArrayAt accessors; no apply, no retention, no closure mint; B1/B2/B3 unchanged | re-audit 2026-10-06: plans/kernel-root-stack-bounded-rooting.md - JsonExports.cpp rooting only (rootInChunks -> rootBuffer: one all-ones shadow-root record per decode buffer instead of one per 64 slots); no apply, no retention, no closure mint; B1/B2/B3 unchanged"
                }
          )
        , ( ( "Json", "map7" )
          , TypeFaithful
                { scope = Transports
                , files = [ "elm-kernel-cpp/src/json/JsonExports.cpp" ]
                , evidence = "class: full | entry: JsonExports.cpp:Elm_Kernel_Json_map7:1524-1527 | helpers: JsonExports.cpp:makeDecoder1:479-493, makeDecoder2:507-525 | type: elm/json/1.1.4/src/Json/Decode.elm ((a -> b -> c -> d -> e -> f -> g -> value) -> Decoder a -> Decoder b -> Decoder c -> Decoder d -> Decoder e -> Decoder f -> Decoder g -> Decoder value) | B1: arguments stored VERBATIM into the DEC_MAP7 decoder Custom; the decoder is then consumed by Json.run/runOnString, which take it AS AN ARGUMENT and drive the decode SYNCHRONOUSLY in that same call (JsonExports.cpp:1589-1645) - so every hop is threaded through shared type variables and there is no cross-call edge. Structurally identical to Scheduler.andThen and to JsArray.singleton | B2: the only store is into the value THIS call returns - no static, no mailbox, no other call's object | B3: no allocClosure - makeDecoder* is a record constructor, not a closure mint | audited: 2026-08-29 | re-audit 2026-08-29: rewrapEscapingResult escape rewrap added at Json_run/runOnString (MONO_013 Ok-payload re-store only; no apply, no retention, no closure mint; B1/B2/B3 unchanged); Json_run additionally bridges ENC_*→CTOR_JSON_* values via the existing elmToJson/jsonToHeap converters (read-then-rebuild, no apply/retention/closure) | re-audit 2026-09-26: threaded-gc-04b GC-safety fixes only - DEC_ARRAY now builds a proper Elm Array tree (buildElmArrayFromElements: fresh JsArray/Custom nodes over the decoded Ok payloads, returned by THIS call) and runDecoder's recursive calls re-encode the rooted jvalHP instead of the unrooted parameter copy; JSON arrays over jsonArrayChunkSize() elements are stored chunked (CTOR_JSON_ARRAY_CHUNKED: fresh chunk ElmArrays + an index, built and returned by the same jsonToHeap call) and every reader goes through the allocation-free jsonArrayLength/jsonArrayAt accessors; no apply, no retention, no closure mint; B1/B2/B3 unchanged | re-audit 2026-10-06: plans/kernel-root-stack-bounded-rooting.md - JsonExports.cpp rooting only (rootInChunks -> rootBuffer: one all-ones shadow-root record per decode buffer instead of one per 64 slots); no apply, no retention, no closure mint; B1/B2/B3 unchanged"
                }
          )
        , ( ( "Json", "map6" )
          , TypeFaithful
                { scope = Transports
                , files = [ "elm-kernel-cpp/src/json/JsonExports.cpp" ]
                , evidence = "class: full | entry: JsonExports.cpp:Elm_Kernel_Json_map6:1519-1522 | helpers: JsonExports.cpp:makeDecoder1:479-493, makeDecoder2:507-525 | type: elm/json/1.1.4/src/Json/Decode.elm ((a -> b -> c -> d -> e -> f -> value) -> Decoder a -> Decoder b -> Decoder c -> Decoder d -> Decoder e -> Decoder f -> Decoder value) | B1: arguments stored VERBATIM into the DEC_MAP6 decoder Custom; the decoder is then consumed by Json.run/runOnString, which take it AS AN ARGUMENT and drive the decode SYNCHRONOUSLY in that same call (JsonExports.cpp:1589-1645) - so every hop is threaded through shared type variables and there is no cross-call edge. Structurally identical to Scheduler.andThen and to JsArray.singleton | B2: the only store is into the value THIS call returns - no static, no mailbox, no other call's object | B3: no allocClosure - makeDecoder* is a record constructor, not a closure mint | audited: 2026-08-29 | re-audit 2026-08-29: rewrapEscapingResult escape rewrap added at Json_run/runOnString (MONO_013 Ok-payload re-store only; no apply, no retention, no closure mint; B1/B2/B3 unchanged); Json_run additionally bridges ENC_*→CTOR_JSON_* values via the existing elmToJson/jsonToHeap converters (read-then-rebuild, no apply/retention/closure) | re-audit 2026-09-26: threaded-gc-04b GC-safety fixes only - DEC_ARRAY now builds a proper Elm Array tree (buildElmArrayFromElements: fresh JsArray/Custom nodes over the decoded Ok payloads, returned by THIS call) and runDecoder's recursive calls re-encode the rooted jvalHP instead of the unrooted parameter copy; JSON arrays over jsonArrayChunkSize() elements are stored chunked (CTOR_JSON_ARRAY_CHUNKED: fresh chunk ElmArrays + an index, built and returned by the same jsonToHeap call) and every reader goes through the allocation-free jsonArrayLength/jsonArrayAt accessors; no apply, no retention, no closure mint; B1/B2/B3 unchanged | re-audit 2026-10-06: plans/kernel-root-stack-bounded-rooting.md - JsonExports.cpp rooting only (rootInChunks -> rootBuffer: one all-ones shadow-root record per decode buffer instead of one per 64 slots); no apply, no retention, no closure mint; B1/B2/B3 unchanged"
                }
          )
        , ( ( "Json", "map5" )
          , TypeFaithful
                { scope = Transports
                , files = [ "elm-kernel-cpp/src/json/JsonExports.cpp" ]
                , evidence = "class: full | entry: JsonExports.cpp:Elm_Kernel_Json_map5:1514-1517 | helpers: JsonExports.cpp:makeDecoder1:479-493, makeDecoder2:507-525 | type: elm/json/1.1.4/src/Json/Decode.elm ((a -> b -> c -> d -> e -> value) -> Decoder a -> Decoder b -> Decoder c -> Decoder d -> Decoder e -> Decoder value) | B1: arguments stored VERBATIM into the DEC_MAP5 decoder Custom; the decoder is then consumed by Json.run/runOnString, which take it AS AN ARGUMENT and drive the decode SYNCHRONOUSLY in that same call (JsonExports.cpp:1589-1645) - so every hop is threaded through shared type variables and there is no cross-call edge. Structurally identical to Scheduler.andThen and to JsArray.singleton | B2: the only store is into the value THIS call returns - no static, no mailbox, no other call's object | B3: no allocClosure - makeDecoder* is a record constructor, not a closure mint | audited: 2026-08-29 | re-audit 2026-08-29: rewrapEscapingResult escape rewrap added at Json_run/runOnString (MONO_013 Ok-payload re-store only; no apply, no retention, no closure mint; B1/B2/B3 unchanged); Json_run additionally bridges ENC_*→CTOR_JSON_* values via the existing elmToJson/jsonToHeap converters (read-then-rebuild, no apply/retention/closure) | re-audit 2026-09-26: threaded-gc-04b GC-safety fixes only - DEC_ARRAY now builds a proper Elm Array tree (buildElmArrayFromElements: fresh JsArray/Custom nodes over the decoded Ok payloads, returned by THIS call) and runDecoder's recursive calls re-encode the rooted jvalHP instead of the unrooted parameter copy; JSON arrays over jsonArrayChunkSize() elements are stored chunked (CTOR_JSON_ARRAY_CHUNKED: fresh chunk ElmArrays + an index, built and returned by the same jsonToHeap call) and every reader goes through the allocation-free jsonArrayLength/jsonArrayAt accessors; no apply, no retention, no closure mint; B1/B2/B3 unchanged | re-audit 2026-10-06: plans/kernel-root-stack-bounded-rooting.md - JsonExports.cpp rooting only (rootInChunks -> rootBuffer: one all-ones shadow-root record per decode buffer instead of one per 64 slots); no apply, no retention, no closure mint; B1/B2/B3 unchanged"
                }
          )
        , ( ( "Json", "map4" )
          , TypeFaithful
                { scope = Transports
                , files = [ "elm-kernel-cpp/src/json/JsonExports.cpp" ]
                , evidence = "class: full | entry: JsonExports.cpp:Elm_Kernel_Json_map4:1509-1512 | helpers: JsonExports.cpp:makeDecoder1:479-493, makeDecoder2:507-525 | type: elm/json/1.1.4/src/Json/Decode.elm ((a -> b -> c -> d -> value) -> Decoder a -> Decoder b -> Decoder c -> Decoder d -> Decoder value) | B1: arguments stored VERBATIM into the DEC_MAP4 decoder Custom; the decoder is then consumed by Json.run/runOnString, which take it AS AN ARGUMENT and drive the decode SYNCHRONOUSLY in that same call (JsonExports.cpp:1589-1645) - so every hop is threaded through shared type variables and there is no cross-call edge. Structurally identical to Scheduler.andThen and to JsArray.singleton | B2: the only store is into the value THIS call returns - no static, no mailbox, no other call's object | B3: no allocClosure - makeDecoder* is a record constructor, not a closure mint | audited: 2026-08-29 | re-audit 2026-08-29: rewrapEscapingResult escape rewrap added at Json_run/runOnString (MONO_013 Ok-payload re-store only; no apply, no retention, no closure mint; B1/B2/B3 unchanged); Json_run additionally bridges ENC_*→CTOR_JSON_* values via the existing elmToJson/jsonToHeap converters (read-then-rebuild, no apply/retention/closure) | re-audit 2026-09-26: threaded-gc-04b GC-safety fixes only - DEC_ARRAY now builds a proper Elm Array tree (buildElmArrayFromElements: fresh JsArray/Custom nodes over the decoded Ok payloads, returned by THIS call) and runDecoder's recursive calls re-encode the rooted jvalHP instead of the unrooted parameter copy; JSON arrays over jsonArrayChunkSize() elements are stored chunked (CTOR_JSON_ARRAY_CHUNKED: fresh chunk ElmArrays + an index, built and returned by the same jsonToHeap call) and every reader goes through the allocation-free jsonArrayLength/jsonArrayAt accessors; no apply, no retention, no closure mint; B1/B2/B3 unchanged | re-audit 2026-10-06: plans/kernel-root-stack-bounded-rooting.md - JsonExports.cpp rooting only (rootInChunks -> rootBuffer: one all-ones shadow-root record per decode buffer instead of one per 64 slots); no apply, no retention, no closure mint; B1/B2/B3 unchanged"
                }
          )
        , ( ( "Json", "map3" )
          , TypeFaithful
                { scope = Transports
                , files = [ "elm-kernel-cpp/src/json/JsonExports.cpp" ]
                , evidence = "class: full | entry: JsonExports.cpp:Elm_Kernel_Json_map3:1504-1507 | helpers: JsonExports.cpp:makeDecoder1:479-493, makeDecoder2:507-525 | type: elm/json/1.1.4/src/Json/Decode.elm ((a -> b -> c -> value) -> Decoder a -> Decoder b -> Decoder c -> Decoder value) | B1: arguments stored VERBATIM into the DEC_MAP3 decoder Custom; the decoder is then consumed by Json.run/runOnString, which take it AS AN ARGUMENT and drive the decode SYNCHRONOUSLY in that same call (JsonExports.cpp:1589-1645) - so every hop is threaded through shared type variables and there is no cross-call edge. Structurally identical to Scheduler.andThen and to JsArray.singleton | B2: the only store is into the value THIS call returns - no static, no mailbox, no other call's object | B3: no allocClosure - makeDecoder* is a record constructor, not a closure mint | audited: 2026-08-29 | re-audit 2026-08-29: rewrapEscapingResult escape rewrap added at Json_run/runOnString (MONO_013 Ok-payload re-store only; no apply, no retention, no closure mint; B1/B2/B3 unchanged); Json_run additionally bridges ENC_*→CTOR_JSON_* values via the existing elmToJson/jsonToHeap converters (read-then-rebuild, no apply/retention/closure) | re-audit 2026-09-26: threaded-gc-04b GC-safety fixes only - DEC_ARRAY now builds a proper Elm Array tree (buildElmArrayFromElements: fresh JsArray/Custom nodes over the decoded Ok payloads, returned by THIS call) and runDecoder's recursive calls re-encode the rooted jvalHP instead of the unrooted parameter copy; JSON arrays over jsonArrayChunkSize() elements are stored chunked (CTOR_JSON_ARRAY_CHUNKED: fresh chunk ElmArrays + an index, built and returned by the same jsonToHeap call) and every reader goes through the allocation-free jsonArrayLength/jsonArrayAt accessors; no apply, no retention, no closure mint; B1/B2/B3 unchanged | re-audit 2026-10-06: plans/kernel-root-stack-bounded-rooting.md - JsonExports.cpp rooting only (rootInChunks -> rootBuffer: one all-ones shadow-root record per decode buffer instead of one per 64 slots); no apply, no retention, no closure mint; B1/B2/B3 unchanged"
                }
          )
        , ( ( "Json", "map2" )
          , TypeFaithful
                { scope = Transports
                , files = [ "elm-kernel-cpp/src/json/JsonExports.cpp" ]
                , evidence = "class: full | entry: JsonExports.cpp:Elm_Kernel_Json_map2:1499-1502 | helpers: JsonExports.cpp:makeDecoder1:479-493, makeDecoder2:507-525 | type: elm/json/1.1.4/src/Json/Decode.elm ((a -> b -> value) -> Decoder a -> Decoder b -> Decoder value) | B1: arguments stored VERBATIM into the DEC_MAP2 decoder Custom; the decoder is then consumed by Json.run/runOnString, which take it AS AN ARGUMENT and drive the decode SYNCHRONOUSLY in that same call (JsonExports.cpp:1589-1645) - so every hop is threaded through shared type variables and there is no cross-call edge. Structurally identical to Scheduler.andThen and to JsArray.singleton | B2: the only store is into the value THIS call returns - no static, no mailbox, no other call's object | B3: no allocClosure - makeDecoder* is a record constructor, not a closure mint | audited: 2026-08-29 | re-audit 2026-08-29: rewrapEscapingResult escape rewrap added at Json_run/runOnString (MONO_013 Ok-payload re-store only; no apply, no retention, no closure mint; B1/B2/B3 unchanged); Json_run additionally bridges ENC_*→CTOR_JSON_* values via the existing elmToJson/jsonToHeap converters (read-then-rebuild, no apply/retention/closure) | re-audit 2026-09-26: threaded-gc-04b GC-safety fixes only - DEC_ARRAY now builds a proper Elm Array tree (buildElmArrayFromElements: fresh JsArray/Custom nodes over the decoded Ok payloads, returned by THIS call) and runDecoder's recursive calls re-encode the rooted jvalHP instead of the unrooted parameter copy; JSON arrays over jsonArrayChunkSize() elements are stored chunked (CTOR_JSON_ARRAY_CHUNKED: fresh chunk ElmArrays + an index, built and returned by the same jsonToHeap call) and every reader goes through the allocation-free jsonArrayLength/jsonArrayAt accessors; no apply, no retention, no closure mint; B1/B2/B3 unchanged | re-audit 2026-10-06: plans/kernel-root-stack-bounded-rooting.md - JsonExports.cpp rooting only (rootInChunks -> rootBuffer: one all-ones shadow-root record per decode buffer instead of one per 64 slots); no apply, no retention, no closure mint; B1/B2/B3 unchanged"
                }
          )
        , ( ( "Json", "map1" )
          , TypeFaithful
                { scope = Transports
                , files = [ "elm-kernel-cpp/src/json/JsonExports.cpp" ]
                , evidence = "class: full | entry: JsonExports.cpp:Elm_Kernel_Json_map1:1466-1468 | helpers: JsonExports.cpp:makeDecoder1:479-493, makeDecoder2:507-525 | type: elm/json/1.1.4/src/Json/Decode.elm ((a -> value) -> Decoder a -> Decoder value) | B1: arguments stored VERBATIM into the DEC_MAP1 decoder Custom; the decoder is then consumed by Json.run/runOnString, which take it AS AN ARGUMENT and drive the decode SYNCHRONOUSLY in that same call (JsonExports.cpp:1589-1645) - so every hop is threaded through shared type variables and there is no cross-call edge. Structurally identical to Scheduler.andThen and to JsArray.singleton | B2: the only store is into the value THIS call returns - no static, no mailbox, no other call's object | B3: no allocClosure - makeDecoder* is a record constructor, not a closure mint | audited: 2026-08-29 | re-audit 2026-08-29: rewrapEscapingResult escape rewrap added at Json_run/runOnString (MONO_013 Ok-payload re-store only; no apply, no retention, no closure mint; B1/B2/B3 unchanged); Json_run additionally bridges ENC_*→CTOR_JSON_* values via the existing elmToJson/jsonToHeap converters (read-then-rebuild, no apply/retention/closure) | re-audit 2026-09-26: threaded-gc-04b GC-safety fixes only - DEC_ARRAY now builds a proper Elm Array tree (buildElmArrayFromElements: fresh JsArray/Custom nodes over the decoded Ok payloads, returned by THIS call) and runDecoder's recursive calls re-encode the rooted jvalHP instead of the unrooted parameter copy; JSON arrays over jsonArrayChunkSize() elements are stored chunked (CTOR_JSON_ARRAY_CHUNKED: fresh chunk ElmArrays + an index, built and returned by the same jsonToHeap call) and every reader goes through the allocation-free jsonArrayLength/jsonArrayAt accessors; no apply, no retention, no closure mint; B1/B2/B3 unchanged | re-audit 2026-10-06: plans/kernel-root-stack-bounded-rooting.md - JsonExports.cpp rooting only (rootInChunks -> rootBuffer: one all-ones shadow-root record per decode buffer instead of one per 64 slots); no apply, no retention, no closure mint; B1/B2/B3 unchanged"
                }
          )
        , ( ( "List", "cons" )
          , TypeFaithful
                { scope = Transports
                , files = [ "elm-kernel-cpp/src/core/ListExports.cpp", "elm-kernel-cpp/src/core/List.cpp" ]
                , evidence = "class: cheap | entry: ListExports.cpp:Elm_Kernel_List_cons:276-283 (ABI :288-304) | helpers: List.cpp:cons:18-20 | type: elm/core/1.0.5/src/List.elm:106 | B1: head word stored verbatim in the fresh cell, B1(b) MOVE along a | B2: no static/global/cache/task write | B3: no allocClosure/Tag_Closure | audited: 2026-10-05 (re-audit, plans/wide-object-tail-kind-words-phase-2.md 2.3/2.6: the only C++ changes are the EvalParamLayout encoding (hand-written byte arrays replaced by makeEvalParamLayout values with the same kinds; u16 num_params) and, in ListExports, closure kinds read from a ClosureKinds snapshot; no application, retention, fabrication or type change) | re-audit 2026-10-06: plans/kernel-root-stack-bounded-rooting.md - List.cpp dead-code deletion only (toArray and map2-map5 had no caller; cons untouched); no apply, no retention, no closure mint; B1/B2/B3 unchanged"
                }
          )
        , ( ( "List", "fromArray" )
          , TypeFaithful
                { scope = TransportsAs (TsFun (tsList (TsVar "a")) (tsList (TsVar "a")))
                , files = [ "elm-kernel-cpp/src/core/ListExports.cpp" ]
                , evidence = "class: cheap | entry: ListExports.cpp:Elm_Kernel_List_fromArray:306-354 | type: DECLARED List a -> List a, pinned equal to the intrinsic annotation (TYPE_KERNEL_001) which is what SOLVES the occurrence -- the earlier Array/JsArray shapes matched nothing because the non-List side was an unsolved var | B1: B1(b)/B1(c) only -- Nil and already-Cons inputs return the ARGUMENT by identity :310-330, and the conversion copies element words verbatim | B2: no static/global/cache write | B3: no allocClosure/Tag_Closure; allocation is list cells | audited: 2026-10-05 (re-audit, plans/wide-object-tail-kind-words-phase-2.md 2.3/2.6: the only C++ changes are the EvalParamLayout encoding (hand-written byte arrays replaced by makeEvalParamLayout values with the same kinds; u16 num_params) and, in ListExports, closure kinds read from a ClosureKinds snapshot; no application, retention, fabrication or type change)"
                }
          )
        , ( ( "List", "map2" )
          , TypeFaithful
                { scope = Transports
                , files = [ "elm-kernel-cpp/src/core/ListExports.cpp" ]
                , evidence = "class: full | entry: ListExports.cpp:Elm_Kernel_List_map2:592-600 | helpers: kernelListMapN:432-590, appendClosureResult:233 | type: elm/core/1.0.5/src/List.elm:437 | B1: apply-only via eco_apply_closure_eval :567-569 | B2: call-local vectors, roots unwound :581 | B3: no allocClosure/Tag_Closure | audited: 2026-10-05 (re-audit, plans/wide-object-tail-kind-words-phase-2.md 2.3/2.6: the only C++ changes are the EvalParamLayout encoding (hand-written byte arrays replaced by makeEvalParamLayout values with the same kinds; u16 num_params) and, in ListExports, closure kinds read from a ClosureKinds snapshot; no application, retention, fabrication or type change)"
                }
          )
        , ( ( "List", "map3" )
          , TypeFaithful
                { scope = Transports
                , files = [ "elm-kernel-cpp/src/core/ListExports.cpp" ]
                , evidence = "class: full | entry: ListExports.cpp:Elm_Kernel_List_map3:602-611 | helpers: kernelListMapN:432-590 (n=3 at :609) | type: elm/core/1.0.5/src/List.elm:443 | B1: apply-only via eco_apply_closure_eval :567-569 | B2: call-local vectors, roots unwound :581 | B3: no allocClosure/Tag_Closure | audited: 2026-10-05 (re-audit, plans/wide-object-tail-kind-words-phase-2.md 2.3/2.6: the only C++ changes are the EvalParamLayout encoding (hand-written byte arrays replaced by makeEvalParamLayout values with the same kinds; u16 num_params) and, in ListExports, closure kinds read from a ClosureKinds snapshot; no application, retention, fabrication or type change)"
                }
          )
        , ( ( "List", "map4" )
          , TypeFaithful
                { scope = Transports
                , files = [ "elm-kernel-cpp/src/core/ListExports.cpp" ]
                , evidence = "class: full | entry: ListExports.cpp:Elm_Kernel_List_map4:613-623 | helpers: kernelListMapN:432-590 (n=4 at :621) | type: elm/core/1.0.5/src/List.elm:449 | B1: apply-only via eco_apply_closure_eval :567-569 | B2: call-local vectors, roots unwound :581 | B3: no allocClosure/Tag_Closure | audited: 2026-10-05 (re-audit, plans/wide-object-tail-kind-words-phase-2.md 2.3/2.6: the only C++ changes are the EvalParamLayout encoding (hand-written byte arrays replaced by makeEvalParamLayout values with the same kinds; u16 num_params) and, in ListExports, closure kinds read from a ClosureKinds snapshot; no application, retention, fabrication or type change)"
                }
          )
        , ( ( "List", "map5" )
          , TypeFaithful
                { scope = Transports
                , files = [ "elm-kernel-cpp/src/core/ListExports.cpp" ]
                , evidence = "class: full | entry: ListExports.cpp:Elm_Kernel_List_map5:625-637 | helpers: kernelListMapN:432-590 (n=5 at :635) | type: elm/core/1.0.5/src/List.elm:455 | B1: apply-only via eco_apply_closure_eval :567-569 | B2: call-local vectors, roots unwound :581 | B3: no allocClosure/Tag_Closure | audited: 2026-10-05 (re-audit, plans/wide-object-tail-kind-words-phase-2.md 2.3/2.6: the only C++ changes are the EvalParamLayout encoding (hand-written byte arrays replaced by makeEvalParamLayout values with the same kinds; u16 num_params) and, in ListExports, closure kinds read from a ClosureKinds snapshot; no application, retention, fabrication or type change)"
                }
          )
        , ( ( "List", "toArray" )
          , TypeFaithful
                { scope = TransportsAs (TsFun (tsList (TsVar "a")) (tsList (TsVar "a")))
                , files = [ "elm-kernel-cpp/src/core/ListExports.cpp" ]
                , evidence = "class: cheap | entry: ListExports.cpp:Elm_Kernel_List_toArray:356-392 | type: DECLARED List a -> List a, pinned equal to the intrinsic annotation (TYPE_KERNEL_001); the consumer StringOps::join takes a cons list (StringOps.cpp:659) | B1: B1(b)/B1(c) only -- Nil and Cons inputs return the ARGUMENT by identity :362-375; the fallback copies element words via listToVectorU64 | B2: no static/global/cache write | B3: no allocClosure/Tag_Closure | audited: 2026-10-05 (re-audit, plans/wide-object-tail-kind-words-phase-2.md 2.3/2.6: the only C++ changes are the EvalParamLayout encoding (hand-written byte arrays replaced by makeEvalParamLayout values with the same kinds; u16 num_params) and, in ListExports, closure kinds read from a ClosureKinds snapshot; no application, retention, fabrication or type change)"
                }
          )
        , ( ( "List", "sortBy" )
          , TypeFaithful
                { scope = Transports
                , files = [ "elm-kernel-cpp/src/core/ListExports.cpp", "elm-kernel-cpp/src/core/Utils.cpp" ]
                , evidence = "class: full | entry: ListExports.cpp:Elm_Kernel_List_sortBy:759-830 | helpers: listFromPermutation:741, Utils.cpp:compare:437 | type: elm/core/1.0.5/src/List.elm:484 | B1: apply-only via eco_apply_closure :787; result = permutation :828 | B2: no retention; cmp read-only | B3: no allocClosure/Tag_Closure | audited: 2026-10-05 (re-audit, plans/wide-object-tail-kind-words-phase-2.md 2.3/2.6: the only C++ changes are the EvalParamLayout encoding (hand-written byte arrays replaced by makeEvalParamLayout values with the same kinds; u16 num_params) and, in ListExports, closure kinds read from a ClosureKinds snapshot; no application, retention, fabrication or type change)"
                }
          )
        , ( ( "List", "sortWith" )
          , TypeFaithful
                { scope = Transports
                , files = [ "elm-kernel-cpp/src/core/ListExports.cpp" ]
                , evidence = "class: full | entry: ListExports.cpp:Elm_Kernel_List_sortWith:832-887 | helpers: listFromPermutation:741 | type: elm/core/1.0.5/src/List.elm:502 | B1: apply-only via eco_apply_closure :873; result = permutation :885 | B2: call-local buffers, roots balanced :868-883 | B3: no allocClosure/Tag_Closure | audited: 2026-10-05 (re-audit, plans/wide-object-tail-kind-words-phase-2.md 2.3/2.6: the only C++ changes are the EvalParamLayout encoding (hand-written byte arrays replaced by makeEvalParamLayout values with the same kinds; u16 num_params) and, in ListExports, closure kinds read from a ClosureKinds snapshot; no application, retention, fabrication or type change)"
                }
          )
        , ( ( "MVar", "drop" )
          , TypeFaithful
                { scope = Transports
                , files = [ "eco-kernel-cpp/src/eco-kernel/MVarExports.cpp", "eco-kernel-cpp/src/eco-kernel/MVar.cpp" ]
                , evidence = "class: cheap | entry: MVarExports.cpp:Eco_Kernel_MVar_drop:63-65 | helpers: MVar.cpp:drop | type: Eco/MVar.elm (MVar a -> Task Never ()) | B1: takes ONLY the unboxed id (uint64_t); `a` does not appear in the result, so no function value can leave | B2: clears the slot; nothing function-valued is read back to Elm | B3: no allocClosure | audited: 2026-08-25"
                }
          )
        , ( ( "MVar", "new" )
          , TypeFaithful
                { scope = Transports
                , files = [ "eco-kernel-cpp/src/eco-kernel/MVarExports.cpp", "eco-kernel-cpp/src/eco-kernel/MVar.cpp" ]
                , evidence = "class: cheap | entry: MVarExports.cpp:Eco_Kernel_MVar_new:25-28 | helpers: MVar.cpp:newEmpty | type: Eco/MVar.elm:42 (Task Never (MVar a)) | B1: makeBinding<mvarNewBody>(unit()) - unit capture; returns a fresh HANDLE. `a` is phantom and NOTHING is ever written to it by this call. Contrast MVar.put/read/take, which stay REJECTED | B2: no store outside the returned Task | B3: binding closure only, payload unit | audited: 2026-08-25"
                }
          )
        , ( ( "NativeDriver", "lowerAndLink" )
          , TypeFaithful
                { scope = Inert
                , files = [ "eco-kernel-cpp/src/eco-kernel/NativeDriverExports.cpp", "eco-kernel-cpp/src/eco-kernel/NativeDriver.cpp" ]
                , evidence = "class: vacuous | entry: NativeDriverExports.cpp:Eco_Kernel_NativeDriver_lowerAndLink:9-13 | helpers: NativeDriver.cpp:lowerAndLink:88-98 | type: Eco/NativeDriver.elm:46 | B1: vacuous (no function-capable position) | B2: three Strings in a tuple3 :94-97; no statics in the file | B3: binding closure only | audited: 2026-08-20"
                }
          )
        , ( ( "NativeDriver", "lowerAndLinkBytes" )
          , TypeFaithful
                { scope = Inert
                , files = [ "eco-kernel-cpp/src/eco-kernel/NativeDriverExports.cpp", "eco-kernel-cpp/src/eco-kernel/NativeDriver.cpp" ]
                , evidence = "class: vacuous | entry: NativeDriverExports.cpp:Eco_Kernel_NativeDriver_lowerAndLinkBytes:15-18 | helpers: NativeDriver.cpp:lowerAndLinkBytes:100-108 | type: Eco/NativeDriver.elm:58 | B1: vacuous (no function-capable position) | B2: both args in a tuple2 :104-105; no statics | B3: binding closure only | audited: 2026-08-20"
                }
          )
        , ( ( "Parser", "chompBase10" )
          , TypeFaithful
                { scope = Inert
                , files = [ "elm-kernel-cpp/src/parser/ParserExports.cpp" ]
                , evidence = "class: vacuous | entry: ParserExports.cpp:Elm_Kernel_Parser_chompBase10:284-295 | helpers: resolveString:81-86 | type: elm/parser/1.1.0/src/Parser/Advanced.elm:755 | B1: vacuous (no function-capable position) | B2: no cross-call storage; returns a raw int64_t | B3: grep clean (no allocClosure) | audited: 2026-10-05 (re-audit, plans/wide-object-tail-kind-words-phase-2.md 2.3/2.6: the only C++ changes are the EvalParamLayout encoding (hand-written byte arrays replaced by makeEvalParamLayout values with the same kinds; u16 num_params) and, in ListExports, closure kinds read from a ClosureKinds snapshot; no application, retention, fabrication or type change)"
                }
          )
        , ( ( "Parser", "consumeBase" )
          , TypeFaithful
                { scope = Inert
                , files = [ "elm-kernel-cpp/src/parser/ParserExports.cpp" ]
                , evidence = "class: vacuous | entry: ParserExports.cpp:Elm_Kernel_Parser_consumeBase:299-312 | type: elm/parser/1.1.0/src/Parser/Advanced.elm:659 | B1: vacuous (no function-capable position) | B2: no cross-call storage in ParserExports.cpp | B3: grep clean (no allocClosure) | audited: 2026-10-05 (re-audit, plans/wide-object-tail-kind-words-phase-2.md 2.3/2.6: the only C++ changes are the EvalParamLayout encoding (hand-written byte arrays replaced by makeEvalParamLayout values with the same kinds; u16 num_params) and, in ListExports, closure kinds read from a ClosureKinds snapshot; no application, retention, fabrication or type change)"
                }
          )
        , ( ( "Parser", "consumeBase16" )
          , TypeFaithful
                { scope = Inert
                , files = [ "elm-kernel-cpp/src/parser/ParserExports.cpp" ]
                , evidence = "class: vacuous | entry: ParserExports.cpp:Elm_Kernel_Parser_consumeBase16:316-336 | type: elm/parser/1.1.0/src/Parser/Advanced.elm:664 | B1: vacuous (no function-capable position) | B2: no cross-call storage in ParserExports.cpp | B3: grep clean (no allocClosure) | audited: 2026-10-05 (re-audit, plans/wide-object-tail-kind-words-phase-2.md 2.3/2.6: the only C++ changes are the EvalParamLayout encoding (hand-written byte arrays replaced by makeEvalParamLayout values with the same kinds; u16 num_params) and, in ListExports, closure kinds read from a ClosureKinds snapshot; no application, retention, fabrication or type change)"
                }
          )
        , ( ( "Parser", "findSubString" )
          , TypeFaithful
                { scope = Inert
                , files = [ "elm-kernel-cpp/src/parser/ParserExports.cpp" ]
                , evidence = "class: vacuous | entry: ParserExports.cpp:Elm_Kernel_Parser_findSubString:240-281 | type: elm/parser/1.1.0/src/Parser/Advanced.elm:1131 | B1: vacuous (no function-capable position) | B2: no cross-call storage; StackRootGuard :246 is call-scoped | B3: grep clean (no allocClosure) | audited: 2026-10-05 (re-audit, plans/wide-object-tail-kind-words-phase-2.md 2.3/2.6: the only C++ changes are the EvalParamLayout encoding (hand-written byte arrays replaced by makeEvalParamLayout values with the same kinds; u16 num_params) and, in ListExports, closure kinds read from a ClosureKinds snapshot; no application, retention, fabrication or type change)"
                }
          )
        , ( ( "Parser", "isAsciiCode" )
          , TypeFaithful
                { scope = Inert
                , files = [ "elm-kernel-cpp/src/parser/ParserExports.cpp" ]
                , evidence = "class: vacuous | entry: ParserExports.cpp:Elm_Kernel_Parser_isAsciiCode:129-134 | helpers: resolveString:81-86 | type: elm/parser/1.1.0/src/Parser/Advanced.elm:1118 | B1: vacuous (no function-capable position) | B2: no cross-call storage; result is a boxed Bool :133 | B3: grep clean (no allocClosure) | audited: 2026-10-05 (re-audit, plans/wide-object-tail-kind-words-phase-2.md 2.3/2.6: the only C++ changes are the EvalParamLayout encoding (hand-written byte arrays replaced by makeEvalParamLayout values with the same kinds; u16 num_params) and, in ListExports, closure kinds read from a ClosureKinds snapshot; no application, retention, fabrication or type change)"
                }
          )
        , ( ( "Parser", "isSubChar" )
          , TypeFaithful
                { scope = Transports
                , files = [ "elm-kernel-cpp/src/parser/ParserExports.cpp" ]
                , evidence = "class: full | entry: ParserExports.cpp:Elm_Kernel_Parser_isSubChar:142-189 | type: elm/parser/1.1.0/src/Parser/Advanced.elm:1110 ((Char -> Bool) -> Int -> String -> Int) | B1: apply-only via eco_apply_closure_typed :179 (sole eco_apply site); decode :147, root :148 | B2: only static is the const layout array :175 | B3: grep clean (no allocClosure) | audited: 2026-10-05 (re-audit, plans/wide-object-tail-kind-words-phase-2.md 2.3/2.6: the only C++ changes are the EvalParamLayout encoding (hand-written byte arrays replaced by makeEvalParamLayout values with the same kinds; u16 num_params) and, in ListExports, closure kinds read from a ClosureKinds snapshot; no application, retention, fabrication or type change)"
                }
          )
        , ( ( "Parser", "isSubString" )
          , TypeFaithful
                { scope = Inert
                , files = [ "elm-kernel-cpp/src/parser/ParserExports.cpp" ]
                , evidence = "class: vacuous | entry: ParserExports.cpp:Elm_Kernel_Parser_isSubString:195-233 | type: elm/parser/1.1.0/src/Parser/Advanced.elm:1090 | B1: vacuous (no function-capable position) | B2: no cross-call storage; StackRootGuard :203 is call-scoped | B3: grep clean (no allocClosure) | audited: 2026-10-05 (re-audit, plans/wide-object-tail-kind-words-phase-2.md 2.3/2.6: the only C++ changes are the EvalParamLayout encoding (hand-written byte arrays replaced by makeEvalParamLayout values with the same kinds; u16 num_params) and, in ListExports, closure kinds read from a ClosureKinds snapshot; no application, retention, fabrication or type change)"
                }
          )
        , ( ( "Platform", "batch" )
          , TypeFaithful
                { scope = Transports
                , files = [ "elm-kernel-cpp/src/core/PlatformExports.cpp" ]
                , evidence = "class: cheap | entry: PlatformExports.cpp:Elm_Kernel_Platform_batch:21-29 | type: elm/core/1.0.5/src/Platform/Sub.elm (List (Sub msg) -> Sub msg) | B1: a STRUCTURAL container - it collects the Subs it is handed and adds, applies and reroutes nothing; `msg` passes through untouched. List.cons-shaped, and List.cons is licensed. Contrast Platform.map, which STORES A TAGGER the effect manager applies at a later unconnected call, and stays REJECTED | B2: the only store is into the value THIS call returns - no static, no mailbox, no other call's object | B3: no allocClosure | audited: 2026-08-25"
                }
          )
        , ( ( "Process", "exit" )
          , TypeFaithful
                { scope = Inert
                , files = [ "eco-kernel-cpp/src/eco-kernel/ProcessExports.cpp", "eco-kernel-cpp/src/eco-kernel/Process.cpp" ]
                , evidence = "class: vacuous | entry: ProcessExports.cpp:Eco_Kernel_Process_exit:9-11 | helpers: Process.cpp:exit:227-234 | type: Eco/Process.elm:49 | B1: vacuous (no function-capable position) | B2: nothing captured, nothing stored; ::exit() at :231 | B3: no closure fabricated at all | audited: 2026-08-20"
                }
          )
        , ( ( "Process", "sleep" )
          , TypeFaithful
                { scope = Transports
                , files = [ "elm-kernel-cpp/src/core/ProcessExports.cpp" ]
                , evidence = "class: cheap | entry: ProcessExports.cpp:Elm_Kernel_Process_sleep:43-52 | type: elm/core/1.0.5/src/Process.elm:93 (Float -> Task x ()) | B1: boxes the Float (allocFloat) and captures THAT; the binding payload is a boxed primitive, never a closure. Result is Task x () - nothing function-capable leaves | B2: no store outside the returned Task | B3: binding closure only, payload a boxed Float | audited: 2026-08-25"
                }
          )
        , ( ( "Process", "spawn" )
          , TypeFaithful
                { scope = Inert
                , files = [ "eco-kernel-cpp/src/eco-kernel/ProcessExports.cpp", "eco-kernel-cpp/src/eco-kernel/Process.cpp" ]
                , evidence = "class: vacuous | entry: ProcessExports.cpp:Eco_Kernel_Process_spawn:13-15 | helpers: Process.cpp:spawn:236-243 | type: Eco/Process.elm:56 | B1: vacuous (no function-capable position) | B2: both args in a tuple2 :240-242, Strings only | B3: binding closure only | audited: 2026-08-20"
                }
          )
        , ( ( "Process", "spawnProcess" )
          , TypeFaithful
                { scope = Inert
                , files = [ "eco-kernel-cpp/src/eco-kernel/ProcessExports.cpp", "eco-kernel-cpp/src/eco-kernel/Process.cpp" ]
                , evidence = "class: vacuous | entry: ProcessExports.cpp:Eco_Kernel_Process_spawnProcess:17-19 | type: Eco/Process.elm:67-74 | B1: vacuous (no function-capable position) | B2: 5-field record payload :253-259; s_streamHandles:154 maps int64->fd, no Elm value | B3: binding closure only | audited: 2026-08-20"
                }
          )
        , ( ( "Process", "wait" )
          , TypeFaithful
                { scope = Inert
                , files = [ "eco-kernel-cpp/src/eco-kernel/ProcessExports.cpp", "eco-kernel-cpp/src/eco-kernel/Process.cpp" ]
                , evidence = "class: vacuous | entry: ProcessExports.cpp:Eco_Kernel_Process_wait:21-23 | type: Eco/Process.elm:93 | B1: vacuous (no function-capable position) | B2: only an unboxed Int pid captured :267-270; the resume :217 is the runtime's OWN closure | B3: async binding closure only | audited: 2026-08-20"
                }
          )
        , ( ( "Regex", "contains" )
          , TypeFaithful
                { scope = Inert
                , files = [ "elm-kernel-cpp/src/regex/RegexExports.cpp" ]
                , evidence = "class: vacuous | entry: RegexExports.cpp:Elm_Kernel_Regex_contains:223-240 | helpers: getCompiledRegex:65-78 | type: elm/regex/1.0.0/src/Regex.elm:117 | B1: vacuous (no function-capable position) | B2: the static regex table is only READ :75 | B3: grep clean (no allocClosure) | audited: 2026-08-20 | re-audit 2026-10-06: plans/kernel-root-stack-bounded-rooting.md - RegexExports.cpp rooting only (findAtMost/splitAtMost collect into one RootedSlots record, then listFromPointers; per-element pushes and the deque removed); no apply, no retention, no closure mint; B1/B2/B3 unchanged"
                }
          )
        , ( ( "Regex", "findAtMost" )
          , TypeFaithful
                { scope = Inert
                , files = [ "elm-kernel-cpp/src/regex/RegexExports.cpp" ]
                , evidence = "class: vacuous | entry: RegexExports.cpp:Elm_Kernel_Regex_findAtMost:242-308 | type: elm/regex/1.0.0/src/Regex.elm:252 | B1: vacuous (no function-capable position) | B2: deque :262 is C-stack local, roots restored :298/:306, table read-only | B3: grep clean (no allocClosure) | audited: 2026-08-20 | re-audit 2026-10-06: plans/kernel-root-stack-bounded-rooting.md - RegexExports.cpp rooting only (findAtMost/splitAtMost collect into one RootedSlots record, then listFromPointers; per-element pushes and the deque removed); no apply, no retention, no closure mint; B1/B2/B3 unchanged"
                }
          )
        , ( ( "Regex", "fromStringWith" )
          , TypeFaithful
                { scope = Inert
                , files = [ "elm-kernel-cpp/src/regex/RegexExports.cpp" ]
                , evidence = "class: vacuous | entry: RegexExports.cpp:Elm_Kernel_Regex_fromStringWith:176-221 | type: elm/regex/1.0.0/src/Regex.elm:82 | B1: vacuous (no function-capable position) | B2: table write :205 stores a srell::regex*, not an Elm value; result Custom is unboxed ints :212 | B3: grep clean (no allocClosure) | audited: 2026-08-20 | re-audit 2026-10-06: plans/kernel-root-stack-bounded-rooting.md - RegexExports.cpp rooting only (findAtMost/splitAtMost collect into one RootedSlots record, then listFromPointers; per-element pushes and the deque removed); no apply, no retention, no closure mint; B1/B2/B3 unchanged"
                }
          )
        , ( ( "Regex", "infinity" )
          , TypeFaithful
                { scope = Inert
                , files = [ "elm-kernel-cpp/src/regex/RegexExports.cpp" ]
                , evidence = "class: vacuous | entry: RegexExports.cpp:Elm_Kernel_Regex_infinity:171-174 | type: elm/regex/1.0.0 (Float constant; INFERRED-FROM-USAGE, used inline in replaceAtMost, R5 vacuous class) | B1: vacuous - no arguments, returns numeric_limits<double>::infinity() | B2: no store | B3: no allocClosure | audited: 2026-08-25 | re-audit 2026-10-06: plans/kernel-root-stack-bounded-rooting.md - RegexExports.cpp rooting only (findAtMost/splitAtMost collect into one RootedSlots record, then listFromPointers; per-element pushes and the deque removed); no apply, no retention, no closure mint; B1/B2/B3 unchanged"
                }
          )
        , ( ( "Regex", "never" )
          , TypeFaithful
                { scope = Inert
                , files = [ "elm-kernel-cpp/src/regex/RegexExports.cpp" ]
                , evidence = "class: vacuous | entry: RegexExports.cpp:Elm_Kernel_Regex_never:152-169 | helpers: registerRegex:42-46 | type: elm/regex/1.0.0/src/Regex.elm:96 | B1: vacuous (no function-capable position) | B2: table write stores a srell::regex*; result Custom is all unboxed ints :164 | B3: grep clean (no allocClosure) | audited: 2026-08-20 | re-audit 2026-10-06: plans/kernel-root-stack-bounded-rooting.md - RegexExports.cpp rooting only (findAtMost/splitAtMost collect into one RootedSlots record, then listFromPointers; per-element pushes and the deque removed); no apply, no retention, no closure mint; B1/B2/B3 unchanged"
                }
          )
        , ( ( "Regex", "replaceAtMost" )
          , TypeFaithful
                { scope = Transports
                , files = [ "elm-kernel-cpp/src/regex/RegexExports.cpp" ]
                , evidence = "class: full | entry: RegexExports.cpp:Elm_Kernel_Regex_replaceAtMost:310-398 | type: elm/regex/1.0.0/src/Regex.elm:264 (Int -> Regex -> (Match -> String) -> String -> String) | B1: apply-only via eco_apply_closure :378 (sole eco_apply site); decode :335, root :336 | B2: nothing outlives the call; table read-only :317 | B3: grep clean (no allocClosure) | audited: 2026-08-20 | re-audit 2026-10-06: plans/kernel-root-stack-bounded-rooting.md - RegexExports.cpp rooting only (findAtMost/splitAtMost collect into one RootedSlots record, then listFromPointers; per-element pushes and the deque removed); no apply, no retention, no closure mint; B1/B2/B3 unchanged"
                }
          )
        , ( ( "Regex", "splitAtMost" )
          , TypeFaithful
                { scope = Inert
                , files = [ "elm-kernel-cpp/src/regex/RegexExports.cpp" ]
                , evidence = "class: vacuous | entry: RegexExports.cpp:Elm_Kernel_Regex_splitAtMost:400-464 | type: elm/regex/1.0.0/src/Regex.elm:240 | B1: vacuous (no function-capable position) | B2: deque :422 is call-local, roots restored :454/:462, table read-only | B3: grep clean (no allocClosure) | audited: 2026-08-20 | re-audit 2026-10-06: plans/kernel-root-stack-bounded-rooting.md - RegexExports.cpp rooting only (findAtMost/splitAtMost collect into one RootedSlots record, then listFromPointers; per-element pushes and the deque removed); no apply, no retention, no closure mint; B1/B2/B3 unchanged"
                }
          )
        , ( ( "Runtime", "dirname" )
          , TypeFaithful
                { scope = Inert
                , files = [ "eco-kernel-cpp/src/eco-kernel/RuntimeExports.cpp", "eco-kernel-cpp/src/eco-kernel/Runtime.cpp" ]
                , evidence = "class: vacuous | entry: RuntimeExports.cpp:Eco_Kernel_Runtime_dirname:9-11 | helpers: Runtime.cpp:dirname:64-67 | type: Eco/Runtime.elm:21 | B1: vacuous (no function-capable position) | B2: nothing captured (unit(), :66); s_savedState untouched | B3: binding closure only | audited: 2026-10-04 (re-audit: the only change to RuntimeExports.cpp since the previous hash is one deleted line in Eco_Kernel_register_all_gc_roots, the CellStore root-registration call, removed with that kernel by plans/remove-cellstore.md; no licensed body, type or capture behaviour is touched)"
                }
          )
        , ( ( "Runtime", "loadState" )
          , TypeFaithful
                { scope = Inert
                , files = [ "eco-kernel-cpp/src/eco-kernel/RuntimeExports.cpp", "eco-kernel-cpp/src/eco-kernel/Runtime.cpp" ]
                , evidence = "class: vacuous | entry: RuntimeExports.cpp:Eco_Kernel_Runtime_loadState:21-23 | helpers: Runtime.cpp:loadState | type: Eco/Runtime.elm (Task Never Encode.Value) | B1: vacuous - FULLY CONCRETE; the cross-call read is sound for the same reason as saveState | B2: reads runtime state, see B1 | B3: no allocClosure | audited: 2026-10-04 (re-audit: the only change to RuntimeExports.cpp since the previous hash is one deleted line in Eco_Kernel_register_all_gc_roots, the CellStore root-registration call, removed with that kernel by plans/remove-cellstore.md; no licensed body, type or capture behaviour is touched)"
                }
          )
        , ( ( "Runtime", "random" )
          , TypeFaithful
                { scope = Inert
                , files = [ "eco-kernel-cpp/src/eco-kernel/RuntimeExports.cpp", "eco-kernel-cpp/src/eco-kernel/Runtime.cpp" ]
                , evidence = "class: vacuous | entry: RuntimeExports.cpp:Eco_Kernel_Runtime_random:13-15 | helpers: Runtime.cpp:random:69-72 | type: Eco/Runtime.elm:28 | B1: vacuous (no function-capable position) | B2: nothing captured (unit(), :71); statics :41-42 are C++ PRNG state | B3: binding closure only | audited: 2026-10-04 (re-audit: the only change to RuntimeExports.cpp since the previous hash is one deleted line in Eco_Kernel_register_all_gc_roots, the CellStore root-registration call, removed with that kernel by plans/remove-cellstore.md; no licensed body, type or capture behaviour is touched)"
                }
          )
        , ( ( "Runtime", "saveState" )
          , TypeFaithful
                { scope = Inert
                , files = [ "eco-kernel-cpp/src/eco-kernel/RuntimeExports.cpp", "eco-kernel-cpp/src/eco-kernel/Runtime.cpp" ]
                , evidence = "class: vacuous | entry: RuntimeExports.cpp:Eco_Kernel_Runtime_saveState:17-19 | helpers: Runtime.cpp:saveState | type: Eco/Runtime.elm (Encode.Value -> Task Never ()) | B1: vacuous - FULLY CONCRETE both ways, so the loaded scheme has zero set slots (R3). It IS cross-call (loadState returns what a different saveState stored) and that is IRRELEVANT: cross-call only disqualifies when the retained position is FUNCTION-CAPABLE | B2: stores into runtime state, see B1 | B3: no allocClosure | audited: 2026-10-04 (re-audit: the only change to RuntimeExports.cpp since the previous hash is one deleted line in Eco_Kernel_register_all_gc_roots, the CellStore root-registration call, removed with that kernel by plans/remove-cellstore.md; no licensed body, type or capture behaviour is touched)"
                }
          )
        , ( ( "Scheduler", "andThen" )
          , TypeFaithful
                { scope = Transports
                , files = [ "elm-kernel-cpp/src/core/SchedulerExports.cpp", "runtime/src/platform/Scheduler.cpp" ]
                , evidence = "class: full | entry: SchedulerExports.cpp:Elm_Kernel_Scheduler_andThen:30-37 | helpers: Scheduler.cpp:taskAndThen:149-152 | type: elm/core/1.0.5/src/Task.elm:207 ((a -> Task x b) -> Task x a -> Task x b) | B1: BOTH words stored VERBATIM (:33-35 decode, taskAndThen :151 allocTask(Task_AndThen, nil, callback, nil, task)); the scheduler later applies THAT callback to THAT task's value - the callback is never substituted, wrapped or re-created, so param1's `a` = param2's `a` and param1's result `Task x b` = the result, exactly as the type's variable-sharing graph states | B2: the ONLY store is into the Task this call RETURNS (alloc::allocTask, HeapHelpers.hpp:2047-2069, write :2064-2067) - no static, no mailbox, no other call's object; the scheduler reads it back out of THAT SAME Task | B3: no allocClosure/Tag_Closure - allocTask is a record constructor, not a closure mint | audited: 2026-10-05 (re-audit, plans/wide-object-tail-kind-words-phase-2.md 2.3/2.6: the only C++ changes are the EvalParamLayout encoding (hand-written byte arrays replaced by makeEvalParamLayout values with the same kinds; u16 num_params) and, in ListExports, closure kinds read from a ClosureKinds snapshot; no application, retention, fabrication or type change)"
                }
          )
        , ( ( "Scheduler", "fail" )
          , TypeFaithful
                { scope = Transports
                , files = [ "elm-kernel-cpp/src/core/SchedulerExports.cpp", "runtime/src/platform/Scheduler.cpp" ]
                , evidence = "class: cheap | entry: SchedulerExports.cpp:Elm_Kernel_Scheduler_fail:23-28 | helpers: Scheduler.cpp:taskFail:139-142 | type: elm/core/1.0.5/src/Task.elm:92 (x -> Task x a) | B1: the arg word is stored unchanged (:26, taskFail :141 allocTask(Task_Fail, error, nil, nil, nil)) and handed back at the SAME `x` the type names | B2: the ONLY store is into the Task this call RETURNS (alloc::allocTask, HeapHelpers.hpp:2047-2069, write :2064-2067) - no static, no mailbox, no other call's object; the scheduler reads it back out of THAT SAME Task | B3: no allocClosure/Tag_Closure - allocTask is a record constructor, not a closure mint | audited: 2026-10-05 (re-audit, plans/wide-object-tail-kind-words-phase-2.md 2.3/2.6: the only C++ changes are the EvalParamLayout encoding (hand-written byte arrays replaced by makeEvalParamLayout values with the same kinds; u16 num_params) and, in ListExports, closure kinds read from a ClosureKinds snapshot; no application, retention, fabrication or type change)"
                }
          )
        , ( ( "Scheduler", "kill" )
          , TypeFaithful
                { scope = Transports
                , files = [ "elm-kernel-cpp/src/core/SchedulerExports.cpp", "runtime/src/platform/Scheduler.cpp" ]
                , evidence = "class: cheap | entry: SchedulerExports.cpp:Elm_Kernel_Scheduler_kill:55-60 | helpers: Scheduler.cpp:killTask | type: elm/core/1.0.5/src/Process.elm:103 (Id -> Task x ()) | B1: captures only a process Id; Id and () are concrete, so nothing function-capable enters or leaves | B2: no store outside the returned Task | B3: binding closure only, payload an Id | audited: 2026-10-05 (re-audit, plans/wide-object-tail-kind-words-phase-2.md 2.3/2.6: the only C++ changes are the EvalParamLayout encoding (hand-written byte arrays replaced by makeEvalParamLayout values with the same kinds; u16 num_params) and, in ListExports, closure kinds read from a ClosureKinds snapshot; no application, retention, fabrication or type change)"
                }
          )
        , ( ( "Scheduler", "onError" )
          , TypeFaithful
                { scope = Transports
                , files = [ "elm-kernel-cpp/src/core/SchedulerExports.cpp", "runtime/src/platform/Scheduler.cpp" ]
                , evidence = "class: full | entry: SchedulerExports.cpp:Elm_Kernel_Scheduler_onError:39-46 | helpers: Scheduler.cpp:taskOnError:154-157 | type: elm/core/1.0.5/src/Task.elm:227 ((x -> Task y a) -> Task x a -> Task y a) | B1: both words stored VERBATIM (:42-44, taskOnError :156); the handler is applied to the inner task's error and never substituted, and on the SUCCESS path the inner `a` passes straight through to the result's `a` - both edges are the type's shared variables | B2: the ONLY store is into the Task this call RETURNS (alloc::allocTask, HeapHelpers.hpp:2047-2069, write :2064-2067) - no static, no mailbox, no other call's object; the scheduler reads it back out of THAT SAME Task | B3: no allocClosure/Tag_Closure - allocTask is a record constructor, not a closure mint | audited: 2026-10-05 (re-audit, plans/wide-object-tail-kind-words-phase-2.md 2.3/2.6: the only C++ changes are the EvalParamLayout encoding (hand-written byte arrays replaced by makeEvalParamLayout values with the same kinds; u16 num_params) and, in ListExports, closure kinds read from a ClosureKinds snapshot; no application, retention, fabrication or type change)"
                }
          )
        , ( ( "Scheduler", "spawn" )
          , TypeFaithful
                { scope = Transports
                , files = [ "elm-kernel-cpp/src/core/SchedulerExports.cpp", "runtime/src/platform/Scheduler.cpp" ]
                , evidence = "class: full | entry: SchedulerExports.cpp:Elm_Kernel_Scheduler_spawn:48-53 | helpers: Scheduler.cpp:spawnTask:472-474 | type: elm/core/1.0.5/src/Process.elm:82 (Task x a -> Task y Id) | B1: the captured task MAY contain closures, but `a` is ABSENT FROM THE RESULT (Task y Id) - the type creates an EMPTY flow obligation, so there is nothing a licence can get wrong. The scheduler consumes the task; nothing function-valued is handed back to Elm at a typed position | B2: no store outside the returned Task | B3: makeBinding mints a closure, but it lands in Task.callback where no type variable names it | audited: 2026-10-05 (re-audit, plans/wide-object-tail-kind-words-phase-2.md 2.3/2.6: the only C++ changes are the EvalParamLayout encoding (hand-written byte arrays replaced by makeEvalParamLayout values with the same kinds; u16 num_params) and, in ListExports, closure kinds read from a ClosureKinds snapshot; no application, retention, fabrication or type change)"
                }
          )
        , ( ( "Scheduler", "succeed" )
          , TypeFaithful
                { scope = Transports
                , files = [ "elm-kernel-cpp/src/core/SchedulerExports.cpp", "runtime/src/platform/Scheduler.cpp" ]
                , evidence = "class: cheap | entry: SchedulerExports.cpp:Elm_Kernel_Scheduler_succeed:16-21 | helpers: Scheduler.cpp:taskSucceed:123-126 | type: elm/core/1.0.5/src/Task.elm:78 (a -> Task x a) | B1: the arg word is stored unchanged (:18, taskSucceed :125 allocTask(Task_Succeed, value, nil, nil, nil)) and handed back at the SAME `a` the type names - structurally JsArray.singleton with an opaque carrier | B2: the ONLY store is into the Task this call RETURNS (alloc::allocTask, HeapHelpers.hpp:2047-2069, write :2064-2067) - no static, no mailbox, no other call's object; the scheduler reads it back out of THAT SAME Task | B3: no allocClosure/Tag_Closure - allocTask is a record constructor, not a closure mint | audited: 2026-10-05 (re-audit, plans/wide-object-tail-kind-words-phase-2.md 2.3/2.6: the only C++ changes are the EvalParamLayout encoding (hand-written byte arrays replaced by makeEvalParamLayout values with the same kinds; u16 num_params) and, in ListExports, closure kinds read from a ClosureKinds snapshot; no application, retention, fabrication or type change)"
                }
          )
        , ( ( "String", "all" )
          , TypeFaithful
                { scope = Transports
                , files = [ "elm-kernel-cpp/src/core/StringExports.cpp" ]
                , evidence = "class: full | entry: StringExports.cpp:Elm_Kernel_String_all:317-334 | helpers: callCharToBoolClosure:217, snapshotChars:237 | type: elm/core/1.0.5/src/String.elm:615 ((Char -> Bool) -> String -> Bool) | B1: apply-only via eco_apply_closure_typed :329 | B2: no retention | B3: embedded Bool consts | audited: 2026-10-05 (re-audit, plans/wide-object-tail-kind-words-phase-2.md 2.3/2.6: the only C++ changes are the EvalParamLayout encoding (hand-written byte arrays replaced by makeEvalParamLayout values with the same kinds; u16 num_params) and, in ListExports, closure kinds read from a ClosureKinds snapshot; no application, retention, fabrication or type change)"
                }
          )
        , ( ( "String", "any" )
          , TypeFaithful
                { scope = Transports
                , files = [ "elm-kernel-cpp/src/core/StringExports.cpp" ]
                , evidence = "class: full | entry: StringExports.cpp:Elm_Kernel_String_any:299-315 | helpers: callCharToBoolClosure:217, snapshotChars:237 | type: elm/core/1.0.5/src/String.elm:604 ((Char -> Bool) -> String -> Bool) | B1: apply-only via eco_apply_closure_typed :310 | B2: no retention | B3: embedded Bool consts | audited: 2026-10-05 (re-audit, plans/wide-object-tail-kind-words-phase-2.md 2.3/2.6: the only C++ changes are the EvalParamLayout encoding (hand-written byte arrays replaced by makeEvalParamLayout values with the same kinds; u16 num_params) and, in ListExports, closure kinds read from a ClosureKinds snapshot; no application, retention, fabrication or type change)"
                }
          )
        , ( ( "String", "append" )
          , TypeFaithful
                { scope = Inert
                , files = [ "elm-kernel-cpp/src/core/StringExports.cpp", "elm-kernel-cpp/src/core/String.cpp" ]
                , evidence = "class: vacuous | entry: StringExports.cpp:Elm_Kernel_String_append:41-44 | helpers: String.cpp:append:26-28 | type: elm/core/1.0.5/src/String.elm:169 (String -> String -> String) | B1: vacuous (no function-capable position) | B2: no static/global/task write | B3: no closure alloc | audited: 2026-10-05 (re-audit, plans/wide-object-tail-kind-words-phase-2.md 2.3/2.6: the only C++ changes are the EvalParamLayout encoding (hand-written byte arrays replaced by makeEvalParamLayout values with the same kinds; u16 num_params) and, in ListExports, closure kinds read from a ClosureKinds snapshot; no application, retention, fabrication or type change) | re-audit 2026-10-06: plans/kernel-root-stack-bounded-rooting.md - String.cpp rooting only (split/lines/words parts rooted by one all-ones record instead of per-64 chunks); no apply, no retention, no closure mint; B1/B2/B3 unchanged"
                }
          )
        , ( ( "String", "cons" )
          , TypeFaithful
                { scope = Inert
                , files = [ "elm-kernel-cpp/src/core/StringExports.cpp", "elm-kernel-cpp/src/core/String.cpp" ]
                , evidence = "class: vacuous | entry: StringExports.cpp:Elm_Kernel_String_cons:52-56 | helpers: String.cpp:cons:38-40 | type: elm/core/1.0.5/src/String.elm:542 (Char -> String -> String) | B1: vacuous (no function-capable position) | B2: no static/global/task write | B3: no closure alloc | audited: 2026-10-05 (re-audit, plans/wide-object-tail-kind-words-phase-2.md 2.3/2.6: the only C++ changes are the EvalParamLayout encoding (hand-written byte arrays replaced by makeEvalParamLayout values with the same kinds; u16 num_params) and, in ListExports, closure kinds read from a ClosureKinds snapshot; no application, retention, fabrication or type change) | re-audit 2026-10-06: plans/kernel-root-stack-bounded-rooting.md - String.cpp rooting only (split/lines/words parts rooted by one all-ones record instead of per-64 chunks); no apply, no retention, no closure mint; B1/B2/B3 unchanged"
                }
          )
        , ( ( "String", "contains" )
          , TypeFaithful
                { scope = Inert
                , files = [ "elm-kernel-cpp/src/core/StringExports.cpp", "elm-kernel-cpp/src/core/String.cpp" ]
                , evidence = "class: vacuous | entry: StringExports.cpp:Elm_Kernel_String_contains:126-128 | helpers: String.cpp:contains:431-433 | type: elm/core/1.0.5/src/String.elm:299 (String -> String -> Bool) | B1: vacuous (no function-capable position) | B2: no static/global/task write | B3: embedded Bool consts | audited: 2026-10-05 (re-audit, plans/wide-object-tail-kind-words-phase-2.md 2.3/2.6: the only C++ changes are the EvalParamLayout encoding (hand-written byte arrays replaced by makeEvalParamLayout values with the same kinds; u16 num_params) and, in ListExports, closure kinds read from a ClosureKinds snapshot; no application, retention, fabrication or type change) | re-audit 2026-10-06: plans/kernel-root-stack-bounded-rooting.md - String.cpp rooting only (split/lines/words parts rooted by one all-ones record instead of per-64 chunks); no apply, no retention, no closure mint; B1/B2/B3 unchanged"
                }
          )
        , ( ( "String", "endsWith" )
          , TypeFaithful
                { scope = Inert
                , files = [ "elm-kernel-cpp/src/core/StringExports.cpp", "elm-kernel-cpp/src/core/String.cpp" ]
                , evidence = "class: vacuous | entry: StringExports.cpp:Elm_Kernel_String_endsWith:122-124 | helpers: String.cpp:endsWith:427-429 | type: elm/core/1.0.5/src/String.elm:319 (String -> String -> Bool) | B1: vacuous (no function-capable position) | B2: no static/global/task write | B3: embedded Bool consts | audited: 2026-10-05 (re-audit, plans/wide-object-tail-kind-words-phase-2.md 2.3/2.6: the only C++ changes are the EvalParamLayout encoding (hand-written byte arrays replaced by makeEvalParamLayout values with the same kinds; u16 num_params) and, in ListExports, closure kinds read from a ClosureKinds snapshot; no application, retention, fabrication or type change) | re-audit 2026-10-06: plans/kernel-root-stack-bounded-rooting.md - String.cpp rooting only (split/lines/words parts rooted by one all-ones record instead of per-64 chunks); no apply, no retention, no closure mint; B1/B2/B3 unchanged"
                }
          )
        , ( ( "String", "filter" )
          , TypeFaithful
                { scope = Transports
                , files = [ "elm-kernel-cpp/src/core/StringExports.cpp" ]
                , evidence = "class: full | entry: StringExports.cpp:Elm_Kernel_String_filter:281-297 | helpers: callCharToBoolClosure:217, materializeString:250 | type: elm/core/1.0.5/src/String.elm:575 ((Char -> Bool) -> String -> String) | B1: apply-only via eco_apply_closure_typed :294 | B2: C-stack only | B3: string alloc only | audited: 2026-10-05 (re-audit, plans/wide-object-tail-kind-words-phase-2.md 2.3/2.6: the only C++ changes are the EvalParamLayout encoding (hand-written byte arrays replaced by makeEvalParamLayout values with the same kinds; u16 num_params) and, in ListExports, closure kinds read from a ClosureKinds snapshot; no application, retention, fabrication or type change)"
                }
          )
        , ( ( "String", "foldl" )
          , TypeFaithful
                { scope = Transports
                , files = [ "elm-kernel-cpp/src/core/StringExports.cpp" ]
                , evidence = "class: full | entry: StringExports.cpp:Elm_Kernel_String_foldl:336-350 | type: elm/core/1.0.5/src/String.elm:584 ((Char -> b -> b) -> b -> String -> b) | B1: apply-only :346 via callFoldClosure:226 -> eco_apply_closure_typed; acc PK_Boxed :199 -> result :338/:349, shared b | B2: accHP :347 | B3: no alloc | audited: 2026-10-05 (re-audit, plans/wide-object-tail-kind-words-phase-2.md 2.3/2.6: the only C++ changes are the EvalParamLayout encoding (hand-written byte arrays replaced by makeEvalParamLayout values with the same kinds; u16 num_params) and, in ListExports, closure kinds read from a ClosureKinds snapshot; no application, retention, fabrication or type change)"
                }
          )
        , ( ( "String", "foldr" )
          , TypeFaithful
                { scope = Transports
                , files = [ "elm-kernel-cpp/src/core/StringExports.cpp" ]
                , evidence = "class: full | entry: StringExports.cpp:Elm_Kernel_String_foldr:352-366 | type: elm/core/1.0.5/src/String.elm:593 ((Char -> b -> b) -> b -> String -> b) | B1: apply-only :362 via callFoldClosure:226 -> eco_apply_closure_typed; acc PK_Boxed :199 -> result :354/:365, shared b | B2: accHP :363 | B3: no alloc | audited: 2026-10-05 (re-audit, plans/wide-object-tail-kind-words-phase-2.md 2.3/2.6: the only C++ changes are the EvalParamLayout encoding (hand-written byte arrays replaced by makeEvalParamLayout values with the same kinds; u16 num_params) and, in ListExports, closure kinds read from a ClosureKinds snapshot; no application, retention, fabrication or type change)"
                }
          )
        , ( ( "String", "fromList" )
          , TypeFaithful
                { scope = Inert
                , files = [ "elm-kernel-cpp/src/core/StringExports.cpp", "elm-kernel-cpp/src/core/String.cpp" ]
                , evidence = "class: vacuous | entry: StringExports.cpp:Elm_Kernel_String_fromList:63-66 | helpers: String.cpp:fromList:63-107 | type: elm/core/1.0.5/src/String.elm:520 (List Char -> String; elem type concrete) | B1: vacuous (no function-capable position) | B2: StackRootGuard :84/:99 RAII | B3: no closure alloc | audited: 2026-10-05 (re-audit, plans/wide-object-tail-kind-words-phase-2.md 2.3/2.6: the only C++ changes are the EvalParamLayout encoding (hand-written byte arrays replaced by makeEvalParamLayout values with the same kinds; u16 num_params) and, in ListExports, closure kinds read from a ClosureKinds snapshot; no application, retention, fabrication or type change) | re-audit 2026-10-06: plans/kernel-root-stack-bounded-rooting.md - String.cpp rooting only (split/lines/words parts rooted by one all-ones record instead of per-64 chunks); no apply, no retention, no closure mint; B1/B2/B3 unchanged"
                }
          )
        , ( ( "String", "fromNumber" )
          , TypeFaithful
                { scope = Inert
                , files = [ "elm-kernel-cpp/src/core/StringExports.cpp", "elm-kernel-cpp/src/core/String.cpp" ]
                , evidence = "class: vacuous | entry: StringExports.cpp:Elm_Kernel_String_fromNumber:145-151 | helpers: String.cpp:fromNumber:451 | type: 2 aliasing defs, both arrow/var-free: String.elm:458 fromInt Int->String; :494 fromFloat Float->String | B1: vacuous (no function-capable position) | B2: no static/global write | B3: no alloc | audited: 2026-10-05 (re-audit, plans/wide-object-tail-kind-words-phase-2.md 2.3/2.6: the only C++ changes are the EvalParamLayout encoding (hand-written byte arrays replaced by makeEvalParamLayout values with the same kinds; u16 num_params) and, in ListExports, closure kinds read from a ClosureKinds snapshot; no application, retention, fabrication or type change) | re-audit 2026-10-06: plans/kernel-root-stack-bounded-rooting.md - String.cpp rooting only (split/lines/words parts rooted by one all-ones record instead of per-64 chunks); no apply, no retention, no closure mint; B1/B2/B3 unchanged"
                }
          )
        , ( ( "String", "indexes" )
          , TypeFaithful
                { scope = Inert
                , files = [ "elm-kernel-cpp/src/core/StringExports.cpp", "elm-kernel-cpp/src/core/String.cpp" ]
                , evidence = "class: vacuous | entry: StringExports.cpp:Elm_Kernel_String_indexes:130-133 | helpers: String.cpp:indexes:435 | type: elm/core/1.0.5/src/String.elm:330 (String -> String -> List Int); alias indices :336 | B1: vacuous (no function-capable position) | B2: no static/global/task write | B3: no closure alloc | audited: 2026-10-05 (re-audit, plans/wide-object-tail-kind-words-phase-2.md 2.3/2.6: the only C++ changes are the EvalParamLayout encoding (hand-written byte arrays replaced by makeEvalParamLayout values with the same kinds; u16 num_params) and, in ListExports, closure kinds read from a ClosureKinds snapshot; no application, retention, fabrication or type change) | re-audit 2026-10-06: plans/kernel-root-stack-bounded-rooting.md - String.cpp rooting only (split/lines/words parts rooted by one all-ones record instead of per-64 chunks); no apply, no retention, no closure mint; B1/B2/B3 unchanged"
                }
          )
        , ( ( "String", "join" )
          , TypeFaithful
                { scope = Inert
                , files = [ "elm-kernel-cpp/src/core/StringExports.cpp", "elm-kernel-cpp/src/core/String.cpp" ]
                , evidence = "class: vacuous | entry: StringExports.cpp:Elm_Kernel_String_join:46-49 | helpers: String.cpp:join:30 | type: inferred-from-usage; use-site String.elm:202 (String -> Array String -> String); arrow/var-free | B1: vacuous (no function-capable position) | B2: no static/global write | B3: no alloc | audited: 2026-10-05 (re-audit, plans/wide-object-tail-kind-words-phase-2.md 2.3/2.6: the only C++ changes are the EvalParamLayout encoding (hand-written byte arrays replaced by makeEvalParamLayout values with the same kinds; u16 num_params) and, in ListExports, closure kinds read from a ClosureKinds snapshot; no application, retention, fabrication or type change) | re-audit 2026-10-06: plans/kernel-root-stack-bounded-rooting.md - String.cpp rooting only (split/lines/words parts rooted by one all-ones record instead of per-64 chunks); no apply, no retention, no closure mint; B1/B2/B3 unchanged"
                }
          )
        , ( ( "String", "length" )
          , TypeFaithful
                { scope = Inert
                , files = [ "elm-kernel-cpp/src/core/StringExports.cpp", "elm-kernel-cpp/src/core/String.cpp" ]
                , evidence = "class: vacuous | entry: StringExports.cpp:Elm_Kernel_String_length:18-27 | helpers: String.cpp:length:18-20 | type: elm/core/1.0.5/src/String.elm:112 (String -> Int) | B1: vacuous (no function-capable position) | B2: no static/global/task write | B3: no closure alloc | audited: 2026-10-05 (re-audit, plans/wide-object-tail-kind-words-phase-2.md 2.3/2.6: the only C++ changes are the EvalParamLayout encoding (hand-written byte arrays replaced by makeEvalParamLayout values with the same kinds; u16 num_params) and, in ListExports, closure kinds read from a ClosureKinds snapshot; no application, retention, fabrication or type change) | re-audit 2026-10-06: plans/kernel-root-stack-bounded-rooting.md - String.cpp rooting only (split/lines/words parts rooted by one all-ones record instead of per-64 chunks); no apply, no retention, no closure mint; B1/B2/B3 unchanged"
                }
          )
        , ( ( "String", "lines" )
          , TypeFaithful
                { scope = Inert
                , files = [ "elm-kernel-cpp/src/core/StringExports.cpp", "elm-kernel-cpp/src/core/String.cpp" ]
                , evidence = "class: vacuous | entry: StringExports.cpp:Elm_Kernel_String_lines:78-81 | helpers: String.cpp:lines:179-284 (2 arms) | type: elm/core/1.0.5/src/String.elm:218 (String -> List String) | B1: vacuous (no function-capable position) | B2: root ranges :211/:272 restored :222/:282 | B3: no closure alloc | audited: 2026-10-05 (re-audit, plans/wide-object-tail-kind-words-phase-2.md 2.3/2.6: the only C++ changes are the EvalParamLayout encoding (hand-written byte arrays replaced by makeEvalParamLayout values with the same kinds; u16 num_params) and, in ListExports, closure kinds read from a ClosureKinds snapshot; no application, retention, fabrication or type change) | re-audit 2026-10-06: plans/kernel-root-stack-bounded-rooting.md - String.cpp rooting only (split/lines/words parts rooted by one all-ones record instead of per-64 chunks); no apply, no retention, no closure mint; B1/B2/B3 unchanged"
                }
          )
        , ( ( "String", "map" )
          , TypeFaithful
                { scope = Transports
                , files = [ "elm-kernel-cpp/src/core/StringExports.cpp" ]
                , evidence = "class: full | entry: StringExports.cpp:Elm_Kernel_String_map:263-279 | helpers: callCharToCharClosure:206, materializeString:250 | type: elm/core/1.0.5/src/String.elm:566 ((Char -> Char) -> String -> String) | B1: apply-only via eco_apply_closure_eval :276 | B2: C-stack only | B3: string alloc only | audited: 2026-10-05 (re-audit, plans/wide-object-tail-kind-words-phase-2.md 2.3/2.6: the only C++ changes are the EvalParamLayout encoding (hand-written byte arrays replaced by makeEvalParamLayout values with the same kinds; u16 num_params) and, in ListExports, closure kinds read from a ClosureKinds snapshot; no application, retention, fabrication or type change)"
                }
          )
        , ( ( "String", "reverse" )
          , TypeFaithful
                { scope = Inert
                , files = [ "elm-kernel-cpp/src/core/StringExports.cpp", "elm-kernel-cpp/src/core/String.cpp" ]
                , evidence = "class: vacuous | entry: StringExports.cpp:Elm_Kernel_String_reverse:88-91 | helpers: String.cpp:reverse:395-397 | type: elm/core/1.0.5/src/String.elm:121 (String -> String) | B1: vacuous (no function-capable position) | B2: no static/global/task write | B3: no closure alloc | audited: 2026-10-05 (re-audit, plans/wide-object-tail-kind-words-phase-2.md 2.3/2.6: the only C++ changes are the EvalParamLayout encoding (hand-written byte arrays replaced by makeEvalParamLayout values with the same kinds; u16 num_params) and, in ListExports, closure kinds read from a ClosureKinds snapshot; no application, retention, fabrication or type change) | re-audit 2026-10-06: plans/kernel-root-stack-bounded-rooting.md - String.cpp rooting only (split/lines/words parts rooted by one all-ones record instead of per-64 chunks); no apply, no retention, no closure mint; B1/B2/B3 unchanged"
                }
          )
        , ( ( "String", "slice" )
          , TypeFaithful
                { scope = Inert
                , files = [ "elm-kernel-cpp/src/core/StringExports.cpp", "elm-kernel-cpp/src/core/String.cpp" ]
                , evidence = "class: vacuous | entry: StringExports.cpp:Elm_Kernel_String_slice:68-71 | helpers: String.cpp:slice:167-169 | type: elm/core/1.0.5/src/String.elm:235 (Int -> Int -> String -> String) | B1: vacuous (no function-capable position) | B2: no static/global/task write | B3: no closure alloc | audited: 2026-10-05 (re-audit, plans/wide-object-tail-kind-words-phase-2.md 2.3/2.6: the only C++ changes are the EvalParamLayout encoding (hand-written byte arrays replaced by makeEvalParamLayout values with the same kinds; u16 num_params) and, in ListExports, closure kinds read from a ClosureKinds snapshot; no application, retention, fabrication or type change) | re-audit 2026-10-06: plans/kernel-root-stack-bounded-rooting.md - String.cpp rooting only (split/lines/words parts rooted by one all-ones record instead of per-64 chunks); no apply, no retention, no closure mint; B1/B2/B3 unchanged"
                }
          )
        , ( ( "String", "split" )
          , TypeFaithful
                { scope = Inert
                , files = [ "elm-kernel-cpp/src/core/StringExports.cpp", "elm-kernel-cpp/src/core/String.cpp" ]
                , evidence = "class: vacuous | entry: StringExports.cpp:Elm_Kernel_String_split:73-76 | helpers: String.cpp:split:175 | type: inferred-from-usage; use-site String.elm:191 (String -> String -> Array String); arrow/var-free | B1: vacuous (no function-capable position) | B2: no static/global write | B3: no alloc | audited: 2026-10-05 (re-audit, plans/wide-object-tail-kind-words-phase-2.md 2.3/2.6: the only C++ changes are the EvalParamLayout encoding (hand-written byte arrays replaced by makeEvalParamLayout values with the same kinds; u16 num_params) and, in ListExports, closure kinds read from a ClosureKinds snapshot; no application, retention, fabrication or type change) | re-audit 2026-10-06: plans/kernel-root-stack-bounded-rooting.md - String.cpp rooting only (split/lines/words parts rooted by one all-ones record instead of per-64 chunks); no apply, no retention, no closure mint; B1/B2/B3 unchanged"
                }
          )
        , ( ( "String", "startsWith" )
          , TypeFaithful
                { scope = Inert
                , files = [ "elm-kernel-cpp/src/core/StringExports.cpp", "elm-kernel-cpp/src/core/String.cpp" ]
                , evidence = "class: vacuous | entry: StringExports.cpp:Elm_Kernel_String_startsWith:118-120 | helpers: String.cpp:startsWith:423-425 | type: elm/core/1.0.5/src/String.elm:309 (String -> String -> Bool) | B1: vacuous (no function-capable position) | B2: no static/global/task write | B3: embedded Bool consts, no alloc | audited: 2026-10-05 (re-audit, plans/wide-object-tail-kind-words-phase-2.md 2.3/2.6: the only C++ changes are the EvalParamLayout encoding (hand-written byte arrays replaced by makeEvalParamLayout values with the same kinds; u16 num_params) and, in ListExports, closure kinds read from a ClosureKinds snapshot; no application, retention, fabrication or type change) | re-audit 2026-10-06: plans/kernel-root-stack-bounded-rooting.md - String.cpp rooting only (split/lines/words parts rooted by one all-ones record instead of per-64 chunks); no apply, no retention, no closure mint; B1/B2/B3 unchanged"
                }
          )
        , ( ( "String", "toFloat" )
          , TypeFaithful
                { scope = Inert
                , files = [ "elm-kernel-cpp/src/core/StringExports.cpp", "elm-kernel-cpp/src/core/String.cpp" ]
                , evidence = "class: vacuous | entry: StringExports.cpp:Elm_Kernel_String_toFloat:140-143 | helpers: String.cpp:toFloat:447-449 | type: elm/core/1.0.5/src/String.elm:480 (String -> Maybe Float) | B1: vacuous (no function-capable position) | B2: no static/global/task write | B3: no closure alloc | audited: 2026-10-05 (re-audit, plans/wide-object-tail-kind-words-phase-2.md 2.3/2.6: the only C++ changes are the EvalParamLayout encoding (hand-written byte arrays replaced by makeEvalParamLayout values with the same kinds; u16 num_params) and, in ListExports, closure kinds read from a ClosureKinds snapshot; no application, retention, fabrication or type change) | re-audit 2026-10-06: plans/kernel-root-stack-bounded-rooting.md - String.cpp rooting only (split/lines/words parts rooted by one all-ones record instead of per-64 chunks); no apply, no retention, no closure mint; B1/B2/B3 unchanged"
                }
          )
        , ( ( "String", "toInt" )
          , TypeFaithful
                { scope = Inert
                , files = [ "elm-kernel-cpp/src/core/StringExports.cpp", "elm-kernel-cpp/src/core/String.cpp" ]
                , evidence = "class: vacuous | entry: StringExports.cpp:Elm_Kernel_String_toInt:135-138 | helpers: String.cpp:toInt:443-445 | type: elm/core/1.0.5/src/String.elm:445 (String -> Maybe Int) | B1: vacuous (no function-capable position) | B2: no static/global/task write | B3: no closure alloc | audited: 2026-10-05 (re-audit, plans/wide-object-tail-kind-words-phase-2.md 2.3/2.6: the only C++ changes are the EvalParamLayout encoding (hand-written byte arrays replaced by makeEvalParamLayout values with the same kinds; u16 num_params) and, in ListExports, closure kinds read from a ClosureKinds snapshot; no application, retention, fabrication or type change) | re-audit 2026-10-06: plans/kernel-root-stack-bounded-rooting.md - String.cpp rooting only (split/lines/words parts rooted by one all-ones record instead of per-64 chunks); no apply, no retention, no closure mint; B1/B2/B3 unchanged"
                }
          )
        , ( ( "String", "toLower" )
          , TypeFaithful
                { scope = Inert
                , files = [ "elm-kernel-cpp/src/core/StringExports.cpp", "elm-kernel-cpp/src/core/String.cpp" ]
                , evidence = "class: vacuous | entry: StringExports.cpp:Elm_Kernel_String_toLower:98-101 | helpers: String.cpp:toLower:403-405 | type: elm/core/1.0.5/src/String.elm:359 (String -> String) | B1: vacuous (no function-capable position) | B2: no static/global/task write | B3: no closure alloc | audited: 2026-10-05 (re-audit, plans/wide-object-tail-kind-words-phase-2.md 2.3/2.6: the only C++ changes are the EvalParamLayout encoding (hand-written byte arrays replaced by makeEvalParamLayout values with the same kinds; u16 num_params) and, in ListExports, closure kinds read from a ClosureKinds snapshot; no application, retention, fabrication or type change) | re-audit 2026-10-06: plans/kernel-root-stack-bounded-rooting.md - String.cpp rooting only (split/lines/words parts rooted by one all-ones record instead of per-64 chunks); no apply, no retention, no closure mint; B1/B2/B3 unchanged"
                }
          )
        , ( ( "String", "toUpper" )
          , TypeFaithful
                { scope = Inert
                , files = [ "elm-kernel-cpp/src/core/StringExports.cpp", "elm-kernel-cpp/src/core/String.cpp" ]
                , evidence = "class: vacuous | entry: StringExports.cpp:Elm_Kernel_String_toUpper:93-96 | helpers: String.cpp:toUpper:399-401 | type: elm/core/1.0.5/src/String.elm:350 (String -> String) | B1: vacuous (no function-capable position) | B2: no static/global/task write | B3: no closure alloc | audited: 2026-10-05 (re-audit, plans/wide-object-tail-kind-words-phase-2.md 2.3/2.6: the only C++ changes are the EvalParamLayout encoding (hand-written byte arrays replaced by makeEvalParamLayout values with the same kinds; u16 num_params) and, in ListExports, closure kinds read from a ClosureKinds snapshot; no application, retention, fabrication or type change) | re-audit 2026-10-06: plans/kernel-root-stack-bounded-rooting.md - String.cpp rooting only (split/lines/words parts rooted by one all-ones record instead of per-64 chunks); no apply, no retention, no closure mint; B1/B2/B3 unchanged"
                }
          )
        , ( ( "String", "trim" )
          , TypeFaithful
                { scope = Inert
                , files = [ "elm-kernel-cpp/src/core/StringExports.cpp", "elm-kernel-cpp/src/core/String.cpp" ]
                , evidence = "class: vacuous | entry: StringExports.cpp:Elm_Kernel_String_trim:103-106 | helpers: String.cpp:trim:407-409 | type: elm/core/1.0.5/src/String.elm:405 (String -> String) | B1: vacuous (no function-capable position) | B2: no static/global/task write | B3: no closure alloc | audited: 2026-10-05 (re-audit, plans/wide-object-tail-kind-words-phase-2.md 2.3/2.6: the only C++ changes are the EvalParamLayout encoding (hand-written byte arrays replaced by makeEvalParamLayout values with the same kinds; u16 num_params) and, in ListExports, closure kinds read from a ClosureKinds snapshot; no application, retention, fabrication or type change) | re-audit 2026-10-06: plans/kernel-root-stack-bounded-rooting.md - String.cpp rooting only (split/lines/words parts rooted by one all-ones record instead of per-64 chunks); no apply, no retention, no closure mint; B1/B2/B3 unchanged"
                }
          )
        , ( ( "String", "trimLeft" )
          , TypeFaithful
                { scope = Inert
                , files = [ "elm-kernel-cpp/src/core/StringExports.cpp", "elm-kernel-cpp/src/core/String.cpp" ]
                , evidence = "class: vacuous | entry: StringExports.cpp:Elm_Kernel_String_trimLeft:108-111 | helpers: String.cpp:trimLeft:411-413 | type: elm/core/1.0.5/src/String.elm:414 (String -> String) | B1: vacuous (no function-capable position) | B2: no static/global/task write | B3: no closure alloc | audited: 2026-10-05 (re-audit, plans/wide-object-tail-kind-words-phase-2.md 2.3/2.6: the only C++ changes are the EvalParamLayout encoding (hand-written byte arrays replaced by makeEvalParamLayout values with the same kinds; u16 num_params) and, in ListExports, closure kinds read from a ClosureKinds snapshot; no application, retention, fabrication or type change) | re-audit 2026-10-06: plans/kernel-root-stack-bounded-rooting.md - String.cpp rooting only (split/lines/words parts rooted by one all-ones record instead of per-64 chunks); no apply, no retention, no closure mint; B1/B2/B3 unchanged"
                }
          )
        , ( ( "String", "trimRight" )
          , TypeFaithful
                { scope = Inert
                , files = [ "elm-kernel-cpp/src/core/StringExports.cpp", "elm-kernel-cpp/src/core/String.cpp" ]
                , evidence = "class: vacuous | entry: StringExports.cpp:Elm_Kernel_String_trimRight:113-116 | helpers: String.cpp:trimRight:415-417 | type: elm/core/1.0.5/src/String.elm:423 (String -> String) | B1: vacuous (no function-capable position) | B2: no static/global/task write | B3: no closure alloc | audited: 2026-10-05 (re-audit, plans/wide-object-tail-kind-words-phase-2.md 2.3/2.6: the only C++ changes are the EvalParamLayout encoding (hand-written byte arrays replaced by makeEvalParamLayout values with the same kinds; u16 num_params) and, in ListExports, closure kinds read from a ClosureKinds snapshot; no application, retention, fabrication or type change) | re-audit 2026-10-06: plans/kernel-root-stack-bounded-rooting.md - String.cpp rooting only (split/lines/words parts rooted by one all-ones record instead of per-64 chunks); no apply, no retention, no closure mint; B1/B2/B3 unchanged"
                }
          )
        , ( ( "String", "uncons" )
          , TypeFaithful
                { scope = Inert
                , files = [ "elm-kernel-cpp/src/core/StringExports.cpp", "elm-kernel-cpp/src/core/String.cpp" ]
                , evidence = "class: vacuous | entry: StringExports.cpp:Elm_Kernel_String_uncons:58-61 | helpers: String.cpp:uncons:42-44 | type: elm/core/1.0.5/src/String.elm:553 (String -> Maybe (Char, String); slots concrete) | B1: vacuous (no function-capable position) | B2: no static/global/task write | B3: no closure alloc | audited: 2026-10-05 (re-audit, plans/wide-object-tail-kind-words-phase-2.md 2.3/2.6: the only C++ changes are the EvalParamLayout encoding (hand-written byte arrays replaced by makeEvalParamLayout values with the same kinds; u16 num_params) and, in ListExports, closure kinds read from a ClosureKinds snapshot; no application, retention, fabrication or type change) | re-audit 2026-10-06: plans/kernel-root-stack-bounded-rooting.md - String.cpp rooting only (split/lines/words parts rooted by one all-ones record instead of per-64 chunks); no apply, no retention, no closure mint; B1/B2/B3 unchanged"
                }
          )
        , ( ( "String", "words" )
          , TypeFaithful
                { scope = Inert
                , files = [ "elm-kernel-cpp/src/core/StringExports.cpp", "elm-kernel-cpp/src/core/String.cpp" ]
                , evidence = "class: vacuous | entry: StringExports.cpp:Elm_Kernel_String_words:83-86 | helpers: String.cpp:words:286-389 (two arms) | type: elm/core/1.0.5/src/String.elm:209 (String -> List String) | B1: vacuous (no function-capable position) | B2: root ranges :321/:372 restored :334/:387 | B3: no closure alloc | audited: 2026-10-05 (re-audit, plans/wide-object-tail-kind-words-phase-2.md 2.3/2.6: the only C++ changes are the EvalParamLayout encoding (hand-written byte arrays replaced by makeEvalParamLayout values with the same kinds; u16 num_params) and, in ListExports, closure kinds read from a ClosureKinds snapshot; no application, retention, fabrication or type change) | re-audit 2026-10-06: plans/kernel-root-stack-bounded-rooting.md - String.cpp rooting only (split/lines/words parts rooted by one all-ones record instead of per-64 chunks); no apply, no retention, no closure mint; B1/B2/B3 unchanged"
                }
          )
        , ( ( "Time", "getZoneName" )
          , TypeFaithful
                { scope = Transports
                , files = [ "elm-kernel-cpp/src/time/TimeExports.cpp" ]
                , evidence = "class: cheap | entry: TimeExports.cpp:Elm_Kernel_Time_getZoneName:286-293 | type: elm/time/1.0.0/src/Time.elm (Task x ZoneName) | B1: same binding shape as Time.here - unit capture, concrete result | B2: no store outside the returned Task | B3: binding closure only, payload unit | audited: 2026-10-05 (re-audit, plans/wide-object-tail-kind-words-phase-2.md 2.3/2.6: the only C++ changes are the EvalParamLayout encoding (hand-written byte arrays replaced by makeEvalParamLayout values with the same kinds; u16 num_params) and, in ListExports, closure kinds read from a ClosureKinds snapshot; no application, retention, fabrication or type change)"
                }
          )
        , ( ( "Time", "here" )
          , TypeFaithful
                { scope = Transports
                , files = [ "elm-kernel-cpp/src/time/TimeExports.cpp" ]
                , evidence = "class: cheap | entry: TimeExports.cpp:Elm_Kernel_Time_here:279-284 | type: elm/time/1.0.0/src/Time.elm (Task x Zone) | B1: makeBinding<timeHereBody>(unit()) - the ONLY capture is unit; Zone is concrete, so no function value can enter or leave | B2: no store outside the returned Task | B3: mints a binding closure, but it lands in Task.callback where NO type variable names it and its payload is unit | audited: 2026-10-05 (re-audit, plans/wide-object-tail-kind-words-phase-2.md 2.3/2.6: the only C++ changes are the EvalParamLayout encoding (hand-written byte arrays replaced by makeEvalParamLayout values with the same kinds; u16 num_params) and, in ListExports, closure kinds read from a ClosureKinds snapshot; no application, retention, fabrication or type change)"
                }
          )
        , ( ( "Url", "percentDecode" )
          , TypeFaithful
                { scope = Inert
                , files = [ "elm-kernel-cpp/src/url/UrlExports.cpp" ]
                , evidence = "class: vacuous | entry: UrlExports.cpp:Elm_Kernel_Url_percentDecode:65-101 | helpers: elmStringToStd:18-20, hexToInt:33-38 | type: elm/url/1.0.0/src/Url.elm:288 | B1: vacuous (no function-capable position) | B2: grep `static` over UrlExports.cpp: zero hits | B3: grep clean (no allocClosure) | audited: 2026-08-20"
                }
          )
        , ( ( "Url", "percentEncode" )
          , TypeFaithful
                { scope = Inert
                , files = [ "elm-kernel-cpp/src/url/UrlExports.cpp" ]
                , evidence = "class: vacuous | entry: UrlExports.cpp:Elm_Kernel_Url_percentEncode:44-63 | helpers: elmStringToStd:18-20, shouldEncode:23-30 | type: elm/url/1.0.0/src/Url.elm:255 | B1: vacuous (no function-capable position) | B2: grep `static` over UrlExports.cpp: zero hits | B3: grep clean (no allocClosure) | audited: 2026-08-20"
                }
          )
        , ( ( "Utils", "append" )
          , TypeFaithful
                { scope = Transports
                , files = [ "elm-kernel-cpp/src/core/UtilsExports.cpp", "elm-kernel-cpp/src/core/Utils.cpp" ]
                , evidence = "class: cheap | entry: UtilsExports.cpp:Elm_Kernel_Utils_append:161-171 | helpers: Utils.cpp:append:809-833 | type: elm/core/1.0.5/src/Basics.elm:510 | B1: B1(b)/(c); slots copied verbatim, b aliased as tail, no apply | B2: result is sole write target; roots balanced | B3: no closure alloc; slots unwrapped | audited: 2026-10-05 (re-audit, plans/wide-object-tail-kind-words-phase-1.md 1c: the only C++ changes are kind READS -- Custom/Record equality reads slot kinds through customSlotKind/recordSlotKind and closureNewArgKind reads slots >= 25 as boxed, both identical to before below the header cap and UB-free past it; no application, retention, fabrication or type change)"
                }
          )
        , ( ( "Utils", "compare" )
          , TypeFaithful
                { scope = Inert
                , files = [ "elm-kernel-cpp/src/core/UtilsExports.cpp", "elm-kernel-cpp/src/core/Utils.cpp" ]
                , evidence = "class: vacuous | entry: UtilsExports.cpp:Elm_Kernel_Utils_compare:14-17 | helpers: Utils.cpp:compare:437-443, :cmp:288-431 | type: elm/core/1.0.5/src/Basics.elm:418 (comparable -> comparable -> Order) | B1: vacuous (no function-capable position) | B2: no static mutable storage | B3: no closure alloc | audited: 2026-10-05 (re-audit, plans/wide-object-tail-kind-words-phase-1.md 1c: the only C++ changes are kind READS -- Custom/Record equality reads slot kinds through customSlotKind/recordSlotKind and closureNewArgKind reads slots >= 25 as boxed, both identical to before below the header cap and UB-free past it; no application, retention, fabrication or type change)"
                }
          )
        , ( ( "Utils", "equal" )
          , TypeFaithful
                { scope = Transports
                , files = [ "elm-kernel-cpp/src/core/UtilsExports.cpp", "elm-kernel-cpp/src/core/Utils.cpp" ]
                , evidence = "class: cheap | entry: UtilsExports.cpp:Elm_Kernel_Utils_equal:108-110 | helpers: Utils.cpp:eqHelp:507-720 | type: elm/core/1.0.5/src/Basics.elm:348 (a -> a -> Bool) | B1: reads only :557-696; Tag_Closure arm :713-715 | B2: no static mutable storage; dictEq scratch frame-local | B3: no allocClosure/papCreate | audited: 2026-10-05 (re-audit, plans/wide-object-tail-kind-words-phase-1.md 1c: the only C++ changes are kind READS -- Custom/Record equality reads slot kinds through customSlotKind/recordSlotKind and closureNewArgKind reads slots >= 25 as boxed, both identical to before below the header cap and UB-free past it; no application, retention, fabrication or type change)"
                }
          )
        , ( ( "Utils", "ge" )
          , TypeFaithful
                { scope = Inert
                , files = [ "elm-kernel-cpp/src/core/UtilsExports.cpp", "elm-kernel-cpp/src/core/Utils.cpp" ]
                , evidence = "class: vacuous | entry: UtilsExports.cpp:Elm_Kernel_Utils_ge:128-130 | helpers: Utils.cpp:ge:801-803, :cmp:288-431 | type: elm/core/1.0.5/src/Basics.elm:385 (comparable -> comparable -> Bool) | B1: vacuous (no function-capable position) | B2: no static mutable storage | B3: no closure alloc | audited: 2026-10-05 (re-audit, plans/wide-object-tail-kind-words-phase-1.md 1c: the only C++ changes are kind READS -- Custom/Record equality reads slot kinds through customSlotKind/recordSlotKind and closureNewArgKind reads slots >= 25 as boxed, both identical to before below the header cap and UB-free past it; no application, retention, fabrication or type change)"
                }
          )
        , ( ( "Utils", "gt" )
          , TypeFaithful
                { scope = Inert
                , files = [ "elm-kernel-cpp/src/core/UtilsExports.cpp", "elm-kernel-cpp/src/core/Utils.cpp" ]
                , evidence = "class: vacuous | entry: UtilsExports.cpp:Elm_Kernel_Utils_gt:124-126 | helpers: Utils.cpp:gt:797-799, :cmp:288-431 | type: elm/core/1.0.5/src/Basics.elm:373 (comparable -> comparable -> Bool) | B1: vacuous (no function-capable position) | B2: no static mutable storage | B3: no closure alloc | audited: 2026-10-05 (re-audit, plans/wide-object-tail-kind-words-phase-1.md 1c: the only C++ changes are kind READS -- Custom/Record equality reads slot kinds through customSlotKind/recordSlotKind and closureNewArgKind reads slots >= 25 as boxed, both identical to before below the header cap and UB-free past it; no application, retention, fabrication or type change)"
                }
          )
        , ( ( "Utils", "le" )
          , TypeFaithful
                { scope = Inert
                , files = [ "elm-kernel-cpp/src/core/UtilsExports.cpp", "elm-kernel-cpp/src/core/Utils.cpp" ]
                , evidence = "class: vacuous | entry: UtilsExports.cpp:Elm_Kernel_Utils_le:120-122 | helpers: Utils.cpp:le:793-795, :cmp:288-431 | type: elm/core/1.0.5/src/Basics.elm:379 (comparable -> comparable -> Bool) | B1: vacuous (no function-capable position) | B2: no static mutable storage | B3: no closure alloc | audited: 2026-10-05 (re-audit, plans/wide-object-tail-kind-words-phase-1.md 1c: the only C++ changes are kind READS -- Custom/Record equality reads slot kinds through customSlotKind/recordSlotKind and closureNewArgKind reads slots >= 25 as boxed, both identical to before below the header cap and UB-free past it; no application, retention, fabrication or type change)"
                }
          )
        , ( ( "Utils", "lt" )
          , TypeFaithful
                { scope = Inert
                , files = [ "elm-kernel-cpp/src/core/UtilsExports.cpp", "elm-kernel-cpp/src/core/Utils.cpp" ]
                , evidence = "class: vacuous | entry: UtilsExports.cpp:Elm_Kernel_Utils_lt:116-118 | helpers: Utils.cpp:lt:789-791, :cmp:288-431 | type: elm/core/1.0.5/src/Basics.elm:367 (comparable -> comparable -> Bool) | B1: vacuous (no function-capable position) | B2: no static mutable storage | B3: no closure alloc | audited: 2026-10-05 (re-audit, plans/wide-object-tail-kind-words-phase-1.md 1c: the only C++ changes are kind READS -- Custom/Record equality reads slot kinds through customSlotKind/recordSlotKind and closureNewArgKind reads slots >= 25 as boxed, both identical to before below the header cap and UB-free past it; no application, retention, fabrication or type change)"
                }
          )
        , ( ( "Utils", "notEqual" )
          , TypeFaithful
                { scope = Transports
                , files = [ "elm-kernel-cpp/src/core/UtilsExports.cpp", "elm-kernel-cpp/src/core/Utils.cpp" ]
                , evidence = "class: cheap | entry: UtilsExports.cpp:Elm_Kernel_Utils_notEqual:112-114 | helpers: Utils.cpp:eqHelp:507-720 (shared with equal) | type: elm/core/1.0.5/src/Basics.elm:357 (a -> a -> Bool) | B1: reads only :557-696; Tag_Closure arm :713-715 | B2: no static mutable storage | B3: no allocClosure/papCreate | audited: 2026-10-05 (re-audit, plans/wide-object-tail-kind-words-phase-1.md 1c: the only C++ changes are kind READS -- Custom/Record equality reads slot kinds through customSlotKind/recordSlotKind and closureNewArgKind reads slots >= 25 as boxed, both identical to before below the header cap and UB-free past it; no application, retention, fabrication or type change)"
                }
          )
        ]


{-| Returns the shape of a `List` of `el`.
-}
tsList : TypeShape -> TypeShape
tsList el =
    TsCon "List" [ el ]


{-| The shape of the JSON `Value` type.
-}
tsValue : TypeShape
tsValue =
    TsCon "Value" []
