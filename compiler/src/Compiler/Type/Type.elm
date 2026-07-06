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

{-| Internal type representation for type inference.

This module defines the runtime type representation used during type checking.
Unlike `Can.Type Name` which represents user-written types, these types use union-find
variables for efficient unification.


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

Used by the solver to track generalization levels:

@docs noRank, outermostRank, noMark, nextMark


# Conversion

@docs toAnnotation, toErrorType, toCanTypeBatch

-}

import Array exposing (Array)
import Compiler.AST.Canonical as Can
import Compiler.AST.Utils.Type as Type
import Compiler.Data.Name as Name exposing (Name)
import Compiler.Elm.ModuleName as ModuleName
import Compiler.Reporting.Annotation as A
import Compiler.Reporting.Error.Type as E
import Compiler.Type.Error as ET
import Compiler.Type.UnionFind as UF
import Dict exposing (Dict)
import Maybe.Extra as Maybe
import System.TypeCheck.IO as IO exposing (Content(..), Descriptor, FlatType(..), IO, Mark(..), NameState, SuperType(..), Variable)
import Utils.Crash exposing (crash)



-- ====== CONSTRAINTS ======


{-| Constraint tree representing type relationships for the solver.

Constraints form a tree structure that encodes all type requirements discovered
during constraint generation. The solver walks this tree to unify types and
detect type errors.

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


{-| Wraps a constraint with existentially quantified flex variables.

Creates a CLet constraint that introduces new flex variables that are local to
the given constraint, with no header bindings.

-}
exists : List Variable -> Constraint -> Constraint
exists flexVars constraint =
    CLet [] flexVars Dict.empty constraint CTrue



-- ====== TYPE PRIMITIVES ======


{-| Runtime type representation with unification variables.

Types during inference use Variables (union-find pointers) rather than the
named type variables seen in source code. This enables efficient unification
through union-find operations.

-}
type Type
    = AliasN IO.Canonical Name (List ( Name, Type )) Type
    | VarN Variable
    | AppN IO.Canonical Name (List Type)
    | FunN Type Type
    | EmptyRecordN
    | RecordN (Dict Name Type) Type
    | UnitN
    | TupleN Type Type (List Type)



-- ====== DESCRIPTORS ======


makeDescriptor : Content -> Descriptor
makeDescriptor content =
    IO.makeDescriptor content noRank noMark Nothing



-- ====== RANKS ======


{-| Rank value for unranked variables or error states.

Used to mark variables that haven't been assigned a rank yet or that are in an
error state.

-}
noRank : Int
noRank =
    0


{-| Rank value for top-level type variables.

Variables at the outermost scope have rank 1, allowing the solver to detect
when generalization is safe.

-}
outermostRank : Int
outermostRank =
    1



-- ====== MARKS ======


{-| Default mark value for unmarked variables.

Marks are used during graph traversal to avoid revisiting nodes. This is the
initial mark value for fresh variables.

-}
noMark : Mark
noMark =
    Mark 2


occursMark : Mark
occursMark =
    Mark 1


getVarNamesMark : Mark
getVarNamesMark =
    Mark 0


{-| Generates the next mark value for a new traversal.

Each graph traversal should use a fresh mark value to distinguish visited nodes
from unvisited ones.

-}
nextMark : Mark -> Mark
nextMark (Mark mark) =
    Mark (mark + 1)



-- ====== FUNCTION TYPES ======


{-| Constructs a function type from argument to result.

Represents the type `arg -> result` in Elm syntax.

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


{-| The Never type, representing values that cannot exist.
-}
never : Type
never =
    AppN ModuleName.basics "Never" []



-- ====== WEBGL TYPES ======


{-| The Vec2 WebGL type for 2D vectors.
-}
vec2 : Type
vec2 =
    AppN ModuleName.vector2 "Vec2" []


{-| The Vec3 WebGL type for 3D vectors.
-}
vec3 : Type
vec3 =
    AppN ModuleName.vector3 "Vec3" []


{-| The Vec4 WebGL type for 4D vectors.
-}
vec4 : Type
vec4 =
    AppN ModuleName.vector4 "Vec4" []


{-| The Mat4 WebGL type for 4x4 matrices.
-}
mat4 : Type
mat4 =
    AppN ModuleName.matrix4 "Mat4" []


{-| The Texture WebGL type.
-}
texture : Type
texture =
    AppN ModuleName.texture "Texture" []



-- ====== MAKE FLEX VARIABLES ======


{-| Creates a fresh unnamed flexible type variable.

Returns a new variable that can unify with any type. Used during type inference
when the type is initially unknown.

-}
mkFlexVar : IO Variable
mkFlexVar =
    UF.fresh flexVarDescriptor


flexVarDescriptor : Descriptor
flexVarDescriptor =
    makeDescriptor unnamedFlexVar


{-| Content representing an unnamed flexible variable.

Flexible variables can unify with any type and will be given generated names if
needed for error reporting.

-}
unnamedFlexVar : Content
unnamedFlexVar =
    FlexVar Nothing



-- ====== MAKE FLEX NUMBERS ======


{-| Creates a fresh unnamed flexible number variable.

Returns a new variable constrained to the Number supertype (Int or Float).
Used for numeric literals that could be either type.

-}
mkFlexNumber : IO Variable
mkFlexNumber =
    UF.fresh flexNumberDescriptor


flexNumberDescriptor : Descriptor
flexNumberDescriptor =
    makeDescriptor (unnamedFlexSuper Number)


{-| Content representing an unnamed flexible supertype variable.

Supertype variables are constrained to unify only with types matching the given
supertype (Number, Comparable, Appendable, or CompAppend).

-}
unnamedFlexSuper : SuperType -> Content
unnamedFlexSuper super =
    FlexSuper super Nothing



-- ====== MAKE NAMED VARIABLES ======


{-| Creates a named flexible variable from a type variable name.

If the name corresponds to a supertype (number, comparable, appendable,
compappend), creates a flexible supertype variable. Otherwise creates a regular
flexible variable.

-}
nameToFlex : Name -> IO Variable
nameToFlex name =
    Maybe.unwrap FlexVar FlexSuper (toSuper name) (Just name) |> makeDescriptor |> UF.fresh


{-| Creates a named rigid variable from a type variable name.

Rigid variables represent bound type variables from user annotations or let
polymorphism. They cannot unify with other rigid variables. If the name
corresponds to a supertype, creates a rigid supertype variable.

-}
nameToRigid : Name -> IO Variable
nameToRigid name =
    Maybe.unwrap RigidVar RigidSuper (toSuper name) name |> makeDescriptor |> UF.fresh


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


{-| Converts a type variable to a canonical type annotation.

Traverses the type structure to produce a user-readable type with properly
named type variables. Generates fresh names for unnamed variables and returns
a Forall quantifier listing all type variables found.

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


{-| Convert an array of solver Variables to Can.Types using a shared NameState.

This ensures that type variables across different expressions get globally
unique names, preventing collisions where e.g. two lambda parameters
independently both get named "a".

-}
toCanTypeBatch : Array (Maybe Variable) -> IO (Array (Maybe (Can.Type Name)))
toCanTypeBatch nodeVars =
    -- First pass: collect all user-provided names across all variables
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
                -- Second pass: convert all variables sharing one name state, so
                -- names stay globally unique across the batch.
                IO.withFreshNames (makeNameState allUserNames)
                    (IO.traverseArrayMaybe variableToCanType nodeVars)
            )


variableToCanType : Variable -> IO (Can.Type Name)
variableToCanType variable =
    UF.get variable
        |> IO.andThen
            (\descProps ->
                case descProps.content of
                    Structure term ->
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

                    Error ->
                        crash "cannot handle Error types in variableToCanType"
            )


termToCanType : FlatType -> IO (Can.Type Name)
termToCanType term =
    case term of
        App1 home name args ->
            IO.traverseList variableToCanType args
                |> IO.map (Can.TType home name)

        Fun1 a b ->
            IO.pure Can.TLambda
                |> IO.apply (variableToCanType a)
                |> IO.apply (variableToCanType b)

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


fieldToCanType : Variable -> IO (Can.FieldType Name)
fieldToCanType variable =
    variableToCanType variable
        |> IO.map (\tipe -> Can.FieldType 0 tipe)



-- ====== TO ERROR TYPE ======


{-| Converts a type variable to an error type for reporting.

Similar to toAnnotation but produces types in the error reporting format.
Includes special handling for infinite types (occurs check failures) by
detecting cycles during traversal.

-}
toErrorType : Variable -> IO ET.Type
toErrorType variable =
    getVarNames variable Dict.empty
        |> IO.andThen
            (\userNames ->
                IO.withFreshNames (makeNameState userNames) (variableToErrorType variable)
            )


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
--
-- `NameState` now lives in `System.TypeCheck.IO` (folded into the IO state), so
-- the conversion functions above run in plain `IO` rather than `StateT`.


makeNameState : Dict Name Variable -> NameState
makeNameState takenNames =
    { taken = Dict.map (\_ _ -> ()) takenNames, normals = 0, numbers = 0, comparables = 0, appendables = 0, compAppends = 0 }



-- ====== FRESH VAR NAMES ======


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
