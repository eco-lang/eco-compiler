module Compiler.Type.Type exposing
    ( Constraint(..), exists
    , Type(..)
    , bool, char, float, int, string, never
    , funType
    , vec2, vec3, vec4, mat4, texture
    , mkFlexVar, mkFlexNumber, nameToFlex, nameToRigid
    , unnamedFlexVar, unnamedFlexSuper
    , noRank, outermostRank, noMark, nextMark
    , toAnnotation, toErrorType, toCanTypeBatch
    )

{-| Constraint generation and the solver need one vocabulary for what must be
true of a program's types and for the types themselves, and this module is that
vocabulary, together with the way back from solved variables to types a person
can read.

Type inference works on type variables that are points of a union-find store
(`Compiler.Type.UnionFind`), not on named variables as they appear in source.
Two variables found to be equal are joined into one class, and what is known
about the class is held in a descriptor on its root (`Compiler.AST.TypeVars`).
A `Constraint` says what must hold, a `Type` is a type built over such
variables, and the solver turns both into classes and joins them.

A descriptor carries two numbers the solver needs besides the content. Its
_rank_ is the let-nesting depth the class belongs to, which generalization
uses to decide what it may quantify; `noRank` and `outermostRank` are the two
reserved values. Its _mark_ is a stamp a walk of the type graph leaves on the
classes it visits, so that it can stop on a class it has already reached.

The rest of the module, from `toAnnotation` on, converts a solved variable
back into a `Can.Type` or an error type. A variable with no name is given one
while it is converted, and the conversion is not read-only: see "Converting
solved variables" below.


# Constraints

The solver works on a tree of constraints generated from the source:

@docs Constraint, exists


# Type Representation

Types with unifiable variables for inference:

@docs Type


# Type Constructors

Commonly used built-in types:

@docs bool, char, float, int, string, never
@docs funType


# WebGL Types

@docs vec2, vec3, vec4, mat4, texture


# Type Variables

@docs mkFlexVar, mkFlexNumber, nameToFlex, nameToRigid
@docs unnamedFlexVar, unnamedFlexSuper


# Rank and Mark

Ranks track let levels for generalization; marks stamp the classes a walk has
visited.

@docs noRank, outermostRank, noMark, nextMark


# Converting solved variables

Each conversion first collects the names the variables already carry, then
converts the variable under a naming scope (`System.TypeCheck.IO.withFreshNames`)
seeded with those names, in which every generated name is new. Converting
changes the store in three ways. A variable without a name has the generated
name written into its descriptor. A user's variable whose name another, distinct
variable already holds is renamed by a numeric suffix (`a` to `a1`, `a2`, ...).
And the collecting walk stamps every class it visits with a fixed mark that it
never takes off, so a later conversion's collecting walk skips those classes and
does not see their names.

@docs toAnnotation, toErrorType, toCanTypeBatch

-}

import Array exposing (Array)
import Compiler.AST.Canonical as Can
import Compiler.AST.TypeVars as Vars exposing (Content(..), Descriptor, FlatType(..), Mark(..), SuperType(..), Variable)
import Compiler.AST.Utils.Type as Type
import Compiler.Data.Name as Name exposing (Name)
import Compiler.Elm.ModuleName as ModuleName
import Compiler.Reporting.Annotation as A
import Compiler.Reporting.Error.Type as E
import Compiler.Type.Error as ET
import Compiler.Type.UnionFind as UF
import Dict exposing (Dict)
import Maybe.Extra as Maybe
import System.TypeCheck.IO as IO exposing (IO, NameState)
import Utils.Crash exposing (crash)



-- ====== CONSTRAINTS ======


