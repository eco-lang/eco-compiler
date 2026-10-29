module Compiler.MonoSolver.KernelSetFacts exposing
    ( ParamSetFlow(..), KernelPlan, LicenseScope(..), TypeShape(..), License, KernelSetFact(..)
    , factFor, licenseApplies, shapeOfAnnotation, rows
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

`factFor` looks a kernel up by its prefix, home module and name, and the answer is one
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

A row's audit is kept outside this module, in two CSV files beside it, keyed by
the kernel's `Prefix.Home.name`:

  - `kernel-license-audit.csv` has one line per audit or re-audit of a row:
    `kernel,date,plan,note`. The first audit's note records `class`, `entry`
    (the C++ entry point), `type` (the Elm type audited), `B1` (how function
    values move through the kernel), `B2` (what it stores outside its result)
    and `B3` (whether it allocates a closure). The class is `vacuous` when the
    type has no function-capable position. `cheap` and `full` are the auditor's
    recorded judgement of the rest, and do not follow from the arrows in the
    type. A license is `Inert` exactly when its class is `vacuous`.
  - `kernel-license-files.csv` lists, for each license, the C++ files its
    audit read: `kernel,file,sha256,audited`, where `audited` is the date of
    the kernel's latest audit line.

`test/scripts/check-kernel-license-manifest.sh` checks the two files against
this table and the C++ tree, so an edit to an audited C++ file, or a license
with no audit, fails the build. It reads this module as text to find each row's
key, kind and scope, so that part of the table's layout is part of the check.


## What the table cannot detect

  - **A change to a kernel's Elm type.** The manifest hashes C++ only. An
    `Inert` license is re-checked at every occurrence and a `TransportsAs`
    license is matched against its declared shape, but a `Transports` license
    is not checked at all, so a change to such a kernel's type needs a new
    audit.
  - **One kernel at several types.** A kernel can be reached through several
    annotated definitions, as `String.fromNumber` is through both
    `String.fromInt` and `String.fromFloat`, so a row is a claim about every
    type the kernel can be used at, not only the one its audit quotes.
  - **A duplicate key.** Two rows with the same prefix, home and name do not
    fail: `Dict.fromList` keeps the later one.

@docs ParamSetFlow, KernelPlan, LicenseScope, TypeShape, License, KernelSetFact
@docs factFor, licenseApplies, shapeOfAnnotation, rows

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
for each parameter, in order, and one for the result. Its audit is kept outside
this module, as the module docstring describes. A call whose parameters cannot be
aligned with `params` is fully poisoned instead.
-}
type alias KernelPlan =
    { params : List ParamSetFlow

    -- PSFOpaque poisons the result's arrows; the other two leave them alone.
    , result : ParamSetFlow
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


{-| A kernel's license: its `LicenseScope`. The C++ files its audit read and the
audit itself are kept outside this module, as the module docstring describes.
-}
type alias License =
    { scope : LicenseScope
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


{-| Returns the fact for the kernel `name` in module `prefix.Kernel.home`, or
`Nothing` when it has no row and every function-typed position of a call to it
is to be poisoned. The prefix, `Elm` or `Eco`, is part of the key, because
the two kernels share some homes (`File`, `Http`, `Process`) and a row audits
one kernel's C++.

A `TypeFaithful` fact needs no alignment with the call, because partial and
over-application are handled by unification, but `licenseApplies` must accept
the occurrence. A `Positional` fact applies only to a call whose parameters
can be aligned with the row's `params`, and any other call is fully poisoned.

-}
factFor : Name -> Name -> Name -> Maybe KernelSetFact
factFor prefix home name =
    Dict.get ( prefix, home, name ) facts


{-| Every row of the table, ordered by prefix, home module and name.
-}
rows : List ( ( Name, Name, Name ), KernelSetFact )
rows =
    Dict.toList facts


{-| The table, keyed by kernel prefix, home module and name. Each row's audit is in
`kernel-license-audit.csv`, beside this module.
-}
facts : Dict.Dict ( Name, Name, Name ) KernelSetFact
facts =
    Dict.fromList
        [ ( ( "Elm", "Basics", "acos" )
          , TypeFaithful
                { scope = Inert
                }
          )
        , ( ( "Elm", "Basics", "add" )
          , TypeFaithful
                { scope = Inert
                }
          )
        , ( ( "Elm", "Basics", "and" )
          , TypeFaithful
                { scope = Inert
                }
          )
        , ( ( "Elm", "Basics", "asin" )
          , TypeFaithful
                { scope = Inert
                }
          )
        , ( ( "Elm", "Basics", "atan" )
          , TypeFaithful
                { scope = Inert
                }
          )
        , ( ( "Elm", "Basics", "atan2" )
          , TypeFaithful
                { scope = Inert
                }
          )
        , ( ( "Elm", "Basics", "ceiling" )
          , TypeFaithful
                { scope = Inert
                }
          )
        , ( ( "Elm", "Basics", "cos" )
          , TypeFaithful
                { scope = Inert
                }
          )
        , ( ( "Elm", "Basics", "e" )
          , TypeFaithful
                { scope = Inert
                }
          )
        , ( ( "Elm", "Basics", "fdiv" )
          , TypeFaithful
                { scope = Inert
                }
          )
        , ( ( "Elm", "Basics", "floor" )
          , TypeFaithful
                { scope = Inert
                }
          )
        , ( ( "Elm", "Basics", "idiv" )
          , TypeFaithful
                { scope = Inert
                }
          )
        , ( ( "Elm", "Basics", "isInfinite" )
          , TypeFaithful
                { scope = Inert
                }
          )
        , ( ( "Elm", "Basics", "isNaN" )
          , TypeFaithful
                { scope = Inert
                }
          )
        , ( ( "Elm", "Basics", "log" )
          , TypeFaithful
                { scope = Inert
                }
          )
        , ( ( "Elm", "Basics", "modBy" )
          , TypeFaithful
                { scope = Inert
                }
          )
        , ( ( "Elm", "Basics", "mul" )
          , TypeFaithful
                { scope = Inert
                }
          )
        , ( ( "Elm", "Basics", "not" )
          , TypeFaithful
                { scope = Inert
                }
          )
        , ( ( "Elm", "Basics", "or" )
          , TypeFaithful
                { scope = Inert
                }
          )
        , ( ( "Elm", "Basics", "pi" )
          , TypeFaithful
                { scope = Inert
                }
          )
        , ( ( "Elm", "Basics", "pow" )
          , TypeFaithful
                { scope = Inert
                }
          )
        , ( ( "Elm", "Basics", "remainderBy" )
          , TypeFaithful
                { scope = Inert
                }
          )
        , ( ( "Elm", "Basics", "round" )
          , TypeFaithful
                { scope = Inert
                }
          )
        , ( ( "Elm", "Basics", "sin" )
          , TypeFaithful
                { scope = Inert
                }
          )
        , ( ( "Elm", "Basics", "sqrt" )
          , TypeFaithful
                { scope = Inert
                }
          )
        , ( ( "Elm", "Basics", "sub" )
          , TypeFaithful
                { scope = Inert
                }
          )
        , ( ( "Elm", "Basics", "tan" )
          , TypeFaithful
                { scope = Inert
                }
          )
        , ( ( "Elm", "Basics", "toFloat" )
          , TypeFaithful
                { scope = Inert
                }
          )
        , ( ( "Elm", "Basics", "truncate" )
          , TypeFaithful
                { scope = Inert
                }
          )
        , ( ( "Elm", "Basics", "xor" )
          , TypeFaithful
                { scope = Inert
                }
          )
        , ( ( "Elm", "Bitwise", "and" )
          , TypeFaithful
                { scope = Inert
                }
          )
        , ( ( "Elm", "Bitwise", "complement" )
          , TypeFaithful
                { scope = Inert
                }
          )
        , ( ( "Elm", "Bitwise", "or" )
          , TypeFaithful
                { scope = Inert
                }
          )
        , ( ( "Elm", "Bitwise", "shiftLeftBy" )
          , TypeFaithful
                { scope = Inert
                }
          )
        , ( ( "Elm", "Bitwise", "shiftRightBy" )
          , TypeFaithful
                { scope = Inert
                }
          )
        , ( ( "Elm", "Bitwise", "shiftRightZfBy" )
          , TypeFaithful
                { scope = Inert
                }
          )
        , ( ( "Elm", "Bitwise", "xor" )
          , TypeFaithful
                { scope = Inert
                }
          )
        , ( ( "Elm", "Bytes", "decode" )
          , Positional
                { params = [ PSFApplies, PSFOpaque ]
                , result = PSFOpaque
                }
          )
        , ( ( "Elm", "Bytes", "decodeFailure" )
          , TypeFaithful
                { scope = Inert
                }
          )
        , ( ( "Elm", "Bytes", "encode" )
          , TypeFaithful
                { scope = Inert
                }
          )
        , ( ( "Elm", "Bytes", "getHostEndianness" )
          , TypeFaithful
                { scope = Inert
                }
          )
        , ( ( "Elm", "Bytes", "getStringWidth" )
          , TypeFaithful
                { scope = Inert
                }
          )
        , ( ( "Elm", "Bytes", "read_bytes" )
          , TypeFaithful
                { scope = Inert
                }
          )
        , ( ( "Elm", "Bytes", "read_f32" )
          , TypeFaithful
                { scope = Inert
                }
          )
        , ( ( "Elm", "Bytes", "read_f64" )
          , TypeFaithful
                { scope = Inert
                }
          )
        , ( ( "Elm", "Bytes", "read_i16" )
          , TypeFaithful
                { scope = Inert
                }
          )
        , ( ( "Elm", "Bytes", "read_i32" )
          , TypeFaithful
                { scope = Inert
                }
          )
        , ( ( "Elm", "Bytes", "read_i8" )
          , TypeFaithful
                { scope = Inert
                }
          )
        , ( ( "Elm", "Bytes", "read_string" )
          , TypeFaithful
                { scope = Inert
                }
          )
        , ( ( "Elm", "Bytes", "read_u16" )
          , TypeFaithful
                { scope = Inert
                }
          )
        , ( ( "Elm", "Bytes", "read_u32" )
          , TypeFaithful
                { scope = Inert
                }
          )
        , ( ( "Elm", "Bytes", "read_u8" )
          , TypeFaithful
                { scope = Inert
                }
          )
        , ( ( "Elm", "Bytes", "width" )
          , TypeFaithful
                { scope = Inert
                }
          )
        , ( ( "Elm", "Bytes", "write_bytes" )
          , TypeFaithful
                { scope = Inert
                }
          )
        , ( ( "Elm", "Bytes", "write_f32" )
          , TypeFaithful
                { scope = Inert
                }
          )
        , ( ( "Elm", "Bytes", "write_f64" )
          , TypeFaithful
                { scope = Inert
                }
          )
        , ( ( "Elm", "Bytes", "write_i16" )
          , TypeFaithful
                { scope = Inert
                }
          )
        , ( ( "Elm", "Bytes", "write_i32" )
          , TypeFaithful
                { scope = Inert
                }
          )
        , ( ( "Elm", "Bytes", "write_i8" )
          , TypeFaithful
                { scope = Inert
                }
          )
        , ( ( "Elm", "Bytes", "write_string" )
          , TypeFaithful
                { scope = Inert
                }
          )
        , ( ( "Elm", "Bytes", "write_u16" )
          , TypeFaithful
                { scope = Inert
                }
          )
        , ( ( "Elm", "Bytes", "write_u32" )
          , TypeFaithful
                { scope = Inert
                }
          )
        , ( ( "Elm", "Bytes", "write_u8" )
          , TypeFaithful
                { scope = Inert
                }
          )
        , ( ( "Elm", "Char", "fromCode" )
          , TypeFaithful
                { scope = Inert
                }
          )
        , ( ( "Elm", "Char", "toCode" )
          , TypeFaithful
                { scope = Inert
                }
          )
        , ( ( "Elm", "Char", "toLocaleLower" )
          , TypeFaithful
                { scope = Inert
                }
          )
        , ( ( "Elm", "Char", "toLocaleUpper" )
          , TypeFaithful
                { scope = Inert
                }
          )
        , ( ( "Elm", "Char", "toLower" )
          , TypeFaithful
                { scope = Inert
                }
          )
        , ( ( "Elm", "Char", "toUpper" )
          , TypeFaithful
                { scope = Inert
                }
          )
        , ( ( "Eco", "Console", "log" )
          , TypeFaithful
                { scope = Transports
                }
          )
        , ( ( "Eco", "Console", "readAll" )
          , TypeFaithful
                { scope = Inert
                }
          )
        , ( ( "Eco", "Console", "readLine" )
          , TypeFaithful
                { scope = Inert
                }
          )
        , ( ( "Eco", "Console", "write" )
          , TypeFaithful
                { scope = Inert
                }
          )
        , ( ( "Eco", "Crash", "crash" )
          , TypeFaithful
                { scope = Transports
                }
          )
        , ( ( "Eco", "Env", "lookup" )
          , TypeFaithful
                { scope = Inert
                }
          )
        , ( ( "Eco", "Env", "rawArgs" )
          , TypeFaithful
                { scope = Inert
                }
          )
        , ( ( "Eco", "File", "appDataDir" )
          , TypeFaithful
                { scope = Inert
                }
          )
        , ( ( "Eco", "File", "canonicalize" )
          , TypeFaithful
                { scope = Inert
                }
          )
        , ( ( "Eco", "File", "close" )
          , TypeFaithful
                { scope = Inert
                }
          )
        , ( ( "Eco", "File", "createDir" )
          , TypeFaithful
                { scope = Inert
                }
          )
        , ( ( "Eco", "File", "dirExists" )
          , TypeFaithful
                { scope = Inert
                }
          )
        , ( ( "Eco", "File", "fileExists" )
          , TypeFaithful
                { scope = Inert
                }
          )
        , ( ( "Eco", "File", "findExecutable" )
          , TypeFaithful
                { scope = Inert
                }
          )
        , ( ( "Eco", "File", "getCwd" )
          , TypeFaithful
                { scope = Inert
                }
          )
        , ( ( "Eco", "File", "hWriteString" )
          , TypeFaithful
                { scope = Inert
                }
          )
        , ( ( "Eco", "File", "list" )
          , TypeFaithful
                { scope = Inert
                }
          )
        , ( ( "Eco", "File", "lock" )
          , TypeFaithful
                { scope = Inert
                }
          )
        , ( ( "Elm", "File", "mime" )
          , TypeFaithful
                { scope = Inert
                }
          )
        , ( ( "Eco", "File", "modificationTime" )
          , TypeFaithful
                { scope = Inert
                }
          )
        , ( ( "Elm", "File", "name" )
          , TypeFaithful
                { scope = Inert
                }
          )
        , ( ( "Eco", "File", "open" )
          , TypeFaithful
                { scope = Inert
                }
          )
        , ( ( "Eco", "File", "readBytes" )
          , TypeFaithful
                { scope = Inert
                }
          )
        , ( ( "Eco", "File", "readString" )
          , TypeFaithful
                { scope = Inert
                }
          )
        , ( ( "Eco", "File", "removeDir" )
          , TypeFaithful
                { scope = Inert
                }
          )
        , ( ( "Eco", "File", "removeFile" )
          , TypeFaithful
                { scope = Inert
                }
          )
        , ( ( "Eco", "File", "setCwd" )
          , TypeFaithful
                { scope = Inert
                }
          )
        , ( ( "Elm", "File", "size" )
          , TypeFaithful
                { scope = Inert
                }
          )
        , ( ( "Eco", "File", "size" )
          , TypeFaithful
                { scope = Inert
                }
          )
        , ( ( "Eco", "File", "touch" )
          , TypeFaithful
                { scope = Inert
                }
          )
        , ( ( "Eco", "File", "unlock" )
          , TypeFaithful
                { scope = Inert
                }
          )
        , ( ( "Eco", "File", "writeBytes" )
          , TypeFaithful
                { scope = Inert
                }
          )
        , ( ( "Eco", "File", "writeBytesAtomic" )
          , TypeFaithful
                { scope = Inert
                }
          )
        , ( ( "Eco", "File", "writeString" )
          , TypeFaithful
                { scope = Inert
                }
          )
        , ( ( "Elm", "Http", "emptyBody" )
          , TypeFaithful
                { scope = Inert
                }
          )
        , ( ( "Eco", "Http", "fetch" )
          , TypeFaithful
                { scope = Inert
                }
          )
        , ( ( "Eco", "Http", "getArchive" )
          , TypeFaithful
                { scope = Inert
                }
          )
        , ( ( "Elm", "Http", "pair" )
          , TypeFaithful
                { scope = Inert
                }
          )
        , ( ( "Elm", "Http", "toFormData" )
          , TypeFaithful
                { scope = Inert
                }
          )
        , ( ( "Elm", "JsArray", "appendN" )
          , TypeFaithful
                { scope = Transports
                }
          )
        , ( ( "Elm", "JsArray", "empty" )
          , TypeFaithful
                { scope = Transports
                }
          )
        , ( ( "Elm", "JsArray", "foldl" )
          , TypeFaithful
                { scope = Transports
                }
          )
        , ( ( "Elm", "JsArray", "foldr" )
          , TypeFaithful
                { scope = Transports
                }
          )
        , ( ( "Elm", "JsArray", "indexedMap" )
          , TypeFaithful
                { scope = Transports
                }
          )
        , ( ( "Elm", "JsArray", "initialize" )
          , TypeFaithful
                { scope = Transports
                }
          )
        , ( ( "Elm", "JsArray", "initializeFromList" )
          , TypeFaithful
                { scope = Transports
                }
          )
        , ( ( "Elm", "JsArray", "length" )
          , TypeFaithful
                { scope = Transports
                }
          )
        , ( ( "Elm", "JsArray", "map" )
          , TypeFaithful
                { scope = Transports
                }
          )
        , ( ( "Elm", "JsArray", "push" )
          , TypeFaithful
                { scope = Transports
                }
          )
        , ( ( "Elm", "JsArray", "singleton" )
          , TypeFaithful
                { scope = Transports
                }
          )
        , ( ( "Elm", "JsArray", "slice" )
          , TypeFaithful
                { scope = Transports
                }
          )
        , ( ( "Elm", "JsArray", "unsafeGet" )
          , TypeFaithful
                { scope = Transports
                }
          )
        , ( ( "Elm", "JsArray", "unsafeSet" )
          , TypeFaithful
                { scope = Transports
                }
          )
        , ( ( "Elm", "Json", "addField" )
          , TypeFaithful
                { scope = Inert
                }
          )
        , ( ( "Elm", "Json", "addEntry" )
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
                }
          )
        , ( ( "Elm", "Json", "decodeArray" )
          , TypeFaithful
                { scope = Transports
                }
          )
        , ( ( "Elm", "Json", "andThen" )
          , TypeFaithful
                { scope = Transports
                }
          )
        , ( ( "Elm", "Json", "decodeBool" )
          , TypeFaithful
                { scope = Inert
                }
          )
        , ( ( "Elm", "Json", "decodeField" )
          , TypeFaithful
                { scope = Transports
                }
          )
        , ( ( "Elm", "Json", "decodeFloat" )
          , TypeFaithful
                { scope = Inert
                }
          )
        , ( ( "Elm", "Json", "decodeIndex" )
          , TypeFaithful
                { scope = Transports
                }
          )
        , ( ( "Elm", "Json", "decodeInt" )
          , TypeFaithful
                { scope = Inert
                }
          )
        , ( ( "Elm", "Json", "decodeList" )
          , TypeFaithful
                { scope = Transports
                }
          )
        , ( ( "Elm", "Json", "decodeKeyValuePairs" )
          , TypeFaithful
                { scope = Transports
                }
          )
        , ( ( "Elm", "Json", "decodeNull" )
          , TypeFaithful
                { scope = Transports
                }
          )
        , ( ( "Elm", "Json", "decodeString" )
          , TypeFaithful
                { scope = Inert
                }
          )
        , ( ( "Elm", "Json", "decodeValue" )
          , TypeFaithful
                { scope = Inert
                }
          )
        , ( ( "Elm", "Json", "emptyArray" )
          , TypeFaithful
                { scope = Inert
                }
          )
        , ( ( "Elm", "Json", "emptyObject" )
          , TypeFaithful
                { scope = Inert
                }
          )
        , ( ( "Elm", "Json", "encode" )
          , TypeFaithful
                { scope = Inert
                }
          )
        , ( ( "Elm", "Json", "encodeNull" )
          , TypeFaithful
                { scope = Inert
                }
          )
        , ( ( "Elm", "Json", "runOnString" )
          , TypeFaithful
                { scope = Transports
                }
          )
        , ( ( "Elm", "Json", "run" )
          , TypeFaithful
                { scope = Transports
                }
          )
        , ( ( "Elm", "Json", "oneOf" )
          , TypeFaithful
                { scope = Transports
                }
          )
        , ( ( "Elm", "Json", "fail" )
          , TypeFaithful
                { scope = Transports
                }
          )
        , ( ( "Elm", "Json", "succeed" )
          , TypeFaithful
                { scope = Transports
                }
          )
        , ( ( "Elm", "Json", "map8" )
          , TypeFaithful
                { scope = Transports
                }
          )
        , ( ( "Elm", "Json", "map7" )
          , TypeFaithful
                { scope = Transports
                }
          )
        , ( ( "Elm", "Json", "map6" )
          , TypeFaithful
                { scope = Transports
                }
          )
        , ( ( "Elm", "Json", "map5" )
          , TypeFaithful
                { scope = Transports
                }
          )
        , ( ( "Elm", "Json", "map4" )
          , TypeFaithful
                { scope = Transports
                }
          )
        , ( ( "Elm", "Json", "map3" )
          , TypeFaithful
                { scope = Transports
                }
          )
        , ( ( "Elm", "Json", "map2" )
          , TypeFaithful
                { scope = Transports
                }
          )
        , ( ( "Elm", "Json", "map1" )
          , TypeFaithful
                { scope = Transports
                }
          )
        , ( ( "Elm", "List", "cons" )
          , TypeFaithful
                { scope = Transports
                }
          )
        , ( ( "Elm", "List", "fromArray" )
          , TypeFaithful
                { scope = TransportsAs (TsFun (tsList (TsVar "a")) (tsList (TsVar "a")))
                }
          )
        , ( ( "Elm", "List", "map2" )
          , TypeFaithful
                { scope = Transports
                }
          )
        , ( ( "Elm", "List", "map3" )
          , TypeFaithful
                { scope = Transports
                }
          )
        , ( ( "Elm", "List", "map4" )
          , TypeFaithful
                { scope = Transports
                }
          )
        , ( ( "Elm", "List", "map5" )
          , TypeFaithful
                { scope = Transports
                }
          )
        , ( ( "Elm", "List", "toArray" )
          , TypeFaithful
                { scope = TransportsAs (TsFun (tsList (TsVar "a")) (tsList (TsVar "a")))
                }
          )
        , ( ( "Elm", "List", "sortBy" )
          , TypeFaithful
                { scope = Transports
                }
          )
        , ( ( "Elm", "List", "sortWith" )
          , TypeFaithful
                { scope = Transports
                }
          )
        , ( ( "Eco", "MVar", "drop" )
          , TypeFaithful
                { scope = Transports
                }
          )
        , ( ( "Eco", "MVar", "new" )
          , TypeFaithful
                { scope = Transports
                }
          )
        , ( ( "Eco", "NativeDriver", "lowerAndLink" )
          , TypeFaithful
                { scope = Inert
                }
          )
        , ( ( "Eco", "NativeDriver", "lowerAndLinkBytes" )
          , TypeFaithful
                { scope = Inert
                }
          )
        , ( ( "Elm", "Parser", "chompBase10" )
          , TypeFaithful
                { scope = Inert
                }
          )
        , ( ( "Elm", "Parser", "consumeBase" )
          , TypeFaithful
                { scope = Inert
                }
          )
        , ( ( "Elm", "Parser", "consumeBase16" )
          , TypeFaithful
                { scope = Inert
                }
          )
        , ( ( "Elm", "Parser", "findSubString" )
          , TypeFaithful
                { scope = Inert
                }
          )
        , ( ( "Elm", "Parser", "isAsciiCode" )
          , TypeFaithful
                { scope = Inert
                }
          )
        , ( ( "Elm", "Parser", "isSubChar" )
          , TypeFaithful
                { scope = Transports
                }
          )
        , ( ( "Elm", "Parser", "isSubString" )
          , TypeFaithful
                { scope = Inert
                }
          )
        , ( ( "Elm", "Platform", "batch" )
          , TypeFaithful
                { scope = Transports
                }
          )
        , ( ( "Eco", "Process", "exit" )
          , TypeFaithful
                { scope = Inert
                }
          )
        , ( ( "Elm", "Process", "sleep" )
          , TypeFaithful
                { scope = Transports
                }
          )
        , ( ( "Eco", "Process", "spawn" )
          , TypeFaithful
                { scope = Inert
                }
          )
        , ( ( "Eco", "Process", "spawnProcess" )
          , TypeFaithful
                { scope = Inert
                }
          )
        , ( ( "Eco", "Process", "wait" )
          , TypeFaithful
                { scope = Inert
                }
          )
        , ( ( "Elm", "Regex", "contains" )
          , TypeFaithful
                { scope = Inert
                }
          )
        , ( ( "Elm", "Regex", "findAtMost" )
          , TypeFaithful
                { scope = Inert
                }
          )
        , ( ( "Elm", "Regex", "fromStringWith" )
          , TypeFaithful
                { scope = Inert
                }
          )
        , ( ( "Elm", "Regex", "infinity" )
          , TypeFaithful
                { scope = Inert
                }
          )
        , ( ( "Elm", "Regex", "never" )
          , TypeFaithful
                { scope = Inert
                }
          )
        , ( ( "Elm", "Regex", "replaceAtMost" )
          , TypeFaithful
                { scope = Transports
                }
          )
        , ( ( "Elm", "Regex", "splitAtMost" )
          , TypeFaithful
                { scope = Inert
                }
          )
        , ( ( "Eco", "Runtime", "dirname" )
          , TypeFaithful
                { scope = Inert
                }
          )
        , ( ( "Eco", "Runtime", "loadState" )
          , TypeFaithful
                { scope = Inert
                }
          )
        , ( ( "Eco", "Runtime", "random" )
          , TypeFaithful
                { scope = Inert
                }
          )
        , ( ( "Eco", "Runtime", "saveState" )
          , TypeFaithful
                { scope = Inert
                }
          )
        , ( ( "Elm", "Scheduler", "andThen" )
          , TypeFaithful
                { scope = Transports
                }
          )
        , ( ( "Elm", "Scheduler", "fail" )
          , TypeFaithful
                { scope = Transports
                }
          )
        , ( ( "Elm", "Scheduler", "kill" )
          , TypeFaithful
                { scope = Transports
                }
          )
        , ( ( "Elm", "Scheduler", "onError" )
          , TypeFaithful
                { scope = Transports
                }
          )
        , ( ( "Elm", "Scheduler", "spawn" )
          , TypeFaithful
                { scope = Transports
                }
          )
        , ( ( "Elm", "Scheduler", "succeed" )
          , TypeFaithful
                { scope = Transports
                }
          )
        , ( ( "Elm", "String", "all" )
          , TypeFaithful
                { scope = Transports
                }
          )
        , ( ( "Elm", "String", "any" )
          , TypeFaithful
                { scope = Transports
                }
          )
        , ( ( "Elm", "String", "append" )
          , TypeFaithful
                { scope = Inert
                }
          )
        , ( ( "Elm", "String", "cons" )
          , TypeFaithful
                { scope = Inert
                }
          )
        , ( ( "Elm", "String", "contains" )
          , TypeFaithful
                { scope = Inert
                }
          )
        , ( ( "Elm", "String", "endsWith" )
          , TypeFaithful
                { scope = Inert
                }
          )
        , ( ( "Elm", "String", "filter" )
          , TypeFaithful
                { scope = Transports
                }
          )
        , ( ( "Elm", "String", "foldl" )
          , TypeFaithful
                { scope = Transports
                }
          )
        , ( ( "Elm", "String", "foldr" )
          , TypeFaithful
                { scope = Transports
                }
          )
        , ( ( "Elm", "String", "fromList" )
          , TypeFaithful
                { scope = Inert
                }
          )
        , ( ( "Elm", "String", "fromNumber" )
          , TypeFaithful
                { scope = Inert
                }
          )
        , ( ( "Elm", "String", "indexes" )
          , TypeFaithful
                { scope = Inert
                }
          )
        , ( ( "Elm", "String", "join" )
          , TypeFaithful
                { scope = Inert
                }
          )
        , ( ( "Elm", "String", "length" )
          , TypeFaithful
                { scope = Inert
                }
          )
        , ( ( "Elm", "String", "lines" )
          , TypeFaithful
                { scope = Inert
                }
          )
        , ( ( "Elm", "String", "map" )
          , TypeFaithful
                { scope = Transports
                }
          )
        , ( ( "Elm", "String", "reverse" )
          , TypeFaithful
                { scope = Inert
                }
          )
        , ( ( "Elm", "String", "slice" )
          , TypeFaithful
                { scope = Inert
                }
          )
        , ( ( "Elm", "String", "split" )
          , TypeFaithful
                { scope = Inert
                }
          )
        , ( ( "Elm", "String", "startsWith" )
          , TypeFaithful
                { scope = Inert
                }
          )
        , ( ( "Elm", "String", "toFloat" )
          , TypeFaithful
                { scope = Inert
                }
          )
        , ( ( "Elm", "String", "toInt" )
          , TypeFaithful
                { scope = Inert
                }
          )
        , ( ( "Elm", "String", "toLower" )
          , TypeFaithful
                { scope = Inert
                }
          )
        , ( ( "Elm", "String", "toUpper" )
          , TypeFaithful
                { scope = Inert
                }
          )
        , ( ( "Elm", "String", "trim" )
          , TypeFaithful
                { scope = Inert
                }
          )
        , ( ( "Elm", "String", "trimLeft" )
          , TypeFaithful
                { scope = Inert
                }
          )
        , ( ( "Elm", "String", "trimRight" )
          , TypeFaithful
                { scope = Inert
                }
          )
        , ( ( "Elm", "String", "uncons" )
          , TypeFaithful
                { scope = Inert
                }
          )
        , ( ( "Elm", "String", "words" )
          , TypeFaithful
                { scope = Inert
                }
          )
        , ( ( "Elm", "Time", "getZoneName" )
          , TypeFaithful
                { scope = Transports
                }
          )
        , ( ( "Elm", "Time", "here" )
          , TypeFaithful
                { scope = Transports
                }
          )
        , ( ( "Elm", "Url", "percentDecode" )
          , TypeFaithful
                { scope = Inert
                }
          )
        , ( ( "Elm", "Url", "percentEncode" )
          , TypeFaithful
                { scope = Inert
                }
          )
        , ( ( "Elm", "Utils", "append" )
          , TypeFaithful
                { scope = Transports
                }
          )
        , ( ( "Elm", "Utils", "compare" )
          , TypeFaithful
                { scope = Inert
                }
          )
        , ( ( "Elm", "Utils", "equal" )
          , TypeFaithful
                { scope = Transports
                }
          )
        , ( ( "Elm", "Utils", "ge" )
          , TypeFaithful
                { scope = Inert
                }
          )
        , ( ( "Elm", "Utils", "gt" )
          , TypeFaithful
                { scope = Inert
                }
          )
        , ( ( "Elm", "Utils", "le" )
          , TypeFaithful
                { scope = Inert
                }
          )
        , ( ( "Elm", "Utils", "lt" )
          , TypeFaithful
                { scope = Inert
                }
          )
        , ( ( "Elm", "Utils", "notEqual" )
          , TypeFaithful
                { scope = Transports
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