{-| A tree of the facts about types that the solver must make true, with what to
report when one cannot be.

`CTrue` holds trivially. `CSaveTheEnvironment` asks the solver to record the
environment of names in scope at this point.

`CEqual` requires a type to equal an expected type, and `CPattern` does the same
for a pattern. `CLocal` requires the type of a name bound locally to equal the
expected type; the name's type is copied from its scheme first. `CForeign` does
the same for a name defined elsewhere, whose type is given as its annotation.
Each carries the region and the expectation an error is reported with.

`CAnd` requires all of its constraints.

`CLet rigids flexes header headerCon bodyCon` introduces the variables `rigids`
and `flexes` and solves `headerCon`, then binds each name of `header` to its
type and solves `bodyCon` with those names in scope. When it has variables to
introduce, the header's types are solved one rank deeper and generalized, which
is how let-polymorphism arises. A `CLet` with no rigids and a body of `CTrue`
only introduces `flexes` for `headerCon`; `exists` builds that form.

-}
type Constraint
    = CTrue
    | CSaveTheEnvironment
    | CEqual A.Region E.Category Type (E.Expected Type)
    | CLocal A.Region Name (E.Expected Type)
    | CForeign A.Region Name (Can.Annotation Name) (E.Expected Type)
    | CPattern A.Region E.PCategory Type (E.PExpected Type)
    | CAnd (List Constraint)
    | CLet (List Variable) (List Variable) (Dict Name (A.Located Type)) Constraint Constraint


{-| Returns `constraint` with the variables `flexVars` introduced for it, binding
no names.
-}
exists : List Variable -> Constraint -> Constraint
exists flexVars constraint =
    CLet [] flexVars Dict.empty constraint CTrue



-- ====== TYPE PRIMITIVES ======


{-| A type as constraint generation writes it, whose variables are points of the
union-find store rather than names.

The solver turns a `Type` into a class of the store before unifying it.

`AliasN` is a use of a type alias: the module and name of the alias, its
arguments by parameter name, and the type it stands for. `VarN` is a solver
variable. `AppN` is a named type applied to arguments. `FunN` is a function
type from its first type to its second. `RecordN` is a record's fields and the
type it extends, which is `EmptyRecordN` for a closed record. `UnitN` is the
unit type `()`. `TupleN` holds a tuple's first two types and the rest.

-}
type Type
    = AliasN ModuleName.Canonical Name (List ( Name, Type )) Type
    | VarN Variable
    | AppN ModuleName.Canonical Name (List Type)
    | FunN Type Type
    | EmptyRecordN
    | RecordN (Dict Name Type) Type
    | UnitN
    | TupleN Type Type (List Type)



-- ====== DESCRIPTORS ======


{-| Returns a descriptor for `content` with no rank, no mark and no copy.
-}
makeDescriptor : Content -> Descriptor
makeDescriptor content =
    IO.makeDescriptor content noRank noMark Nothing



-- ====== RANKS ======


{-| The rank that belongs to no let level.

It is the rank of every variable this module makes, and of the descriptor
`Compiler.Type.Unify` writes when a unification fails. The solver gives every
generalized variable this rank. The solver's check that a variable can be
generalized compares a rank against it.

-}
noRank : Int
noRank =
    0


{-| The rank of the outermost let level, the one just above `noRank`.
-}
outermostRank : Int
outermostRank =
    1



-- ====== MARKS ======


{-| The mark of a class that no walk has stamped.

Every variable this module makes carries it. It differs from the two marks the
conversions below use, so a fresh variable is never mistaken for one they have
visited.

-}
noMark : Mark
noMark =
    Mark 2


{-| The mark `toErrorType` puts on a class while it is converting it, so that
reaching the class again from inside itself is recognised as an infinite type.
-}
occursMark : Mark
occursMark =
    Mark 1


{-| The mark `getVarNames` leaves on every class it visits. It is never removed.
-}
getVarNamesMark : Mark
getVarNamesMark =
    Mark 0


{-| Returns the mark one above `mark`.

The fixed marks are `getVarNamesMark` (0), `occursMark` (1) and `noMark` (2), so
a mark obtained by stepping from `noMark` differs from all three.

-}
nextMark : Mark -> Mark
nextMark (Mark mark) =
    Mark (mark + 1)



-- ====== FUNCTION TYPES ======


{-| Returns the function type from the first type to the second.
-}
funType : Type -> Type -> Type
funType =
    FunN



-- ====== PRIMITIVE TYPES ======


{-| The Int type.
-}
int : Type
int =
    AppN ModuleName.basics "Int" []


{-| The Float type.
-}
float : Type
float =
    AppN ModuleName.basics "Float" []


{-| The Char type.
-}
char : Type
char =
    AppN ModuleName.char "Char" []


{-| The String type.
-}
string : Type
string =
    AppN ModuleName.string "String" []


{-| The Bool type.
-}
bool : Type
bool =
    AppN ModuleName.basics "Bool" []


{-| The Never type, which has no values.
-}
never : Type
never =
    AppN ModuleName.basics "Never" []



-- ====== WEBGL TYPES ======


{-| The `Vec2` type of `Math.Vector2`, as WebGL shaders use it.
-}
vec2 : Type
vec2 =
    AppN ModuleName.vector2 "Vec2" []


{-| The `Vec3` type of `Math.Vector3`, as WebGL shaders use it.
-}
vec3 : Type
vec3 =
    AppN ModuleName.vector3 "Vec3" []


{-| The `Vec4` type of `Math.Vector4`, as WebGL shaders use it.
-}
vec4 : Type
vec4 =
    AppN ModuleName.vector4 "Vec4" []


{-| The `Mat4` type of `Math.Matrix4`, as WebGL shaders use it.
-}
mat4 : Type
mat4 =
    AppN ModuleName.matrix4 "Mat4" []


{-| The `Texture` type of `WebGL.Texture`.
-}
texture : Type
texture =
    AppN ModuleName.texture "Texture" []



-- ====== MAKE FLEX VARIABLES ======


{-| Creates a new flex variable with no name, which unification may bind to any
type.
-}
mkFlexVar : IO Variable
mkFlexVar =
    UF.fresh flexVarDescriptor


{-| The descriptor of a new unnamed flex variable.
-}
flexVarDescriptor : Descriptor
flexVarDescriptor =
    makeDescriptor unnamedFlexVar


{-| The content of a flex variable with no name. Converting it back to a type
gives it a generated name.
-}
unnamedFlexVar : Content
unnamedFlexVar =
    FlexVar Nothing



-- ====== MAKE FLEX NUMBERS ======


{-| Creates a new flex variable with no name, constrained to `number`.
-}
mkFlexNumber : IO Variable
mkFlexNumber =
    UF.fresh flexNumberDescriptor


{-| The descriptor of a new unnamed flex variable constrained to `number`.
-}
flexNumberDescriptor : Descriptor
flexNumberDescriptor =
    makeDescriptor (unnamedFlexSuper Number)


{-| The content of a flex variable with no name, constrained by `super`.
-}
unnamedFlexSuper : SuperType -> Content
unnamedFlexSuper super =
    FlexSuper super Nothing



-- ====== MAKE NAMED VARIABLES ======


{-| Creates a new flex variable called `name`.

A name that starts with `number`, `comparable`, `appendable` or `compappend`
gives a flex variable constrained by that super-type, as
`Compiler.Data.Name.isNumberType` and its neighbours decide.

-}
nameToFlex : Name -> IO Variable
nameToFlex name =
    Maybe.unwrap FlexVar FlexSuper (toSuper name) (Just name) |> makeDescriptor |> UF.fresh


{-| Creates a new rigid variable called `name`, a variable that unification may
not bind to a type.

A name that starts with `number`, `comparable`, `appendable` or `compappend`
gives a rigid variable constrained by that super-type, as for `nameToFlex`.

-}
nameToRigid : Name -> IO Variable
nameToRigid name =
    Maybe.unwrap RigidVar RigidSuper (toSuper name) name |> makeDescriptor |> UF.fresh


{-| Returns the super-type a variable called `name` is constrained by, if any.
-}
toSuper : Name -> Maybe SuperType
toSuper name =
    if Name.isNumberType name then
        Just Number

    else if Name.isComparableType name then
        Just Comparable

    else if Name.isAppendableType name then
        Just Appendable

    else if Name.isCompappendType name then
        Just CompAppend

    else
        Nothing



-- ====== TO TYPE ANNOTATION ======


{-| Converts the solved type of `variable` to an annotation.

The annotation quantifies over every name taken in the naming scope: the names
the type's variables already carried and those generated for it. Unnamed
variables are named, and the store is changed, as "Converting solved variables"
describes. Crashes on a class whose content is a unification error, and on a
lambda set that is not in a function type's set slot.

-}
toAnnotation : Variable -> IO (Can.Annotation Name)
toAnnotation variable =
    getVarNames variable Dict.empty
        |> IO.andThen
            (\userNames ->
                IO.withFreshNames (makeNameState userNames)
                    (variableToCanType variable
                        |> IO.andThen
                            (\tipe ->
                                IO.getNames
                                    |> IO.map (\nsData -> Can.Forall nsData.taken tipe)
                            )
                    )
            )


{-| Converts each variable of `nodeVars` to a `Can.Type`, keeping `Nothing` where
there is no variable.

All of them are converted in one naming scope, so a name generated for one
variable is never generated again for another: two unnamed lambda parameters do
not both become `a`.

`annotationNames` are names to reserve: no generated name is one of them.
Typically they are the names earlier `toAnnotation` calls gave, whose variables
keep those names. They must be passed in rather than found by `getVarNames`:
`toAnnotation`'s own `getVarNames` walk left `getVarNamesMark` on each of those
variables, so the walk below skips them and would not see their names.

Crashes in the same cases as `toAnnotation`.

-}
toCanTypeBatch : Dict Name () -> Array (Maybe Variable) -> IO (Array (Maybe (Can.Type Name)))
toCanTypeBatch annotationNames nodeVars =
    IO.foldMArray
        (\names maybeVar ->
            case maybeVar of
                Nothing ->
                    IO.pure names

                Just var ->
                    getVarNames var names
        )
        Dict.empty
        nodeVars
        |> IO.andThen
            (\allUserNames ->
                let
                    nameState =
                        makeNameState allUserNames
                in
                IO.withFreshNames { nameState | taken = Dict.union nameState.taken annotationNames }
                    (IO.traverseArrayMaybe variableToCanType nodeVars)
            )


{-| Converts the solved type of `variable` to a `Can.Type`, naming unnamed
variables as it goes.

The result is remembered by union-find root for the rest of the naming scope
(`IO.withFreshNames`), for alias nodes and the structures `worthMemo` accepts,
and a remembered root is not converted again. That is valid only while
nothing is unified inside the scope: then the first visit writes every
generated name back into the descriptors, so a second conversion of the same
root would build an equal tree and call no fresh-name generator: skipping it leaves the name
state and the output unchanged.

-}
variableToCanType : Variable -> IO (Can.Type Name)
variableToCanType variable =
    UF.repr variable
        |> IO.andThen
            (\root ->
                let
                    (Vars.Pt rootIdx) =
                        root
                in
                IO.getNames
                    |> IO.andThen
                        (\ns ->
                            case Dict.get rootIdx ns.canMemo of
                                Just t ->
                                    IO.pure t

                                Nothing ->
                                    variableToCanTypeMiss rootIdx root
                        )
            )


{-| Records `t` as the conversion of the root with index `rootIdx` in the current
naming scope, and returns it.

The name state is read afresh here, not passed in, because converting the
subtree may have generated names since it was last read.

-}
rememberCanType : Int -> Can.Type Name -> IO (Can.Type Name)
rememberCanType rootIdx t =
    IO.getNames
        |> IO.andThen (\ns -> IO.putNames { ns | canMemo = Dict.insert rootIdx t ns.canMemo })
        |> IO.map (\_ -> t)


{-| Tells whether the conversion of a structure is worth remembering: true for
an applied type with arguments, a function, a record and a tuple. The others
convert in constant time.
-}
worthMemo : FlatType -> Bool
worthMemo term =
    case term of
        App1 _ _ args ->
            not (List.isEmpty args)

        Fun1 _ _ ->
            True

        FunL _ _ _ ->
            True

        Record1 _ _ ->
            True

        Tuple1 _ _ _ ->
            True

        _ ->
            False


{-| Converts `variable`, whose root has index `rootIdx` and nothing remembered for
it, to a `Can.Type`.

An unnamed flex variable is given a generated name, which is written into its
descriptor. A use of an alias becomes a `Can.TAlias` with its body `Filled`.
Crashes on a class whose content is a unification error.

-}
variableToCanTypeMiss : Int -> Variable -> IO (Can.Type Name)
variableToCanTypeMiss rootIdx variable =
    UF.get variable
        |> IO.andThen
            (\descProps ->
                case descProps.content of
                    Structure term ->
                        if worthMemo term then
                            termToCanType term |> IO.andThen (rememberCanType rootIdx)

                        else
                            termToCanType term

                    FlexVar maybeName ->
                        case maybeName of
                            Just name ->
                                IO.pure (Can.TVar name)

                            Nothing ->
                                getFreshVarName
                                    |> IO.andThen
                                        (\name ->
                                            UF.modify variable
                                                (\props ->
                                                    IO.makeDescriptor (FlexVar (Just name)) props.rank props.mark props.copy
                                                )
                                                |> IO.map (\_ -> Can.TVar name)
                                        )

                    FlexSuper super maybeName ->
                        case maybeName of
                            Just name ->
                                IO.pure (Can.TVar name)

                            Nothing ->
                                getFreshSuperName super
                                    |> IO.andThen
                                        (\name ->
                                            UF.modify variable
                                                (\props ->
                                                    IO.makeDescriptor (FlexSuper super (Just name)) props.rank props.mark props.copy
                                                )
                                                |> IO.map (\_ -> Can.TVar name)
                                        )

                    RigidVar name ->
                        IO.pure (Can.TVar name)

                    RigidSuper _ name ->
                        IO.pure (Can.TVar name)

                    Alias home name args realVariable ->
                        IO.traverseList (IO.traverseTuple variableToCanType) args
                            |> IO.andThen
                                (\canArgs ->
                                    variableToCanType realVariable
                                        |> IO.map
                                            (\canType ->
                                                Can.TAlias home name canArgs (Can.Filled canType)
                                            )
                                )
                            |> IO.andThen (rememberCanType rootIdx)

                    Error ->
                        crash "cannot handle Error types in variableToCanType"
            )


{-| Converts one structure to a `Can.Type`.

A function type with a lambda set (`FunL`) becomes a plain `Can.TLambda`.
A record's fields are merged with those of the record it extends, after
aliases are removed from the extension, so the result names only the last
extension variable; a field present in both keeps the extension's type.
Crashes on a lambda set outside a function type's set slot, and on a record
extension that is neither a record nor a variable.

-}
termToCanType : FlatType -> IO (Can.Type Name)
termToCanType term =
    case term of
        App1 home name args ->
            IO.traverseList variableToCanType args
                |> IO.map (Can.TType home name)

        Fun1 a b ->
            IO.pure Can.tLambda
                |> IO.apply (variableToCanType a)
                |> IO.apply (variableToCanType b)

        FunL a b _ ->
            IO.pure Can.tLambda
                |> IO.apply (variableToCanType a)
                |> IO.apply (variableToCanType b)

        LambdaSet1 _ ->
            -- A lambda set is meant to occur only in a FunL set slot, which
            -- the arm above drops without visiting.
            crash "LambdaSet1 outside an arrow slot in variableToCanType"

        EmptyRecord1 ->
            IO.pure (Can.TRecord Dict.empty Nothing)

        Record1 fields extension ->
            (Dict.toList fields
                |> IO.traverseList (\( fieldName, fieldVar ) -> fieldToCanType fieldVar |> IO.map (Tuple.pair fieldName))
                |> IO.map Dict.fromList
            )
                |> IO.andThen
                    (\canFields ->
                        variableToCanType extension
                            |> IO.map Type.iteratedDealias
                            |> IO.map
                                (\canExt ->
                                    case canExt of
                                        Can.TRecord subFields subExt ->
                                            Can.TRecord (Dict.union subFields canFields) subExt

                                        Can.TVar name ->
                                            Can.TRecord canFields (Just name)

                                        _ ->
                                            crash "Used toAnnotation on a type that is not well-formed"
                                )
                    )

        Unit1 ->
            IO.pure Can.TUnit

        Tuple1 a b cs ->
            IO.pure Can.TTuple
                |> IO.apply (variableToCanType a)
                |> IO.apply (variableToCanType b)
                |> IO.apply (IO.traverseList variableToCanType cs)


{-| Converts the type of a record field, giving the field index 0.
-}
fieldToCanType : Variable -> IO (Can.FieldType Name)
fieldToCanType variable =
    variableToCanType variable
        |> IO.map (\tipe -> Can.FieldType 0 tipe)



-- ====== TO ERROR TYPE ======


{-| Converts the solved type of `variable` to the type an error message shows.

A class reached again from inside itself becomes `ET.Infinite`, and a class
whose content is a unification error becomes `ET.Error`. Unnamed variables are
named, and the store is changed, as "Converting solved variables" describes.
Crashes on a lambda set outside a function type's set slot, and on such an
infinite or error class in a record's extension position.

-}
toErrorType : Variable -> IO ET.Type
toErrorType variable =
    getVarNames variable Dict.empty
        |> IO.andThen
            (\userNames ->
                IO.withFreshNames (makeNameState userNames) (variableToErrorType variable)
            )


{-| Converts `variable` to an error type, giving `ET.Infinite` if its class is
already being converted further up.

The class carries `occursMark` while its contents are converted, and its own
mark is put back afterwards.

-}
variableToErrorType : Variable -> IO ET.Type
variableToErrorType variable =
    UF.get variable
        |> IO.andThen
            (\descProps ->
                if descProps.mark == occursMark then
                    IO.pure ET.Infinite

                else
                    UF.modify variable (\props -> IO.makeDescriptor props.content props.rank occursMark props.copy)
                        |> IO.andThen
                            (\_ ->
                                contentToErrorType variable descProps.content
                                    |> IO.andThen
                                        (\errType ->
                                            UF.modify variable (\props -> IO.makeDescriptor props.content props.rank descProps.mark props.copy)
                                                |> IO.map (\_ -> errType)
                                        )
                            )
            )


{-| Converts `content`, the content of `variable`'s class, to an error type,
writing a generated name into the descriptor of an unnamed flex variable.
-}
contentToErrorType : Variable -> Content -> IO ET.Type
contentToErrorType variable content =
    case content of
        Structure term ->
            termToErrorType term

        FlexVar maybeName ->
            case maybeName of
                Just name ->
                    IO.pure (ET.FlexVar name)

                Nothing ->
                    getFreshVarName
                        |> IO.andThen
                            (\name ->
                                UF.modify variable
                                    (\props ->
                                        IO.makeDescriptor (FlexVar (Just name)) props.rank props.mark props.copy
                                    )
                                    |> IO.map (\_ -> ET.FlexVar name)
                            )

        FlexSuper super maybeName ->
            case maybeName of
                Just name ->
                    IO.pure (ET.FlexSuper (superToSuper super) name)

                Nothing ->
                    getFreshSuperName super
                        |> IO.andThen
                            (\name ->
                                UF.modify variable
                                    (\props ->
                                        IO.makeDescriptor (FlexSuper super (Just name)) props.rank props.mark props.copy
                                    )
                                    |> IO.map (\_ -> ET.FlexSuper (superToSuper super) name)
                            )

        RigidVar name ->
            IO.pure (ET.RigidVar name)

        RigidSuper super name ->
            IO.pure (ET.RigidSuper (superToSuper super) name)

        Alias home name args realVariable ->
            IO.traverseList (IO.traverseTuple variableToErrorType) args
                |> IO.andThen
                    (\errArgs ->
                        variableToErrorType realVariable
                            |> IO.map
                                (\errType ->
                                    ET.Alias home name errArgs errType
                                )
                    )

        Error ->
            IO.pure ET.Error


{-| Returns the error type's form of a super-type.
-}
superToSuper : SuperType -> ET.Super
superToSuper super =
    case super of
        Number ->
            ET.Number

        Comparable ->
            ET.Comparable

        Appendable ->
            ET.Appendable

        CompAppend ->
            ET.CompAppend


{-| Converts one structure to an error type.

A function whose result is a function becomes one `ET.Lambda` with all the
arguments. A function type with a lambda set is shown as a plain arrow.
A record's fields are merged with those of the record it extends, as in
`termToCanType`. Crashes on a lambda set outside a function type's set slot,
and on a record extension that is neither a record nor an unconstrained flex or
rigid variable.

-}
termToErrorType : FlatType -> IO ET.Type
termToErrorType term =
    case term of
        App1 home name args ->
            IO.traverseList variableToErrorType args
                |> IO.map (ET.Type home name)

        Fun1 a b ->
            variableToErrorType a
                |> IO.andThen
                    (\arg ->
                        variableToErrorType b
                            |> IO.map
                                (\result ->
                                    case result of
                                        ET.Lambda arg1 arg2 others ->
                                            ET.Lambda arg arg1 (arg2 :: others)

                                        _ ->
                                            ET.Lambda arg result []
                                )
                    )

        FunL a b _ ->
            variableToErrorType a
                |> IO.andThen
                    (\arg ->
                        variableToErrorType b
                            |> IO.map
                                (\result ->
                                    case result of
                                        ET.Lambda arg1 arg2 others ->
                                            ET.Lambda arg arg1 (arg2 :: others)

                                        _ ->
                                            ET.Lambda arg result []
                                )
                    )

        LambdaSet1 _ ->
            crash "LambdaSet1 outside an arrow slot in variableToErrorType"

        EmptyRecord1 ->
            IO.pure (ET.Record Dict.empty ET.Closed)

        Record1 fields extension ->
            (Dict.toList fields
                |> IO.traverseList (\( fieldName, fieldVar ) -> variableToErrorType fieldVar |> IO.map (Tuple.pair fieldName))
                |> IO.map Dict.fromList
            )
                |> IO.andThen
                    (\errFields ->
                        variableToErrorType extension
                            |> IO.map ET.iteratedDealias
                            |> IO.map
                                (\errExt ->
                                    case errExt of
                                        ET.Record subFields subExt ->
                                            ET.Record (Dict.union subFields errFields) subExt

                                        ET.FlexVar ext ->
                                            ET.Record errFields (ET.FlexOpen ext)

                                        ET.RigidVar ext ->
                                            ET.Record errFields (ET.RigidOpen ext)

                                        _ ->
                                            crash "Used toErrorType on a type that is not well-formed"
                                )
                    )

        Unit1 ->
            IO.pure ET.Unit

        Tuple1 a b cs ->
            IO.pure ET.Tuple
                |> IO.apply (variableToErrorType a)
                |> IO.apply (variableToErrorType b)
                |> IO.apply (IO.traverseList variableToErrorType cs)



-- ====== MANAGE FRESH VARIABLE NAMES ======


{-| Returns the name state a naming scope starts with: the names of
`takenNames` taken, every counter at zero and nothing remembered.
-}
makeNameState : Dict Name Variable -> NameState
makeNameState takenNames =
    { taken = Dict.map (\_ _ -> ()) takenNames, normals = 0, numbers = 0, comparables = 0, appendables = 0, compAppends = 0, canMemo = Dict.empty }



-- ====== FRESH VAR NAMES ======


{-| Returns a generated name for a plain variable that no one in the naming
scope has taken, and marks it taken.
-}
getFreshVarName : IO Name
getFreshVarName =
    IO.getNames
        |> IO.andThen
            (\ns ->
                let
                    ( name, newIndex, newTaken ) =
                        getFreshVarNameHelp ns.normals ns.taken
                in
                IO.putNames { ns | taken = newTaken, normals = newIndex }
                    |> IO.map (\_ -> name)
            )


{-| Returns the first name from `Compiler.Data.Name.fromTypeVariableScheme index`
onwards that is not in `taken`, the index after it, and `taken` with it added.
-}
getFreshVarNameHelp : Int -> Dict Name () -> ( Name, Int, Dict Name () )
getFreshVarNameHelp index taken =
    let
        name : Name
        name =
            Name.fromTypeVariableScheme index
    in
    if Dict.member name taken then
        getFreshVarNameHelp (index + 1) taken

    else
        ( name, index + 1, Dict.insert name () taken )



-- ====== FRESH SUPER NAMES ======


{-| Returns a generated name for a variable constrained by `super`, such as
`number` or `comparable1`, that no one in the naming scope has taken, and marks
it taken.
-}
getFreshSuperName : SuperType -> IO Name
getFreshSuperName super =
    case super of
        Number ->
            getFreshSuper "number"
                (\ns -> ns.numbers)
                (\index ns ->
                    { ns | numbers = index }
                )

        Comparable ->
            getFreshSuper "comparable"
                (\ns -> ns.comparables)
                (\index ns ->
                    { ns | comparables = index }
                )

        Appendable ->
            getFreshSuper "appendable"
                (\ns -> ns.appendables)
                (\index ns ->
                    { ns | appendables = index }
                )

        CompAppend ->
            getFreshSuper "compappend"
                (\ns -> ns.compAppends)
                (\index ns ->
                    { ns | compAppends = index }
                )


{-| Returns a generated name starting with `prefix`, using the counter that
`getter` reads and `setter` writes, and marks it taken.
-}
getFreshSuper : Name -> (NameState -> Int) -> (Int -> NameState -> NameState) -> IO Name
getFreshSuper prefix getter setter =
    IO.getNames
        |> IO.andThen
            (\nameState ->
                let
                    index =
                        getter nameState

                    taken =
                        nameState.taken

                    ( name, newIndex, newTaken ) =
                        getFreshSuperHelp prefix index taken
                in
                IO.putNames (setter newIndex { nameState | taken = newTaken })
                    |> IO.map (\_ -> name)
            )


{-| Returns the first name from `Compiler.Data.Name.fromTypeVariable prefix index`
onwards that is not in `taken`, the index after it, and `taken` with it added.
-}
getFreshSuperHelp : Name -> Int -> Dict Name () -> ( Name, Int, Dict Name () )
getFreshSuperHelp prefix index taken =
    let
        name : Name
        name =
            Name.fromTypeVariable prefix index
    in
    if Dict.member name taken then
        getFreshSuperHelp prefix (index + 1) taken

    else
        ( name, index + 1, Dict.insert name () taken )



-- ====== GET ALL VARIABLE NAMES ======


{-| Returns `takenNames` with the names of the variables reachable from `var`
added, each mapped to the variable that holds it.

Every class visited is stamped with `getVarNamesMark`, which stays, and a class
already carrying that mark is skipped. A name another, distinct variable holds
is changed by `addName`. The lambda sets of function types are not visited.

-}
getVarNames : Variable -> Dict Name Variable -> IO (Dict Name Variable)
getVarNames var takenNames =
    UF.get var
        |> IO.andThen
            (\descProps ->
                if descProps.mark == getVarNamesMark then
                    IO.pure takenNames

                else
                    UF.set var (IO.makeDescriptor descProps.content descProps.rank getVarNamesMark descProps.copy)
                        |> IO.andThen
                            (\_ ->
                                case descProps.content of
                                    Error ->
                                        IO.pure takenNames

                                    FlexVar maybeName ->
                                        case maybeName of
                                            Nothing ->
                                                IO.pure takenNames

                                            Just name ->
                                                addName 0 name var (Just >> FlexVar) takenNames

                                    FlexSuper super maybeName ->
                                        case maybeName of
                                            Nothing ->
                                                IO.pure takenNames

                                            Just name ->
                                                addName 0 name var (Just >> FlexSuper super) takenNames

                                    RigidVar name ->
                                        addName 0 name var RigidVar takenNames

                                    RigidSuper super name ->
                                        addName 0 name var (RigidSuper super) takenNames

                                    Alias _ _ args _ ->
                                        IO.foldrM getVarNames takenNames (List.map Tuple.second args)

                                    Structure flatType ->
                                        case flatType of
                                            App1 _ _ args ->
                                                IO.foldrM getVarNames takenNames args

                                            Fun1 arg body ->
                                                getVarNames body takenNames |> IO.andThen (getVarNames arg)

                                            FunL arg body _ ->
                                                getVarNames body takenNames |> IO.andThen (getVarNames arg)

                                            LambdaSet1 _ ->
                                                IO.pure takenNames

                                            EmptyRecord1 ->
                                                IO.pure takenNames

                                            Record1 fields extension ->
                                                Dict.values fields |> IO.foldrM getVarNames takenNames |> IO.andThen (getVarNames extension)

                                            Unit1 ->
                                                IO.pure takenNames

                                            Tuple1 a b cs ->
                                                IO.foldrM getVarNames takenNames (a :: b :: cs)
                            )
            )



-- ====== REGISTER NAME ======


{-| Records `var` in `takenNames` under `givenName` with the numeric suffix
`index`, or under the first larger suffix whose name is free or already held
by `var`'s own class.

When the name recorded is not `givenName`, `var`'s content is replaced by
`makeContent` of the new name, which is how a clashing user name is renamed.

-}
addName : Int -> Name -> Variable -> (Name -> Content) -> Dict Name Variable -> IO (Dict Name Variable)
addName index givenName var makeContent takenNames =
    let
        indexedName : Name
        indexedName =
            Name.fromTypeVariable givenName index
    in
    case Dict.get indexedName takenNames of
        Nothing ->
            (if indexedName == givenName then
                IO.pure ()

             else
                UF.modify var
                    (\props ->
                        IO.makeDescriptor (makeContent indexedName) props.rank props.mark props.copy
                    )
            )
                |> IO.map (\_ -> Dict.insert indexedName var takenNames)

        Just otherVar ->
            UF.equivalent var otherVar
                |> IO.andThen
                    (\same ->
                        if same then
                            IO.pure takenNames

                        else
                            addName (index + 1) givenName var makeContent takenNames
                    )
