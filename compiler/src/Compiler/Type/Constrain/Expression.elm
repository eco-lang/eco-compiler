module Compiler.Type.Constrain.Expression exposing
    ( RigidTypeVar
    , constrainDef, constrainRecursiveDefs
    , ExprIdState, emptyExprIdState
    , constrainDefWithIds, constrainRecursiveDefsWithIds
    )

{-| Type constraint generation for expressions.

This module walks through canonical expression AST nodes and generates type constraints
that will be solved during type inference. It handles all expression forms including
literals, variables, function calls, pattern matching, records, and more.

The constraint generation process creates relationships between types (e.g., "this
function argument must have the same type as this parameter") without immediately
solving them. The actual unification happens in a separate solving phase.


# Types

@docs RigidTypeVar


# Constraint Generation

@docs constrainDef, constrainRecursiveDefs


# Constraint Generation with Expression ID Tracking

For TypedCanonical AST construction, we also track expression ID → Variable mappings.

@docs ExprIdState, emptyExprIdState
@docs constrainDefWithIds, constrainRecursiveDefsWithIds

-}

import Compiler.AST.Canonical as Can
import Compiler.AST.Utils.Shader as Shader
import Compiler.Data.Index as Index
import Compiler.Data.Name as Name exposing (Name)
import Compiler.Elm.ModuleName as ModuleName
import Compiler.Reporting.Annotation as A
import Compiler.Reporting.Error.Type as E exposing (Category(..), Context(..), Expected(..), MaybeName(..), PContext(..), PExpected(..), SubContext(..))
import Compiler.Type.Constrain.NodeIds as NodeIds
import Compiler.Type.Constrain.Pattern as Pattern
import Compiler.Type.Constrain.Program as Prog exposing (Prog, ProgS)
import Compiler.Type.Instantiate as Instantiate
import Compiler.Type.Type as Type exposing (Constraint(..), Type(..))
import Data.Map as Dict exposing (Dict)
import System.TypeCheck.IO as IO exposing (IO)
import Utils.Main as Utils



-- CONSTRAIN


{-| As we step past type annotations, the free type variables are added to
the "rigid type variables" dict. Allowing sharing of rigid variables
between nested type annotations.

So if you have a top-level type annotation like (func : a -> b) the RTV
dictionary will hold variables for `a` and `b`

-}
type alias RigidTypeVar =
    Dict String Name.Name Type



-- CONSTRAIN LAMBDA
-- CONSTRAIN CALL


{-| Extract the name from an expression for better error messages. Returns
FuncName, CtorName, OpName, or NoName depending on the expression form.
-}
getName : Can.Expr -> MaybeName
getName (A.At _ exprInfo) =
    case exprInfo.node of
        Can.VarLocal name ->
            FuncName name

        Can.VarTopLevel _ name ->
            FuncName name

        Can.VarForeign _ name _ ->
            FuncName name

        Can.VarCtor _ _ name _ _ ->
            CtorName name

        Can.VarOperator op _ _ _ ->
            OpName op

        Can.VarKernel _ name ->
            FuncName name

        _ ->
            NoName


{-| Extract the variable name from an expression being accessed (e.g., in record
access). Returns Nothing if the expression is not a simple variable reference.
-}
getAccessName : Can.Expr -> Maybe Name.Name
getAccessName (A.At _ exprInfo) =
    case exprInfo.node of
        Can.VarLocal name ->
            Just name

        Can.VarTopLevel _ name ->
            Just name

        Can.VarForeign _ name _ ->
            Just name

        _ ->
            Nothing



-- CONSTRAIN BINOP
-- CONSTRAIN LISTS
-- CONSTRAIN IF EXPRESSIONS
-- CONSTRAIN CASE EXPRESSIONS
-- CONSTRAIN RECORD
-- CONSTRAIN RECORD UPDATE
-- CONSTRAIN TUPLE
-- CONSTRAIN SHADER


{-| Convert a dictionary of shader types to a record type. If the dictionary
is empty, returns the base record type; otherwise constructs a record with
the shader types mapped to Elm types.
-}
toShaderRecord : Dict String Name.Name Shader.Type -> Type -> Type
toShaderRecord types baseRecType =
    if Dict.isEmpty types then
        baseRecType

    else
        RecordN (Dict.map (\_ -> glToType) types) baseRecType


{-| Convert a GLSL/WebGL type to the corresponding Elm type (e.g., V2 becomes
vec2, Float becomes float).
-}
glToType : Shader.Type -> Type
glToType glType =
    case glType of
        Shader.V2 ->
            Type.vec2

        Shader.V3 ->
            Type.vec3

        Shader.V4 ->
            Type.vec4

        Shader.M4 ->
            Type.mat4

        Shader.Int ->
            Type.int

        Shader.Float ->
            Type.float

        Shader.Texture ->
            Type.texture

        Shader.Bool ->
            Type.bool



-- CONSTRAIN DESTRUCTURES
-- CONSTRAIN DEF


{-| Generate constraints for a single definition in a let-expression. Handles
both unannotated definitions (where types are inferred) and typed definitions
(where explicit type annotations guide constraint generation).

Uses the stack-safe DSL internally.

-}
constrainDef : RigidTypeVar -> Can.Def -> Constraint -> IO Constraint
constrainDef rtv def bodyCon =
    constrainDefProg rtv def bodyCon |> Prog.run



-- CONSTRAIN RECURSIVE DEFS


{-| Internal type for accumulating information about recursive definitions.
Tracks type variables, constraints, and type headers for both rigid (typed)
and flexible (untyped) definitions.
-}
type Info
    = Info (List IO.Variable) (List Constraint) (Dict String Name (A.Located Type))


{-| Empty Info structure with no variables, constraints, or headers.
-}
emptyInfo : Info
emptyInfo =
    Info [] [] Dict.empty


{-| Generate constraints for a group of mutually recursive definitions in a
let-rec expression. Handles both typed and untyped definitions, ensuring that
recursive references are properly constrained.

Uses the stack-safe DSL internally.

-}
constrainRecursiveDefs : RigidTypeVar -> List Can.Def -> Constraint -> IO Constraint
constrainRecursiveDefs rtv defs bodyCon =
    constrainRecursiveDefsProg rtv defs bodyCon |> Prog.run



-- CONSTRAIN ARGS


{-| Wrapper for argument constraint information, containing type variables,
the overall function type, result type, and pattern state from argument patterns.
-}
type Args
    = Args ArgsProps


{-| Properties for constrained function arguments including:

  - vars: Type variables introduced for arguments and result
  - tipe: The full function type (arg1 -> arg2 -> ... -> result)
  - result: The result type of the function
  - state: Pattern matching state from argument patterns

-}
type alias ArgsProps =
    { vars : List IO.Variable
    , tipe : Type
    , result : Type
    , state : Pattern.State
    }


{-| Construct an Args value from its components: type variables, function type,
result type, and pattern state.
-}
makeArgs : List IO.Variable -> Type -> Type -> Pattern.State -> Args
makeArgs vars tipe result state =
    Args { vars = vars, tipe = tipe, result = result, state = state }


{-| Generate constraints for a list of function argument patterns,
also tracking pattern IDs in the NodeIdState.
-}
constrainArgsWithIds : List Can.Pattern -> NodeIds.NodeIdState -> IO ( Args, NodeIds.NodeIdState )
constrainArgsWithIds args nodeState =
    argsHelpWithIds args Pattern.emptyState nodeState


{-| Helper for constraining function arguments with ID tracking.
Recursively processes patterns, threading through both the pattern state
and the NodeIdState, building up the function type.
-}
argsHelpWithIds : List Can.Pattern -> Pattern.State -> NodeIds.NodeIdState -> IO ( Args, NodeIds.NodeIdState )
argsHelpWithIds args state nodeState =
    case args of
        [] ->
            Type.mkFlexVar
                |> IO.map
                    (\resultVar ->
                        let
                            resultType : Type
                            resultType =
                                VarN resultVar
                        in
                        ( makeArgs [ resultVar ] resultType resultType state, nodeState )
                    )

        pattern :: otherArgs ->
            Type.mkFlexVar
                |> IO.andThen
                    (\argVar ->
                        let
                            argType : Type
                            argType =
                                VarN argVar
                        in
                        Pattern.addWithIds pattern (PNoExpectation argType) state nodeState
                            |> IO.andThen
                                (\( newState, newNodeState ) ->
                                    argsHelpWithIds otherArgs newState newNodeState
                                )
                            |> IO.map
                                (\( Args props, finalNodeState ) ->
                                    ( makeArgs (argVar :: props.vars) (FunN argType props.tipe) props.result props.state
                                    , finalNodeState
                                    )
                                )
                    )



-- CONSTRAIN TYPED ARGS


{-| Information about typed function arguments including the full function type,
the result type, and the pattern state from argument patterns.
-}
type TypedArgs
    = TypedArgs Type Type Pattern.State


{-| Generate constraints for explicitly typed function arguments,
also tracking pattern IDs in the NodeIdState.
-}
constrainTypedArgsWithIds :
    Dict String Name.Name Type
    -> Name.Name
    -> List ( Can.Pattern, Can.Type )
    -> Can.Type
    -> NodeIds.NodeIdState
    -> IO ( TypedArgs, NodeIds.NodeIdState )
constrainTypedArgsWithIds rtv name args srcResultType nodeState =
    typedArgsHelpWithIds rtv name Index.first args srcResultType Pattern.emptyState nodeState


{-| Helper for constraining typed arguments with ID tracking.
Recursively processes pattern-type pairs with NodeIdState threading.
-}
typedArgsHelpWithIds :
    Dict String Name.Name Type
    -> Name.Name
    -> Index.ZeroBased
    -> List ( Can.Pattern, Can.Type )
    -> Can.Type
    -> Pattern.State
    -> NodeIds.NodeIdState
    -> IO ( TypedArgs, NodeIds.NodeIdState )
typedArgsHelpWithIds rtv name index args srcResultType state nodeState =
    case args of
        [] ->
            Instantiate.fromSrcType rtv srcResultType
                |> IO.map
                    (\resultType ->
                        ( TypedArgs resultType resultType state, nodeState )
                    )

        ( (A.At region _) as pattern, srcType ) :: otherArgs ->
            Instantiate.fromSrcType rtv srcType
                |> IO.andThen
                    (\argType ->
                        let
                            expected : PExpected Type
                            expected =
                                PFromContext region (PTypedArg name index) argType
                        in
                        Pattern.addWithIds pattern expected state nodeState
                            |> IO.andThen
                                (\( newState, newNodeState ) ->
                                    typedArgsHelpWithIds rtv name (Index.next index) otherArgs srcResultType newState newNodeState
                                )
                            |> IO.map
                                (\( TypedArgs tipe resultType finalState, finalNodeState ) ->
                                    ( TypedArgs (FunN argType tipe) resultType finalState, finalNodeState )
                                )
                    )



-- ====== Expression ID Tracking for TypedCanonical ======


{-| State for tracking node ID → Variable mappings during constraint generation.

This is an alias for NodeIds.NodeIdState to maintain backwards compatibility
while transitioning to unified node ID tracking.

-}
type alias ExprIdState =
    NodeIds.NodeIdState


{-| Initial empty state for node ID tracking.
-}
emptyExprIdState : ExprIdState
emptyExprIdState =
    NodeIds.emptyNodeIdState


{-| Generate constraints for a definition, also tracking node IDs (expressions and patterns).
-}
constrainDefWithIds : RigidTypeVar -> Can.Def -> Constraint -> ExprIdState -> IO ( Constraint, ExprIdState )
constrainDefWithIds rtv def bodyCon state =
    case def of
        Can.Def (A.At region name) args expr ->
            constrainArgsWithIds args state
                |> IO.andThen
                    (\( Args props, stateAfterArgs ) ->
                        let
                            (Pattern.State headers pvars revCons) =
                                props.state
                        in
                        constrainWithIds rtv expr (NoExpectation props.result) stateAfterArgs
                            |> IO.map
                                (\( exprCon, newState ) ->
                                    ( CLet []
                                        props.vars
                                        (Dict.singleton identity name (A.At region props.tipe))
                                        (CLet []
                                            pvars
                                            headers
                                            (CAnd (List.reverse revCons))
                                            exprCon
                                        )
                                        bodyCon
                                    , newState
                                    )
                                )
                    )

        Can.TypedDef (A.At region name) freeVars typedArgs expr srcResultType ->
            let
                newNames : Dict String Name ()
                newNames =
                    Dict.diff freeVars rtv
            in
            IO.traverseMapWithKey identity compare (\k _ -> Type.nameToRigid k) newNames
                |> IO.andThen
                    (\newRigids ->
                        let
                            newRtv : RigidTypeVar
                            newRtv =
                                Dict.union rtv (Dict.map (\_ -> VarN) newRigids)
                        in
                        constrainTypedArgsWithIds newRtv name typedArgs srcResultType state
                            |> IO.andThen
                                (\( TypedArgs tipe resultType (Pattern.State headers pvars revCons), stateAfterArgs ) ->
                                    constrainWithIds newRtv expr (FromAnnotation name (List.length typedArgs) TypedBody resultType) stateAfterArgs
                                        |> IO.map
                                            (\( exprCon, newState ) ->
                                                ( CLet (Dict.values compare newRigids)
                                                    []
                                                    (Dict.singleton identity name (A.At region tipe))
                                                    (CLet []
                                                        pvars
                                                        headers
                                                        (CAnd (List.reverse revCons))
                                                        exprCon
                                                    )
                                                    bodyCon
                                                , newState
                                                )
                                            )
                                )
                    )


{-| Generate constraints for recursive definitions, also tracking node IDs (expressions and patterns).
-}
constrainRecursiveDefsWithIds : RigidTypeVar -> List Can.Def -> Constraint -> ExprIdState -> IO ( Constraint, ExprIdState )
constrainRecursiveDefsWithIds rtv defs bodyCon state =
    recDefsHelpWithIds rtv defs bodyCon (Info [] [] Dict.empty) (Info [] [] Dict.empty) state


recDefsHelpWithIds : RigidTypeVar -> List Can.Def -> Constraint -> Info -> Info -> ExprIdState -> IO ( Constraint, ExprIdState )
recDefsHelpWithIds rtv defs bodyCon rigidInfo flexInfo state =
    case defs of
        [] ->
            let
                (Info rigidVars rigidCons rigidHeaders) =
                    rigidInfo

                (Info flexVars flexCons flexHeaders) =
                    flexInfo
            in
            IO.pure
                ( CAnd [ CAnd rigidCons, bodyCon ]
                    |> CLet [] flexVars flexHeaders (CLet [] [] flexHeaders CTrue (CAnd flexCons))
                    |> CLet rigidVars [] rigidHeaders CTrue
                , state
                )

        def :: otherDefs ->
            case def of
                Can.Def (A.At region name) args expr ->
                    let
                        (Info flexVars flexCons flexHeaders) =
                            flexInfo
                    in
                    -- Match original: thread accumulated flexVars through pattern state
                    argsHelpWithIds args (Pattern.State Dict.empty flexVars []) state
                        |> IO.andThen
                            (\( Args props, stateAfterArgs ) ->
                                let
                                    (Pattern.State headers pvars revCons) =
                                        props.state
                                in
                                constrainWithIds rtv expr (NoExpectation props.result) stateAfterArgs
                                    |> IO.andThen
                                        (\( exprCon, newState ) ->
                                            let
                                                defCon : Constraint
                                                defCon =
                                                    CLet [] pvars headers (CAnd (List.reverse revCons)) exprCon

                                                -- Match original: just props.vars (flexVars already in pvars)
                                                newFlexInfo : Info
                                                newFlexInfo =
                                                    Info props.vars
                                                        (defCon :: flexCons)
                                                        (Dict.insert identity name (A.At region props.tipe) flexHeaders)
                                            in
                                            recDefsHelpWithIds rtv otherDefs bodyCon rigidInfo newFlexInfo newState
                                        )
                            )

                Can.TypedDef (A.At region name) freeVars typedArgs expr srcResultType ->
                    let
                        (Info rigidVars rigidCons rigidHeaders) =
                            rigidInfo

                        newNames : Dict String Name ()
                        newNames =
                            Dict.diff freeVars rtv
                    in
                    IO.traverseMapWithKey identity compare (\k _ -> Type.nameToRigid k) newNames
                        |> IO.andThen
                            (\newRigids ->
                                let
                                    newRtv : RigidTypeVar
                                    newRtv =
                                        Dict.union rtv (Dict.map (\_ -> VarN) newRigids)
                                in
                                constrainTypedArgsWithIds newRtv name typedArgs srcResultType state
                                    |> IO.andThen
                                        (\( TypedArgs tipe resultType (Pattern.State headers pvars revCons), stateAfterArgs ) ->
                                            constrainWithIds newRtv expr (FromAnnotation name (List.length typedArgs) TypedBody resultType) stateAfterArgs
                                                |> IO.andThen
                                                    (\( exprCon, newState ) ->
                                                        let
                                                            -- Match original: defCon has empty rigid vars
                                                            defCon : Constraint
                                                            defCon =
                                                                CLet []
                                                                    pvars
                                                                    headers
                                                                    (CAnd (List.reverse revCons))
                                                                    exprCon

                                                            -- Match original: wrap defCon in CLet that introduces rigids
                                                            wrappedDefCon : Constraint
                                                            wrappedDefCon =
                                                                CLet (Dict.values compare newRigids) [] Dict.empty defCon CTrue

                                                            newRigidInfo : Info
                                                            newRigidInfo =
                                                                Info (Dict.foldr compare (\_ -> (::)) rigidVars newRigids) (wrappedDefCon :: rigidCons) (Dict.insert identity name (A.At region tipe) rigidHeaders)
                                                        in
                                                        recDefsHelpWithIds rtv otherDefs bodyCon newRigidInfo flexInfo newState
                                                    )
                                        )
                            )


{-| Generate constraints for an expression, tracking expression ID → Variable mapping.

This records the expression's ID and the type variable created for it in the state,
allowing post-solving conversion of variables to types.

-}
constrainWithIds : RigidTypeVar -> Can.Expr -> E.Expected Type -> ExprIdState -> IO ( Constraint, ExprIdState )
constrainWithIds rtv expr expected state =
    Prog.runS state (constrainWithIdsProg rtv expr expected)


{-| DSL version of constrainWithIds for stack safety.

This function dispatches to specialized helpers based on expression type:

  - Group A expressions (those with natural result variables) record their
    existing result var and avoid creating an extra exprVar + CEqual.
  - Group B expressions (without natural result variables) use the generic
    path that allocates a synthetic exprVar.

-}
constrainWithIdsProg : RigidTypeVar -> Can.Expr -> E.Expected Type -> ProgS ExprIdState Constraint
constrainWithIdsProg rtv (A.At region exprInfo) expected =
    case exprInfo.node of
        -- Group A: Use specialized helpers that record the natural result var
        Can.Int _ ->
            constrainIntWithIdsProg region exprInfo.id expected

        Can.Negate expr ->
            constrainNegateWithIdsProg rtv region exprInfo.id expr expected

        Can.Binop op _ _ annotation leftExpr rightExpr ->
            constrainBinopWithIdsProg rtv region exprInfo.id op annotation leftExpr rightExpr expected

        Can.Call func args ->
            constrainCallWithIdsProg rtv region exprInfo.id func args expected

        Can.If branches finally ->
            constrainIfWithIdsProg rtv region exprInfo.id branches finally expected

        Can.Case expr branches ->
            constrainCaseWithIdsProg rtv region exprInfo.id expr branches expected

        Can.Access expr (A.At accessRegion field) ->
            constrainAccessWithIdsProg rtv region exprInfo.id expr accessRegion field expected

        Can.Update expr fields ->
            constrainUpdateWithIdsProg rtv region exprInfo.id expr fields expected

        -- Special case: VarKernel has no constraint but still needs to be tracked
        Can.VarKernel _ _ ->
            Prog.opMkFlexVarS
                |> Prog.andThenS
                    (\exprVar ->
                        Prog.opModifyS (NodeIds.recordNodeVar exprInfo.id exprVar)
                            |> Prog.mapS (\() -> CTrue)
                    )

        -- Group B: Use generic path with extra exprVar
        _ ->
            constrainGenericWithIdsProg rtv region exprInfo expected


{-| Generic path for Group B expressions.

Allocates a synthetic exprVar, records it in NodeIds but does not add any solver constraints on it,
so it will be totally unconstrained at the end of type checking.

-}
constrainGenericWithIdsProg : RigidTypeVar -> A.Region -> Can.ExprInfo -> E.Expected Type -> ProgS ExprIdState Constraint
constrainGenericWithIdsProg rtv region info expected =
    Prog.opMkFlexVarS
        |> Prog.andThenS
            (\exprVar ->
                let
                    exprId =
                        info.id
                in
                Prog.opModifyS (NodeIds.recordNodeVar exprId exprVar)
                    |> Prog.andThenS
                        (\_ ->
                            constrainNodeWithIdsProg rtv region info.node expected
                        )
            )


{-| Compute the appropriate category for an expression node.
This matches the categories used in the original `constrain` function.
-}
nodeToCategory : Can.Expr_ -> Category
nodeToCategory node =
    case node of
        Can.VarLocal name ->
            -- CLocal doesn't use a category, but we need one for the wrapper
            E.Local name

        Can.VarTopLevel _ name ->
            E.Local name

        Can.VarKernel _ name ->
            -- CTrue doesn't use a category
            E.Local name

        Can.VarForeign _ name _ ->
            -- CForeign doesn't directly use a category
            E.Foreign name

        Can.VarCtor _ _ name _ _ ->
            CallResult (CtorName name)

        Can.VarDebug _ name _ ->
            E.Foreign name

        Can.VarOperator op _ _ _ ->
            CallResult (OpName op)

        Can.Str _ ->
            String

        Can.Chr _ ->
            Char

        Can.Int _ ->
            E.Number

        Can.Float _ ->
            Float

        Can.List _ ->
            List

        Can.Negate _ ->
            E.Number

        Can.Binop op _ _ _ _ _ ->
            CallResult (OpName op)

        Can.Lambda _ _ ->
            Lambda

        Can.Call func _ ->
            CallResult (getName func)

        Can.If _ _ ->
            If

        Can.Case _ _ ->
            Case

        Can.Let _ body ->
            -- Let expressions get their category from the body
            nodeToCategory (A.toValue body).node

        Can.LetRec _ body ->
            nodeToCategory (A.toValue body).node

        Can.LetDestruct _ _ body ->
            nodeToCategory (A.toValue body).node

        Can.Accessor field ->
            Accessor field

        Can.Access _ (A.At _ field) ->
            Access field

        Can.Update _ _ ->
            Record

        Can.Record _ ->
            Record

        Can.Unit ->
            Unit

        Can.Tuple _ _ _ ->
            Tuple

        Can.Shader _ _ ->
            Shader



-- ====== Group A Specialized Helpers ======
--
-- These helpers handle expressions that have a natural "result variable".
-- They record that variable directly in NodeIds instead of creating a
-- synthetic exprVar, avoiding an extra CEqual constraint.


{-| Group A helper for Int literals.

Records the flex number var as the expression's type.

-}
constrainIntWithIdsProg : A.Region -> Int -> E.Expected Type -> ProgS ExprIdState Constraint
constrainIntWithIdsProg region exprId expected =
    Prog.opMkFlexNumberS
        |> Prog.andThenS
            (\var ->
                Prog.opModifyS (NodeIds.recordNodeVar exprId var)
                    |> Prog.mapS
                        (\() ->
                            Type.exists [ var ] (CEqual region E.Number (VarN var) expected)
                        )
            )


{-| Group A helper for Negate expressions.

Records the numberVar as the expression's type.

-}
constrainNegateWithIdsProg : RigidTypeVar -> A.Region -> Int -> Can.Expr -> E.Expected Type -> ProgS ExprIdState Constraint
constrainNegateWithIdsProg rtv region exprId expr expected =
    Prog.opMkFlexNumberS
        |> Prog.andThenS
            (\numberVar ->
                let
                    numberType : Type
                    numberType =
                        VarN numberVar
                in
                Prog.opModifyS (NodeIds.recordNodeVar exprId numberVar)
                    |> Prog.andThenS
                        (\() ->
                            constrainWithIdsProg rtv expr (FromContext region Negate numberType)
                                |> Prog.mapS
                                    (\numberCon ->
                                        let
                                            negateCon : Constraint
                                            negateCon =
                                                CEqual region E.Number numberType expected
                                        in
                                        Type.exists [ numberVar ] (CAnd [ numberCon, negateCon ])
                                    )
                        )
            )


{-| Group A helper for Access expressions (record.field).

Records the fieldVar as the expression's type.

-}
constrainAccessWithIdsProg : RigidTypeVar -> A.Region -> Int -> Can.Expr -> A.Region -> Name.Name -> E.Expected Type -> ProgS ExprIdState Constraint
constrainAccessWithIdsProg rtv region exprId expr accessRegion field expected =
    Prog.opMkFlexVarS
        |> Prog.andThenS
            (\extVar ->
                Prog.opMkFlexVarS
                    |> Prog.andThenS
                        (\fieldVar ->
                            Prog.opModifyS (NodeIds.recordNodeVar exprId fieldVar)
                                |> Prog.andThenS
                                    (\() ->
                                        let
                                            extType : Type
                                            extType =
                                                VarN extVar

                                            fieldType : Type
                                            fieldType =
                                                VarN fieldVar

                                            recordType : Type
                                            recordType =
                                                RecordN (Dict.singleton identity field fieldType) extType

                                            context : Context
                                            context =
                                                RecordAccess (A.toRegion expr) (getAccessName expr) accessRegion field
                                        in
                                        constrainWithIdsProg rtv expr (FromContext region context recordType)
                                            |> Prog.mapS
                                                (\recordCon ->
                                                    Type.exists [ fieldVar, extVar ]
                                                        (CAnd [ recordCon, CEqual region (Access field) fieldType expected ])
                                                )
                                    )
                        )
            )


{-| DSL version of constrainNodeWithIds for stack safety.
-}
constrainNodeWithIdsProg : RigidTypeVar -> A.Region -> Can.Expr_ -> E.Expected Type -> ProgS ExprIdState Constraint
constrainNodeWithIdsProg rtv region node expected =
    case node of
        Can.VarLocal name ->
            Prog.pureS (CLocal region name expected)

        Can.VarTopLevel _ name ->
            Prog.pureS (CLocal region name expected)

        Can.VarKernel _ _ ->
            Prog.pureS CTrue

        Can.VarForeign _ name annotation ->
            Prog.pureS (CForeign region name annotation expected)

        Can.VarCtor _ _ name _ annotation ->
            Prog.pureS (CForeign region name annotation expected)

        Can.VarDebug _ name annotation ->
            Prog.pureS (CForeign region name annotation expected)

        Can.VarOperator op _ _ annotation ->
            Prog.pureS (CForeign region op annotation expected)

        Can.Str _ ->
            Prog.pureS (CEqual region String Type.string expected)

        Can.Chr _ ->
            Prog.pureS (CEqual region Char Type.char expected)

        -- Group A expressions are handled directly by constrainWithIdsProg.
        -- These cases are unreachable but required for exhaustive matching.
        Can.Int _ ->
            Prog.pureS CTrue

        Can.Float _ ->
            Prog.pureS (CEqual region Float Type.float expected)

        Can.List elements ->
            constrainListWithIdsProg rtv region elements expected

        Can.Negate _ ->
            Prog.pureS CTrue

        Can.Binop _ _ _ _ _ _ ->
            Prog.pureS CTrue

        Can.Lambda args body ->
            constrainLambdaWithIdsProg rtv region args body expected

        Can.Call _ _ ->
            Prog.pureS CTrue

        Can.If _ _ ->
            Prog.pureS CTrue

        Can.Case _ _ ->
            Prog.pureS CTrue

        Can.Let def body ->
            constrainWithIdsProg rtv body expected
                |> Prog.andThenS (constrainDefWithIdsProg rtv def)

        Can.LetRec defs body ->
            constrainWithIdsProg rtv body expected
                |> Prog.andThenS (constrainRecursiveDefsWithIdsProg rtv defs)

        Can.LetDestruct pattern expr body ->
            constrainWithIdsProg rtv body expected
                |> Prog.andThenS (constrainDestructWithIdsProg rtv region pattern expr)

        Can.Accessor field ->
            Prog.opMkFlexVarS
                |> Prog.andThenS
                    (\extVar ->
                        Prog.opMkFlexVarS
                            |> Prog.mapS
                                (\fieldVar ->
                                    let
                                        extType : Type
                                        extType =
                                            VarN extVar

                                        fieldType : Type
                                        fieldType =
                                            VarN fieldVar

                                        recordType : Type
                                        recordType =
                                            RecordN (Dict.singleton identity field fieldType) extType
                                    in
                                    Type.exists [ fieldVar, extVar ] (CEqual region (Accessor field) (FunN recordType fieldType) expected)
                                )
                    )

        Can.Access _ _ ->
            -- Group A: handled by constrainAccessWithIdsProg
            Prog.pureS CTrue

        Can.Update _ _ ->
            -- Group A: handled by constrainUpdateWithIdsProg
            Prog.pureS CTrue

        Can.Record fields ->
            constrainRecordWithIdsProg rtv region fields expected

        Can.Unit ->
            Prog.pureS (CEqual region Unit UnitN expected)

        Can.Tuple a b cs ->
            constrainTupleWithIdsProg rtv region a b cs expected

        Can.Shader _ types ->
            constrainShaderWithIdsProg region types expected



-- ====== Stack-Safe DSL-Based Constraint Generation (WithIds) ======
--
-- These functions use the ProgS DSL to avoid stack overflow on deeply nested
-- expressions while tracking expression ID → Variable mappings.


{-| DSL version of constrainShaderWithIds.
-}
constrainShaderWithIdsProg : A.Region -> Shader.Types -> Expected Type -> ProgS ExprIdState Constraint
constrainShaderWithIdsProg region (Shader.Types attributes uniforms varyings) expected =
    Prog.opMkFlexVarS
        |> Prog.andThenS
            (\attrVar ->
                Prog.opMkFlexVarS
                    |> Prog.mapS
                        (\unifVar ->
                            let
                                attrType : Type
                                attrType =
                                    VarN attrVar

                                unifType : Type
                                unifType =
                                    VarN unifVar

                                shaderType : Type
                                shaderType =
                                    AppN ModuleName.webgl
                                        Name.shader
                                        [ toShaderRecord attributes attrType
                                        , toShaderRecord uniforms unifType
                                        , toShaderRecord varyings EmptyRecordN
                                        ]
                            in
                            Type.exists [ attrVar, unifVar ] (CEqual region Shader shaderType expected)
                        )
            )


{-| Group A helper for Binop expressions.

Records the answerVar as the expression's type.

-}
constrainBinopWithIdsProg : RigidTypeVar -> A.Region -> Int -> Name.Name -> Can.Annotation -> Can.Expr -> Can.Expr -> E.Expected Type -> ProgS ExprIdState Constraint
constrainBinopWithIdsProg rtv region exprId op annotation leftExpr rightExpr expected =
    Prog.opMkFlexVarS
        |> Prog.andThenS
            (\leftVar ->
                Prog.opMkFlexVarS
                    |> Prog.andThenS
                        (\rightVar ->
                            Prog.opMkFlexVarS
                                |> Prog.andThenS
                                    (\answerVar ->
                                        Prog.opModifyS (NodeIds.recordNodeVar exprId answerVar)
                                            |> Prog.andThenS
                                                (\() ->
                                                    let
                                                        leftType : Type
                                                        leftType =
                                                            VarN leftVar

                                                        rightType : Type
                                                        rightType =
                                                            VarN rightVar

                                                        answerType : Type
                                                        answerType =
                                                            VarN answerVar

                                                        binopType : Type
                                                        binopType =
                                                            Type.funType leftType (Type.funType rightType answerType)

                                                        opCon : Constraint
                                                        opCon =
                                                            CForeign region op annotation (NoExpectation binopType)
                                                    in
                                                    constrainWithIdsProg rtv leftExpr (FromContext region (OpLeft op) leftType)
                                                        |> Prog.andThenS
                                                            (\leftCon ->
                                                                constrainWithIdsProg rtv rightExpr (FromContext region (OpRight op) rightType)
                                                                    |> Prog.mapS
                                                                        (\rightCon ->
                                                                            Type.exists [ leftVar, rightVar, answerVar ]
                                                                                (CAnd
                                                                                    [ opCon
                                                                                    , leftCon
                                                                                    , rightCon
                                                                                    , CEqual region (CallResult (OpName op)) answerType expected
                                                                                    ]
                                                                                )
                                                                        )
                                                            )
                                                )
                                    )
                        )
            )


{-| DSL version of constrainListWithIds.
-}
constrainListWithIdsProg : RigidTypeVar -> A.Region -> List Can.Expr -> E.Expected Type -> ProgS ExprIdState Constraint
constrainListWithIdsProg rtv region entries expected =
    Prog.opMkFlexVarS
        |> Prog.andThenS
            (\entryVar ->
                let
                    entryType : Type
                    entryType =
                        VarN entryVar
                in
                constrainListEntriesWithIdsProg rtv region entryType Index.first entries []
                    |> Prog.mapS
                        (\entryCons ->
                            Type.exists [ entryVar ]
                                (CAnd
                                    [ CAnd entryCons
                                    , CEqual region List (AppN ModuleName.list Name.list [ entryType ]) expected
                                    ]
                                )
                        )
            )


{-| DSL version of constrainListEntriesWithIds.
-}
constrainListEntriesWithIdsProg : RigidTypeVar -> A.Region -> Type -> Index.ZeroBased -> List Can.Expr -> List Constraint -> ProgS ExprIdState (List Constraint)
constrainListEntriesWithIdsProg rtv region tipe index entries acc =
    case entries of
        [] ->
            Prog.pureS (List.reverse acc)

        entry :: rest ->
            constrainWithIdsProg rtv entry (FromContext region (ListEntry index) tipe)
                |> Prog.andThenS
                    (\entryCon ->
                        constrainListEntriesWithIdsProg rtv region tipe (Index.next index) rest (entryCon :: acc)
                    )


{-| Group A helper for If expressions.

For unannotated If expressions, records branchVar as the expression's type.
For annotated If expressions, allocates a synthetic exprVar (Group B behavior).

-}
constrainIfWithIdsProg : RigidTypeVar -> A.Region -> Int -> List ( Can.Expr, Can.Expr ) -> Can.Expr -> E.Expected Type -> ProgS ExprIdState Constraint
constrainIfWithIdsProg rtv region exprId branches final expected =
    let
        boolExpect : Expected Type
        boolExpect =
            FromContext region IfCondition Type.bool

        ( conditions, exprs ) =
            List.foldr (\( c, e ) ( cs, es ) -> ( c :: cs, e :: es )) ( [], [ final ] ) branches
    in
    constrainExprsWithIdsProg rtv conditions boolExpect []
        |> Prog.andThenS
            (\condCons ->
                case expected of
                    FromAnnotation name arity _ tipe ->
                        -- Annotated case: Group B behavior - allocate synthetic exprVar
                        Prog.opMkFlexVarS
                            |> Prog.andThenS
                                (\exprVar ->
                                    Prog.opModifyS (NodeIds.recordNodeVar exprId exprVar)
                                        |> Prog.andThenS
                                            (\() ->
                                                constrainIndexedExprsWithIdsProg rtv exprs (\index -> FromAnnotation name arity (TypedIfBranch index) tipe) Index.first []
                                                    |> Prog.mapS
                                                        (\branchCons ->
                                                            CAnd
                                                                [ CAnd condCons
                                                                , CAnd branchCons
                                                                , CEqual region If (VarN exprVar) expected
                                                                ]
                                                        )
                                            )
                                )

                    _ ->
                        -- Unannotated case: Group A behavior - record branchVar
                        Prog.opMkFlexVarS
                            |> Prog.andThenS
                                (\branchVar ->
                                    Prog.opModifyS (NodeIds.recordNodeVar exprId branchVar)
                                        |> Prog.andThenS
                                            (\() ->
                                                let
                                                    branchType : Type
                                                    branchType =
                                                        VarN branchVar
                                                in
                                                constrainIndexedExprsWithIdsProg rtv exprs (\index -> FromContext region (IfBranch index) branchType) Index.first []
                                                    |> Prog.mapS
                                                        (\branchCons ->
                                                            Type.exists [ branchVar ]
                                                                (CAnd
                                                                    [ CAnd condCons
                                                                    , CAnd branchCons
                                                                    , CEqual region If branchType expected
                                                                    ]
                                                                )
                                                        )
                                            )
                                )
            )


{-| DSL helper for constraining a list of expressions.
-}
constrainExprsWithIdsProg : RigidTypeVar -> List Can.Expr -> E.Expected Type -> List Constraint -> ProgS ExprIdState (List Constraint)
constrainExprsWithIdsProg rtv exprs expected acc =
    case exprs of
        [] ->
            Prog.pureS (List.reverse acc)

        expr :: rest ->
            constrainWithIdsProg rtv expr expected
                |> Prog.andThenS
                    (\con ->
                        constrainExprsWithIdsProg rtv rest expected (con :: acc)
                    )


{-| DSL helper for constraining indexed expressions.
-}
constrainIndexedExprsWithIdsProg : RigidTypeVar -> List Can.Expr -> (Index.ZeroBased -> E.Expected Type) -> Index.ZeroBased -> List Constraint -> ProgS ExprIdState (List Constraint)
constrainIndexedExprsWithIdsProg rtv exprs mkExpected index acc =
    case exprs of
        [] ->
            Prog.pureS (List.reverse acc)

        expr :: rest ->
            constrainWithIdsProg rtv expr (mkExpected index)
                |> Prog.andThenS
                    (\con ->
                        constrainIndexedExprsWithIdsProg rtv rest mkExpected (Index.next index) (con :: acc)
                    )


{-| Group A helper for Case expressions.

Records the bodyVar as the expression's type.

-}
constrainCaseWithIdsProg : RigidTypeVar -> A.Region -> Int -> Can.Expr -> List Can.CaseBranch -> Expected Type -> ProgS ExprIdState Constraint
constrainCaseWithIdsProg rtv region exprId expr branches expected =
    Prog.opMkFlexVarS
        |> Prog.andThenS
            (\ptrnVar ->
                Prog.opMkFlexVarS
                    |> Prog.andThenS
                        (\bodyVar ->
                            Prog.opModifyS (NodeIds.recordNodeVar exprId bodyVar)
                                |> Prog.andThenS
                                    (\() ->
                                        let
                                            ptrnType : Type
                                            ptrnType =
                                                VarN ptrnVar

                                            bodyType : Type
                                            bodyType =
                                                VarN bodyVar

                                            exprExpect : Expected Type
                                            exprExpect =
                                                NoExpectation ptrnType

                                            bodyExpect : Index.ZeroBased -> Expected Type
                                            bodyExpect index =
                                                FromContext region (CaseBranch index) bodyType
                                        in
                                        constrainWithIdsProg rtv expr exprExpect
                                            |> Prog.andThenS
                                                (\exprCon ->
                                                    constrainCaseBranchesWithIdsProg rtv region ptrnType branches bodyExpect Index.first []
                                                        |> Prog.mapS
                                                            (\branchCons ->
                                                                Type.exists [ ptrnVar, bodyVar ]
                                                                    (CAnd
                                                                        [ exprCon
                                                                        , CAnd branchCons
                                                                        , CEqual region Case bodyType expected
                                                                        ]
                                                                    )
                                                            )
                                                )
                                    )
                        )
            )


{-| DSL helper for constraining case branches.
-}
constrainCaseBranchesWithIdsProg : RigidTypeVar -> A.Region -> Type -> List Can.CaseBranch -> (Index.ZeroBased -> Expected Type) -> Index.ZeroBased -> List Constraint -> ProgS ExprIdState (List Constraint)
constrainCaseBranchesWithIdsProg rtv region ptrnType branches mkExpected index acc =
    case branches of
        [] ->
            Prog.pureS (List.reverse acc)

        branch :: rest ->
            constrainCaseBranchWithIdsProg rtv branch (PFromContext region (PCaseMatch index) ptrnType) (mkExpected index)
                |> Prog.andThenS
                    (\branchCon ->
                        constrainCaseBranchesWithIdsProg rtv region ptrnType rest mkExpected (Index.next index) (branchCon :: acc)
                    )


{-| DSL version of constrainCaseBranchWithIds.
-}
constrainCaseBranchWithIdsProg : RigidTypeVar -> Can.CaseBranch -> PExpected Type -> Expected Type -> ProgS ExprIdState Constraint
constrainCaseBranchWithIdsProg rtv (Can.CaseBranch pattern expr) pExpect bExpect =
    Prog.opGetS
        |> Prog.andThenS
            (\state ->
                Prog.opIOS (Pattern.addWithIds pattern pExpect Pattern.emptyState state)
                    |> Prog.andThenS
                        (\( Pattern.State headers pvars revCons, newState ) ->
                            Prog.opModifyS (\_ -> newState)
                                |> Prog.andThenS
                                    (\() ->
                                        constrainWithIdsProg rtv expr bExpect
                                            |> Prog.mapS
                                                (\bodyCon ->
                                                    CLet [] pvars headers (CAnd (List.reverse revCons)) bodyCon
                                                )
                                    )
                        )
            )


{-| DSL version of constrainLambdaWithIds.
-}
constrainLambdaWithIdsProg : RigidTypeVar -> A.Region -> List Can.Pattern -> Can.Expr -> E.Expected Type -> ProgS ExprIdState Constraint
constrainLambdaWithIdsProg rtv region args body expected =
    Prog.opGetS
        |> Prog.andThenS
            (\state ->
                Prog.opIOS (constrainArgsWithIds args state)
                    |> Prog.andThenS
                        (\( Args props, newState ) ->
                            Prog.opModifyS (\_ -> newState)
                                |> Prog.andThenS
                                    (\() ->
                                        let
                                            (Pattern.State headers pvars revCons) =
                                                props.state
                                        in
                                        constrainWithIdsProg rtv body (NoExpectation props.result)
                                            |> Prog.mapS
                                                (\bodyCon ->
                                                    Type.exists props.vars <|
                                                        CAnd
                                                            [ CLet []
                                                                pvars
                                                                headers
                                                                (CAnd (List.reverse revCons))
                                                                bodyCon
                                                            , CEqual region Lambda props.tipe expected
                                                            ]
                                                )
                                    )
                        )
            )


{-| Group A helper for Call expressions.

Records the resultVar as the expression's type.

-}
constrainCallWithIdsProg : RigidTypeVar -> A.Region -> Int -> Can.Expr -> List Can.Expr -> E.Expected Type -> ProgS ExprIdState Constraint
constrainCallWithIdsProg rtv region exprId ((A.At funcRegion _) as func) args expected =
    let
        maybeName : MaybeName
        maybeName =
            getName func
    in
    Prog.opMkFlexVarS
        |> Prog.andThenS
            (\funcVar ->
                Prog.opMkFlexVarS
                    |> Prog.andThenS
                        (\resultVar ->
                            Prog.opModifyS (NodeIds.recordNodeVar exprId resultVar)
                                |> Prog.andThenS
                                    (\() ->
                                        let
                                            funcType : Type
                                            funcType =
                                                VarN funcVar

                                            resultType : Type
                                            resultType =
                                                VarN resultVar
                                        in
                                        constrainWithIdsProg rtv func (E.NoExpectation funcType)
                                            |> Prog.andThenS
                                                (\funcCon ->
                                                    constrainCallArgsWithIdsProg rtv region maybeName Index.first args [] [] []
                                                        |> Prog.mapS
                                                            (\( argVars, argTypes, argCons ) ->
                                                                let
                                                                    arityType : Type
                                                                    arityType =
                                                                        List.foldr FunN resultType argTypes

                                                                    category : Category
                                                                    category =
                                                                        CallResult maybeName
                                                                in
                                                                Type.exists (funcVar :: resultVar :: argVars)
                                                                    (CAnd
                                                                        [ funcCon
                                                                        , CEqual funcRegion category funcType (FromContext region (CallArity maybeName (List.length args)) arityType)
                                                                        , CAnd argCons
                                                                        , CEqual region category resultType expected
                                                                        ]
                                                                    )
                                                            )
                                                )
                                    )
                        )
            )


{-| DSL helper for constraining call arguments.
-}
constrainCallArgsWithIdsProg : RigidTypeVar -> A.Region -> E.MaybeName -> Index.ZeroBased -> List Can.Expr -> List IO.Variable -> List Type -> List Constraint -> ProgS ExprIdState ( List IO.Variable, List Type, List Constraint )
constrainCallArgsWithIdsProg rtv region maybeName index args accVars accTypes accCons =
    case args of
        [] ->
            Prog.pureS ( List.reverse accVars, List.reverse accTypes, List.reverse accCons )

        arg :: rest ->
            Prog.opMkFlexVarS
                |> Prog.andThenS
                    (\argVar ->
                        let
                            argType : Type
                            argType =
                                VarN argVar
                        in
                        constrainWithIdsProg rtv arg (FromContext region (CallArg maybeName index) argType)
                            |> Prog.andThenS
                                (\argCon ->
                                    constrainCallArgsWithIdsProg rtv region maybeName (Index.next index) rest (argVar :: accVars) (argType :: accTypes) (argCon :: accCons)
                                )
                    )


{-| DSL version of constrainRecordWithIds.
-}
constrainRecordWithIdsProg : RigidTypeVar -> A.Region -> Dict String (A.Located Name.Name) Can.Expr -> Expected Type -> ProgS ExprIdState Constraint
constrainRecordWithIdsProg rtv region fields expected =
    let
        fieldList : List ( A.Located Name.Name, Can.Expr )
        fieldList =
            Dict.foldr A.compareLocated (\k v acc -> ( k, v ) :: acc) [] fields
    in
    constrainFieldsWithIdsProg rtv fieldList []
        |> Prog.mapS
            (\fieldConstraints ->
                let
                    vars : List IO.Variable
                    vars =
                        List.map (\( _, ( v, _, _ ) ) -> v) fieldConstraints

                    fieldTypes : Dict String Name.Name Type
                    fieldTypes =
                        List.foldl
                            (\( A.At _ name, ( _, t, _ ) ) acc -> Dict.insert identity name t acc)
                            Dict.empty
                            fieldConstraints

                    fieldCons : List Constraint
                    fieldCons =
                        List.map (\( _, ( _, _, c ) ) -> c) fieldConstraints
                in
                Type.exists vars
                    (CAnd
                        [ CAnd fieldCons
                        , CEqual region Record (RecordN fieldTypes EmptyRecordN) expected
                        ]
                    )
            )


{-| DSL helper for constraining record fields.
-}
constrainFieldsWithIdsProg : RigidTypeVar -> List ( A.Located Name.Name, Can.Expr ) -> List ( A.Located Name.Name, ( IO.Variable, Type, Constraint ) ) -> ProgS ExprIdState (List ( A.Located Name.Name, ( IO.Variable, Type, Constraint ) ))
constrainFieldsWithIdsProg rtv fields acc =
    case fields of
        [] ->
            Prog.pureS (List.reverse acc)

        ( locName, expr ) :: rest ->
            Prog.opMkFlexVarS
                |> Prog.andThenS
                    (\fieldVar ->
                        let
                            fieldType : Type
                            fieldType =
                                VarN fieldVar
                        in
                        constrainWithIdsProg rtv expr (NoExpectation fieldType)
                            |> Prog.andThenS
                                (\fieldCon ->
                                    constrainFieldsWithIdsProg rtv rest (( locName, ( fieldVar, fieldType, fieldCon ) ) :: acc)
                                )
                    )


{-| Group A helper for Update expressions (record update).

Records the recordVar as the expression's type.

-}
constrainUpdateWithIdsProg : RigidTypeVar -> A.Region -> Int -> Can.Expr -> Dict String (A.Located Name.Name) Can.FieldUpdate -> Expected Type -> ProgS ExprIdState Constraint
constrainUpdateWithIdsProg rtv region exprId expr locatedFields expected =
    let
        updateList : List ( Name.Name, Can.FieldUpdate )
        updateList =
            Dict.foldr A.compareLocated (\(A.At _ name) v acc -> ( name, v ) :: acc) [] locatedFields

        fields : Dict String Name.Name Can.FieldUpdate
        fields =
            Utils.mapMapKeys identity A.compareLocated A.toValue locatedFields
    in
    Prog.opMkFlexVarS
        |> Prog.andThenS
            (\extVar ->
                Prog.opMkFlexVarS
                    |> Prog.andThenS
                        (\recordVar ->
                            Prog.opModifyS (NodeIds.recordNodeVar exprId recordVar)
                                |> Prog.andThenS
                                    (\() ->
                                        let
                                            recordType : Type
                                            recordType =
                                                VarN recordVar
                                        in
                                        constrainUpdateFieldsWithIdsProg rtv region updateList []
                                            |> Prog.andThenS
                                                (\fieldConstraints ->
                                                    let
                                                        fieldVars : List IO.Variable
                                                        fieldVars =
                                                            List.map (\( _, ( v, _, _ ) ) -> v) fieldConstraints

                                                        fieldTypes : Dict String Name.Name Type
                                                        fieldTypes =
                                                            List.foldl
                                                                (\( name, ( _, t, _ ) ) acc -> Dict.insert identity name t acc)
                                                                Dict.empty
                                                                fieldConstraints

                                                        fieldCons : List Constraint
                                                        fieldCons =
                                                            List.map (\( _, ( _, _, c ) ) -> c) fieldConstraints

                                                        fieldsType : Type
                                                        fieldsType =
                                                            RecordN fieldTypes (VarN extVar)

                                                        -- NOTE: fieldsTypeCon is separate so that Error propagates better
                                                        fieldsTypeCon : Constraint
                                                        fieldsTypeCon =
                                                            CEqual region Record recordType (NoExpectation fieldsType)

                                                        recordCon : Constraint
                                                        recordCon =
                                                            CEqual region Record recordType expected
                                                    in
                                                    constrainWithIdsProg rtv expr (FromContext region (RecordUpdateKeys fields) recordType)
                                                        |> Prog.mapS
                                                            (\exprCon ->
                                                                Type.exists (recordVar :: extVar :: fieldVars)
                                                                    (CAnd (fieldsTypeCon :: exprCon :: recordCon :: fieldCons))
                                                            )
                                                )
                                    )
                        )
            )


{-| DSL helper for constraining update fields.
-}
constrainUpdateFieldsWithIdsProg : RigidTypeVar -> A.Region -> List ( Name.Name, Can.FieldUpdate ) -> List ( Name.Name, ( IO.Variable, Type, Constraint ) ) -> ProgS ExprIdState (List ( Name.Name, ( IO.Variable, Type, Constraint ) ))
constrainUpdateFieldsWithIdsProg rtv region fields acc =
    case fields of
        [] ->
            Prog.pureS (List.reverse acc)

        ( name, Can.FieldUpdate fieldRegion expr ) :: rest ->
            Prog.opMkFlexVarS
                |> Prog.andThenS
                    (\fieldVar ->
                        let
                            fieldType : Type
                            fieldType =
                                VarN fieldVar

                            expectation : Expected Type
                            expectation =
                                FromContext fieldRegion (RecordUpdateValue name) fieldType
                        in
                        constrainWithIdsProg rtv expr expectation
                            |> Prog.andThenS
                                (\fieldCon ->
                                    constrainUpdateFieldsWithIdsProg rtv region rest (( name, ( fieldVar, fieldType, fieldCon ) ) :: acc)
                                )
                    )


{-| DSL version of constrainTupleWithIds.
-}
constrainTupleWithIdsProg : RigidTypeVar -> A.Region -> Can.Expr -> Can.Expr -> List Can.Expr -> Expected Type -> ProgS ExprIdState Constraint
constrainTupleWithIdsProg rtv region a b cs expected =
    Prog.opMkFlexVarS
        |> Prog.andThenS
            (\aVar ->
                Prog.opMkFlexVarS
                    |> Prog.andThenS
                        (\bVar ->
                            let
                                aType : Type
                                aType =
                                    VarN aVar

                                bType : Type
                                bType =
                                    VarN bVar
                            in
                            constrainWithIdsProg rtv a (NoExpectation aType)
                                |> Prog.andThenS
                                    (\aCon ->
                                        constrainWithIdsProg rtv b (NoExpectation bType)
                                            |> Prog.andThenS
                                                (\bCon ->
                                                    constrainTupleRestWithIdsProg rtv region cs [] []
                                                        |> Prog.mapS
                                                            (\( restCons, restVars ) ->
                                                                let
                                                                    vars : List IO.Variable
                                                                    vars =
                                                                        aVar :: bVar :: restVars

                                                                    restTypes : List Type
                                                                    restTypes =
                                                                        List.map VarN restVars

                                                                    tupleType : Type
                                                                    tupleType =
                                                                        TupleN aType bType restTypes
                                                                in
                                                                Type.exists vars
                                                                    (CAnd
                                                                        [ aCon
                                                                        , bCon
                                                                        , CAnd restCons
                                                                        , CEqual region Tuple tupleType expected
                                                                        ]
                                                                    )
                                                            )
                                                )
                                    )
                        )
            )


{-| DSL helper for constraining remaining tuple elements.
-}
constrainTupleRestWithIdsProg : RigidTypeVar -> A.Region -> List Can.Expr -> List Constraint -> List IO.Variable -> ProgS ExprIdState ( List Constraint, List IO.Variable )
constrainTupleRestWithIdsProg rtv region cs accCons accVars =
    case cs of
        [] ->
            Prog.pureS ( List.reverse accCons, List.reverse accVars )

        c :: rest ->
            Prog.opMkFlexVarS
                |> Prog.andThenS
                    (\cVar ->
                        let
                            cType : Type
                            cType =
                                VarN cVar
                        in
                        constrainWithIdsProg rtv c (NoExpectation cType)
                            |> Prog.andThenS
                                (\cCon ->
                                    constrainTupleRestWithIdsProg rtv region rest (cCon :: accCons) (cVar :: accVars)
                                )
                    )


{-| DSL version of constrainDestructWithIds.
-}
constrainDestructWithIdsProg : RigidTypeVar -> A.Region -> Can.Pattern -> Can.Expr -> Constraint -> ProgS ExprIdState Constraint
constrainDestructWithIdsProg rtv region pattern expr bodyCon =
    Prog.opMkFlexVarS
        |> Prog.andThenS
            (\patternVar ->
                let
                    patternType : Type
                    patternType =
                        VarN patternVar
                in
                Prog.opGetS
                    |> Prog.andThenS
                        (\state ->
                            Prog.opIOS (Pattern.addWithIds pattern (PNoExpectation patternType) Pattern.emptyState state)
                                |> Prog.andThenS
                                    (\( Pattern.State headers pvars revCons, newState ) ->
                                        Prog.opModifyS (\_ -> newState)
                                            |> Prog.andThenS
                                                (\() ->
                                                    constrainWithIdsProg rtv expr (NoExpectation patternType)
                                                        |> Prog.mapS
                                                            (\exprCon ->
                                                                CLet []
                                                                    (patternVar :: pvars)
                                                                    headers
                                                                    (CAnd (exprCon :: List.reverse revCons))
                                                                    bodyCon
                                                            )
                                                )
                                    )
                        )
            )


{-| DSL version of constrainDefWithIds.
-}
constrainDefWithIdsProg : RigidTypeVar -> Can.Def -> Constraint -> ProgS ExprIdState Constraint
constrainDefWithIdsProg rtv def bodyCon =
    case def of
        Can.Def (A.At region name) args expr ->
            Prog.opGetS
                |> Prog.andThenS
                    (\state ->
                        Prog.opIOS (constrainArgsWithIds args state)
                            |> Prog.andThenS
                                (\( Args props, newState ) ->
                                    Prog.opModifyS (\_ -> newState)
                                        |> Prog.andThenS
                                            (\() ->
                                                let
                                                    (Pattern.State headers pvars revCons) =
                                                        props.state
                                                in
                                                constrainWithIdsProg rtv expr (NoExpectation props.result)
                                                    |> Prog.mapS
                                                        (\exprCon ->
                                                            CLet []
                                                                props.vars
                                                                (Dict.singleton identity name (A.At region props.tipe))
                                                                (CLet []
                                                                    pvars
                                                                    headers
                                                                    (CAnd (List.reverse revCons))
                                                                    exprCon
                                                                )
                                                                bodyCon
                                                        )
                                            )
                                )
                    )

        Can.TypedDef (A.At region name) freeVars typedArgs expr srcResultType ->
            let
                newNames : Dict String Name ()
                newNames =
                    Dict.diff freeVars rtv
            in
            Prog.opIOS (IO.traverseMapWithKey identity compare (\k _ -> Type.nameToRigid k) newNames)
                |> Prog.andThenS
                    (\newRigids ->
                        let
                            newRtv : RigidTypeVar
                            newRtv =
                                Dict.union rtv (Dict.map (\_ v -> VarN v) newRigids)
                        in
                        Prog.opGetS
                            |> Prog.andThenS
                                (\state ->
                                    Prog.opIOS (constrainTypedArgsWithIds newRtv name typedArgs srcResultType state)
                                        |> Prog.andThenS
                                            (\( TypedArgs tipe resultType argState, newState ) ->
                                                Prog.opModifyS (\_ -> newState)
                                                    |> Prog.andThenS
                                                        (\() ->
                                                            let
                                                                (Pattern.State headers pvars revCons) =
                                                                    argState
                                                            in
                                                            constrainWithIdsProg newRtv expr (FromAnnotation name (List.length typedArgs) TypedBody resultType)
                                                                |> Prog.mapS
                                                                    (\exprCon ->
                                                                        CLet (Dict.values compare newRigids)
                                                                            []
                                                                            (Dict.singleton identity name (A.At region tipe))
                                                                            (CLet []
                                                                                pvars
                                                                                headers
                                                                                (CAnd (List.reverse revCons))
                                                                                exprCon
                                                                            )
                                                                            bodyCon
                                                                    )
                                                        )
                                            )
                                )
                    )


{-| DSL version of constrainRecursiveDefsWithIds.
-}
constrainRecursiveDefsWithIdsProg : RigidTypeVar -> List Can.Def -> Constraint -> ProgS ExprIdState Constraint
constrainRecursiveDefsWithIdsProg rtv defs bodyCon =
    recDefsHelpWithIdsProg rtv defs bodyCon (Info [] [] Dict.empty) (Info [] [] Dict.empty)


{-| DSL helper for processing recursive definitions.
-}
recDefsHelpWithIdsProg : RigidTypeVar -> List Can.Def -> Constraint -> Info -> Info -> ProgS ExprIdState Constraint
recDefsHelpWithIdsProg rtv defs bodyCon rigidInfo flexInfo =
    case defs of
        [] ->
            let
                (Info rigidVars rigidCons rigidHeaders) =
                    rigidInfo

                (Info flexVars flexCons flexHeaders) =
                    flexInfo
            in
            Prog.pureS
                (CAnd [ CAnd rigidCons, bodyCon ]
                    |> CLet [] flexVars flexHeaders (CLet [] [] flexHeaders CTrue (CAnd flexCons))
                    |> CLet rigidVars [] rigidHeaders CTrue
                )

        def :: otherDefs ->
            case def of
                Can.Def (A.At region name) args expr ->
                    let
                        (Info flexVars flexCons flexHeaders) =
                            flexInfo
                    in
                    Prog.opGetS
                        |> Prog.andThenS
                            (\state ->
                                Prog.opIOS (argsHelpWithIds args (Pattern.State Dict.empty flexVars []) state)
                                    |> Prog.andThenS
                                        (\( Args props, newState ) ->
                                            Prog.opModifyS (\_ -> newState)
                                                |> Prog.andThenS
                                                    (\() ->
                                                        let
                                                            (Pattern.State headers pvars revCons) =
                                                                props.state
                                                        in
                                                        constrainWithIdsProg rtv expr (NoExpectation props.result)
                                                            |> Prog.andThenS
                                                                (\exprCon ->
                                                                    let
                                                                        defCon : Constraint
                                                                        defCon =
                                                                            CLet []
                                                                                pvars
                                                                                headers
                                                                                (CAnd (List.reverse revCons))
                                                                                exprCon

                                                                        newFlexInfo : Info
                                                                        newFlexInfo =
                                                                            Info props.vars (defCon :: flexCons) (Dict.insert identity name (A.At region props.tipe) flexHeaders)
                                                                    in
                                                                    recDefsHelpWithIdsProg rtv otherDefs bodyCon rigidInfo newFlexInfo
                                                                )
                                                    )
                                        )
                            )

                Can.TypedDef (A.At region name) freeVars typedArgs expr srcResultType ->
                    let
                        (Info rigidVars rigidCons rigidHeaders) =
                            rigidInfo

                        newNames : Dict String Name ()
                        newNames =
                            Dict.diff freeVars rtv
                    in
                    Prog.opIOS (IO.traverseMapWithKey identity compare (\k _ -> Type.nameToRigid k) newNames)
                        |> Prog.andThenS
                            (\newRigids ->
                                let
                                    newRtv : RigidTypeVar
                                    newRtv =
                                        Dict.union rtv (Dict.map (\_ -> VarN) newRigids)
                                in
                                Prog.opGetS
                                    |> Prog.andThenS
                                        (\state ->
                                            Prog.opIOS (constrainTypedArgsWithIds newRtv name typedArgs srcResultType state)
                                                |> Prog.andThenS
                                                    (\( TypedArgs tipe resultType argState, newState ) ->
                                                        Prog.opModifyS (\_ -> newState)
                                                            |> Prog.andThenS
                                                                (\() ->
                                                                    let
                                                                        (Pattern.State headers pvars revCons) =
                                                                            argState
                                                                    in
                                                                    constrainWithIdsProg newRtv expr (FromAnnotation name (List.length typedArgs) TypedBody resultType)
                                                                        |> Prog.andThenS
                                                                            (\exprCon ->
                                                                                let
                                                                                    defCon : Constraint
                                                                                    defCon =
                                                                                        CLet []
                                                                                            pvars
                                                                                            headers
                                                                                            (CAnd (List.reverse revCons))
                                                                                            exprCon

                                                                                    wrappedDefCon : Constraint
                                                                                    wrappedDefCon =
                                                                                        CLet (Dict.values compare newRigids) [] Dict.empty defCon CTrue

                                                                                    newRigidInfo : Info
                                                                                    newRigidInfo =
                                                                                        Info (Dict.foldr compare (\_ -> (::)) rigidVars newRigids) (wrappedDefCon :: rigidCons) (Dict.insert identity name (A.At region tipe) rigidHeaders)
                                                                                in
                                                                                recDefsHelpWithIdsProg rtv otherDefs bodyCon newRigidInfo flexInfo
                                                                            )
                                                                )
                                                    )
                                        )
                            )



-- ====== Stack-Safe DSL-Based Constraint Generation ======
--
-- These functions use the Program DSL to avoid stack overflow on deeply nested
-- expressions. The DSL represents constraint-generation steps as data that is
-- interpreted by a tail-recursive loop, keeping stack depth constant.


{-| Generate type constraints using the stack-safe DSL.

This is the main entry point for DSL-based constraint generation. It handles
all expression types and uses an explicit continuation stack to avoid growing
the JavaScript call stack proportionally to AST depth.

-}
constrainProg : RigidTypeVar -> Can.Expr -> E.Expected Type -> Prog Constraint
constrainProg rtv (A.At region exprInfo) expected =
    case exprInfo.node of
        -- Leaf cases: return immediately without recursion
        Can.VarLocal name ->
            Prog.pure (CLocal region name expected)

        Can.VarTopLevel _ name ->
            Prog.pure (CLocal region name expected)

        Can.VarKernel _ _ ->
            Prog.pure CTrue

        Can.VarForeign _ name annotation ->
            Prog.pure (CForeign region name annotation expected)

        Can.VarCtor _ _ name _ annotation ->
            Prog.pure (CForeign region name annotation expected)

        Can.VarDebug _ name annotation ->
            Prog.pure (CForeign region name annotation expected)

        Can.VarOperator op _ _ annotation ->
            Prog.pure (CForeign region op annotation expected)

        Can.Str _ ->
            Prog.pure (CEqual region String Type.string expected)

        Can.Chr _ ->
            Prog.pure (CEqual region Char Type.char expected)

        Can.Int _ ->
            Prog.opMkFlexNumber
                |> Prog.map
                    (\var ->
                        Type.exists [ var ] (CEqual region E.Number (VarN var) expected)
                    )

        Can.Float _ ->
            Prog.pure (CEqual region Float Type.float expected)

        Can.Unit ->
            Prog.pure (CEqual region Unit UnitN expected)

        -- Complex cases: delegate to specialized DSL builders
        Can.List elements ->
            constrainListProg rtv region elements expected

        Can.Negate expr ->
            constrainNegateProg rtv region expr expected

        Can.Binop op _ _ annotation leftExpr rightExpr ->
            constrainBinopProg rtv region op annotation leftExpr rightExpr expected

        Can.Lambda args body ->
            constrainLambdaProg rtv region args body expected

        Can.Call func args ->
            constrainCallProg rtv region func args expected

        Can.If branches finally ->
            constrainIfProg rtv region branches finally expected

        Can.Case expr branches ->
            constrainCaseProg rtv region expr branches expected

        Can.Let def body ->
            constrainProg rtv body expected
                |> Prog.andThen (constrainDefProg rtv def)

        Can.LetRec defs body ->
            constrainProg rtv body expected
                |> Prog.andThen (constrainRecursiveDefsProg rtv defs)

        Can.LetDestruct pattern expr body ->
            constrainProg rtv body expected
                |> Prog.andThen (constrainDestructProg rtv region pattern expr)

        Can.Accessor field ->
            constrainAccessorProg region field expected

        Can.Access expr (A.At accessRegion field) ->
            constrainAccessProg rtv region expr accessRegion field expected

        Can.Update expr fields ->
            constrainUpdateProg rtv region expr fields expected

        Can.Record fields ->
            constrainRecordProg rtv region fields expected

        Can.Tuple a b cs ->
            constrainTupleProg rtv region a b cs expected

        Can.Shader _ types ->
            constrainShaderProg region types expected



-- ====== DSL Builders for Recursive Cases ======


{-| DSL builder for binary operator expressions.
-}
constrainBinopProg : RigidTypeVar -> A.Region -> Name.Name -> Can.Annotation -> Can.Expr -> Can.Expr -> E.Expected Type -> Prog Constraint
constrainBinopProg rtv region op annotation leftExpr rightExpr expected =
    Prog.opMkFlexVar
        |> Prog.andThen
            (\leftVar ->
                Prog.opMkFlexVar
                    |> Prog.andThen
                        (\rightVar ->
                            Prog.opMkFlexVar
                                |> Prog.andThen
                                    (\answerVar ->
                                        let
                                            leftType : Type
                                            leftType =
                                                VarN leftVar

                                            rightType : Type
                                            rightType =
                                                VarN rightVar

                                            answerType : Type
                                            answerType =
                                                VarN answerVar

                                            binopType : Type
                                            binopType =
                                                Type.funType leftType (Type.funType rightType answerType)

                                            opCon : Constraint
                                            opCon =
                                                CForeign region op annotation (NoExpectation binopType)
                                        in
                                        constrainProg rtv leftExpr (FromContext region (OpLeft op) leftType)
                                            |> Prog.andThen
                                                (\leftCon ->
                                                    constrainProg rtv rightExpr (FromContext region (OpRight op) rightType)
                                                        |> Prog.map
                                                            (\rightCon ->
                                                                Type.exists [ leftVar, rightVar, answerVar ]
                                                                    (CAnd
                                                                        [ opCon
                                                                        , leftCon
                                                                        , rightCon
                                                                        , CEqual region (CallResult (OpName op)) answerType expected
                                                                        ]
                                                                    )
                                                            )
                                                )
                                    )
                        )
            )


{-| DSL builder for negation expressions.
-}
constrainNegateProg : RigidTypeVar -> A.Region -> Can.Expr -> E.Expected Type -> Prog Constraint
constrainNegateProg rtv region expr expected =
    Prog.opMkFlexNumber
        |> Prog.andThen
            (\numberVar ->
                let
                    numberType : Type
                    numberType =
                        VarN numberVar
                in
                constrainProg rtv expr (FromContext region Negate numberType)
                    |> Prog.map
                        (\numberCon ->
                            let
                                negateCon : Constraint
                                negateCon =
                                    CEqual region E.Number numberType expected
                            in
                            Type.exists [ numberVar ] (CAnd [ numberCon, negateCon ])
                        )
            )


{-| DSL builder for list expressions.
-}
constrainListProg : RigidTypeVar -> A.Region -> List Can.Expr -> E.Expected Type -> Prog Constraint
constrainListProg rtv region entries expected =
    Prog.opMkFlexVar
        |> Prog.andThen
            (\entryVar ->
                let
                    entryType : Type
                    entryType =
                        VarN entryVar

                    listType : Type
                    listType =
                        AppN ModuleName.list Name.list [ entryType ]
                in
                constrainListEntriesProg rtv region entryType Index.first entries []
                    |> Prog.map
                        (\entryCons ->
                            Type.exists [ entryVar ]
                                (CAnd
                                    [ CAnd entryCons
                                    , CEqual region List listType expected
                                    ]
                                )
                        )
            )


constrainListEntriesProg : RigidTypeVar -> A.Region -> Type -> Index.ZeroBased -> List Can.Expr -> List Constraint -> Prog (List Constraint)
constrainListEntriesProg rtv region tipe index entries acc =
    case entries of
        [] ->
            Prog.pure (List.reverse acc)

        entry :: rest ->
            constrainProg rtv entry (FromContext region (ListEntry index) tipe)
                |> Prog.andThen
                    (\con ->
                        constrainListEntriesProg rtv region tipe (Index.next index) rest (con :: acc)
                    )


{-| DSL builder for if expressions.
-}
constrainIfProg : RigidTypeVar -> A.Region -> List ( Can.Expr, Can.Expr ) -> Can.Expr -> E.Expected Type -> Prog Constraint
constrainIfProg rtv region branches final expected =
    let
        boolExpect : Expected Type
        boolExpect =
            FromContext region IfCondition Type.bool

        ( conditions, exprs ) =
            List.foldr (\( c, e ) ( cs, es ) -> ( c :: cs, e :: es )) ( [], [ final ] ) branches
    in
    constrainExprsProg rtv conditions boolExpect []
        |> Prog.andThen
            (\condCons ->
                case expected of
                    FromAnnotation name arity _ tipe ->
                        constrainIndexedExprsProg rtv exprs (\index -> FromAnnotation name arity (TypedIfBranch index) tipe) Index.first []
                            |> Prog.map
                                (\branchCons ->
                                    CAnd (CAnd condCons :: branchCons)
                                )

                    _ ->
                        Prog.opMkFlexVar
                            |> Prog.andThen
                                (\branchVar ->
                                    let
                                        branchType : Type
                                        branchType =
                                            VarN branchVar
                                    in
                                    constrainIndexedExprsProg rtv exprs (\index -> FromContext region (IfBranch index) branchType) Index.first []
                                        |> Prog.map
                                            (\branchCons ->
                                                Type.exists [ branchVar ]
                                                    (CAnd
                                                        [ CAnd condCons
                                                        , CAnd branchCons
                                                        , CEqual region If branchType expected
                                                        ]
                                                    )
                                            )
                                )
            )


constrainExprsProg : RigidTypeVar -> List Can.Expr -> E.Expected Type -> List Constraint -> Prog (List Constraint)
constrainExprsProg rtv exprs expected acc =
    case exprs of
        [] ->
            Prog.pure (List.reverse acc)

        expr :: rest ->
            constrainProg rtv expr expected
                |> Prog.andThen
                    (\con ->
                        constrainExprsProg rtv rest expected (con :: acc)
                    )


constrainIndexedExprsProg : RigidTypeVar -> List Can.Expr -> (Index.ZeroBased -> E.Expected Type) -> Index.ZeroBased -> List Constraint -> Prog (List Constraint)
constrainIndexedExprsProg rtv exprs mkExpected index acc =
    case exprs of
        [] ->
            Prog.pure (List.reverse acc)

        expr :: rest ->
            constrainProg rtv expr (mkExpected index)
                |> Prog.andThen
                    (\con ->
                        constrainIndexedExprsProg rtv rest mkExpected (Index.next index) (con :: acc)
                    )


{-| DSL builder for case expressions.
-}
constrainCaseProg : RigidTypeVar -> A.Region -> Can.Expr -> List Can.CaseBranch -> Expected Type -> Prog Constraint
constrainCaseProg rtv region expr branches expected =
    Prog.opMkFlexVar
        |> Prog.andThen
            (\ptrnVar ->
                let
                    ptrnType : Type
                    ptrnType =
                        VarN ptrnVar
                in
                constrainProg rtv expr (NoExpectation ptrnType)
                    |> Prog.andThen
                        (\exprCon ->
                            case expected of
                                FromAnnotation name arity _ tipe ->
                                    constrainCaseBranchesProg rtv region ptrnType branches (\index -> FromAnnotation name arity (TypedCaseBranch index) tipe) Index.first []
                                        |> Prog.map
                                            (\branchCons ->
                                                Type.exists [ ptrnVar ] (CAnd (exprCon :: branchCons))
                                            )

                                _ ->
                                    Prog.opMkFlexVar
                                        |> Prog.andThen
                                            (\branchVar ->
                                                let
                                                    branchType : Type
                                                    branchType =
                                                        VarN branchVar
                                                in
                                                constrainCaseBranchesProg rtv region ptrnType branches (\index -> FromContext region (CaseBranch index) branchType) Index.first []
                                                    |> Prog.map
                                                        (\branchCons ->
                                                            Type.exists [ ptrnVar, branchVar ]
                                                                (CAnd
                                                                    [ exprCon
                                                                    , CAnd branchCons
                                                                    , CEqual region Case branchType expected
                                                                    ]
                                                                )
                                                        )
                                            )
                        )
            )


constrainCaseBranchesProg : RigidTypeVar -> A.Region -> Type -> List Can.CaseBranch -> (Index.ZeroBased -> Expected Type) -> Index.ZeroBased -> List Constraint -> Prog (List Constraint)
constrainCaseBranchesProg rtv region ptrnType branches mkExpected index acc =
    case branches of
        [] ->
            Prog.pure (List.reverse acc)

        branch :: rest ->
            constrainCaseBranchProg rtv branch (PFromContext region (PCaseMatch index) ptrnType) (mkExpected index)
                |> Prog.andThen
                    (\con ->
                        constrainCaseBranchesProg rtv region ptrnType rest mkExpected (Index.next index) (con :: acc)
                    )


constrainCaseBranchProg : RigidTypeVar -> Can.CaseBranch -> PExpected Type -> Expected Type -> Prog Constraint
constrainCaseBranchProg rtv (Can.CaseBranch pattern expr) pExpect bExpect =
    -- Use IO for pattern matching (will be converted to PatternProg in Phase 3)
    Prog.opIO (Pattern.add pattern pExpect Pattern.emptyState)
        |> Prog.andThen
            (\(Pattern.State headers pvars revCons) ->
                constrainProg rtv expr bExpect
                    |> Prog.map (CLet [] pvars headers (CAnd (List.reverse revCons)))
            )


{-| DSL builder for lambda expressions.
-}
constrainLambdaProg : RigidTypeVar -> A.Region -> List Can.Pattern -> Can.Expr -> E.Expected Type -> Prog Constraint
constrainLambdaProg rtv region args body expected =
    constrainArgsProg args Pattern.emptyState
        |> Prog.andThen
            (\(Args props) ->
                let
                    (Pattern.State headers pvars revCons) =
                        props.state
                in
                constrainProg rtv body (NoExpectation props.result)
                    |> Prog.map
                        (\bodyCon ->
                            Type.exists props.vars <|
                                CAnd
                                    [ CLet []
                                        pvars
                                        headers
                                        (CAnd (List.reverse revCons))
                                        bodyCon
                                    , CEqual region Lambda props.tipe expected
                                    ]
                        )
            )


constrainArgsProg : List Can.Pattern -> Pattern.State -> Prog Args
constrainArgsProg args state =
    case args of
        [] ->
            Prog.opMkFlexVar
                |> Prog.map
                    (\resultVar ->
                        let
                            resultType : Type
                            resultType =
                                VarN resultVar
                        in
                        makeArgs [ resultVar ] resultType resultType state
                    )

        pattern :: otherArgs ->
            Prog.opMkFlexVar
                |> Prog.andThen
                    (\argVar ->
                        let
                            argType : Type
                            argType =
                                VarN argVar
                        in
                        Prog.opIO (Pattern.add pattern (PNoExpectation argType) state)
                            |> Prog.andThen (constrainArgsProg otherArgs)
                            |> Prog.map
                                (\(Args props) ->
                                    makeArgs (argVar :: props.vars) (FunN argType props.tipe) props.result props.state
                                )
                    )


{-| DSL builder for function call expressions.
-}
constrainCallProg : RigidTypeVar -> A.Region -> Can.Expr -> List Can.Expr -> E.Expected Type -> Prog Constraint
constrainCallProg rtv region ((A.At funcRegion _) as func) args expected =
    let
        maybeName : MaybeName
        maybeName =
            getName func
    in
    Prog.opMkFlexVar
        |> Prog.andThen
            (\funcVar ->
                Prog.opMkFlexVar
                    |> Prog.andThen
                        (\resultVar ->
                            let
                                funcType : Type
                                funcType =
                                    VarN funcVar

                                resultType : Type
                                resultType =
                                    VarN resultVar
                            in
                            constrainProg rtv func (E.NoExpectation funcType)
                                |> Prog.andThen
                                    (\funcCon ->
                                        constrainCallArgsProg rtv region maybeName Index.first args [] [] []
                                            |> Prog.map
                                                (\( argVars, argTypes, argCons ) ->
                                                    let
                                                        arityType : Type
                                                        arityType =
                                                            List.foldr FunN resultType argTypes

                                                        category : Category
                                                        category =
                                                            CallResult maybeName
                                                    in
                                                    Type.exists (funcVar :: resultVar :: argVars)
                                                        (CAnd
                                                            [ funcCon
                                                            , CEqual funcRegion category funcType (FromContext region (CallArity maybeName (List.length args)) arityType)
                                                            , CAnd argCons
                                                            , CEqual region category resultType expected
                                                            ]
                                                        )
                                                )
                                    )
                        )
            )


constrainCallArgsProg : RigidTypeVar -> A.Region -> E.MaybeName -> Index.ZeroBased -> List Can.Expr -> List IO.Variable -> List Type -> List Constraint -> Prog ( List IO.Variable, List Type, List Constraint )
constrainCallArgsProg rtv region maybeName index args accVars accTypes accCons =
    case args of
        [] ->
            Prog.pure ( List.reverse accVars, List.reverse accTypes, List.reverse accCons )

        arg :: rest ->
            Prog.opMkFlexVar
                |> Prog.andThen
                    (\argVar ->
                        let
                            argType : Type
                            argType =
                                VarN argVar
                        in
                        constrainProg rtv arg (FromContext region (CallArg maybeName index) argType)
                            |> Prog.andThen
                                (\argCon ->
                                    constrainCallArgsProg rtv region maybeName (Index.next index) rest (argVar :: accVars) (argType :: accTypes) (argCon :: accCons)
                                )
                    )


{-| DSL builder for record expressions.
-}
constrainRecordProg : RigidTypeVar -> A.Region -> Dict String (A.Located Name.Name) Can.Expr -> Expected Type -> Prog Constraint
constrainRecordProg rtv region fields expected =
    constrainFieldsProg rtv (Dict.toList A.compareLocated fields) []
        |> Prog.map
            (\fieldResults ->
                let
                    dict : Dict String (A.Located Name.Name) ( IO.Variable, Type, Constraint )
                    dict =
                        Dict.fromList A.toValue fieldResults

                    getType : a -> ( b, c, d ) -> c
                    getType _ ( _, t, _ ) =
                        t

                    recordType : Type
                    recordType =
                        RecordN (Utils.mapMapKeys identity A.compareLocated A.toValue (Dict.map getType dict)) EmptyRecordN

                    recordCon : Constraint
                    recordCon =
                        CEqual region Record recordType expected

                    vars : List IO.Variable
                    vars =
                        Dict.foldr A.compareLocated (\_ ( v, _, _ ) vs -> v :: vs) [] dict

                    cons : List Constraint
                    cons =
                        Dict.foldr A.compareLocated (\_ ( _, _, c ) cs -> c :: cs) [ recordCon ] dict
                in
                Type.exists vars (CAnd cons)
            )


constrainFieldsProg : RigidTypeVar -> List ( A.Located Name.Name, Can.Expr ) -> List ( A.Located Name.Name, ( IO.Variable, Type, Constraint ) ) -> Prog (List ( A.Located Name.Name, ( IO.Variable, Type, Constraint ) ))
constrainFieldsProg rtv fields acc =
    case fields of
        [] ->
            Prog.pure (List.reverse acc)

        ( name, expr ) :: rest ->
            Prog.opMkFlexVar
                |> Prog.andThen
                    (\var ->
                        let
                            tipe : Type
                            tipe =
                                VarN var
                        in
                        constrainProg rtv expr (NoExpectation tipe)
                            |> Prog.andThen
                                (\con ->
                                    constrainFieldsProg rtv rest (( name, ( var, tipe, con ) ) :: acc)
                                )
                    )


{-| DSL builder for record update expressions.
-}
constrainUpdateProg : RigidTypeVar -> A.Region -> Can.Expr -> Dict String (A.Located Name.Name) Can.FieldUpdate -> Expected Type -> Prog Constraint
constrainUpdateProg rtv region expr locatedFields expected =
    Prog.opMkFlexVar
        |> Prog.andThen
            (\extVar ->
                let
                    fields : Dict String Name.Name Can.FieldUpdate
                    fields =
                        Utils.mapMapKeys identity A.compareLocated A.toValue locatedFields
                in
                constrainUpdateFieldsProg rtv region (Dict.toList compare fields) []
                    |> Prog.andThen
                        (\fieldResults ->
                            let
                                fieldDict : Dict String Name.Name ( IO.Variable, Type, Constraint )
                                fieldDict =
                                    Dict.fromList identity fieldResults
                            in
                            Prog.opMkFlexVar
                                |> Prog.andThen
                                    (\recordVar ->
                                        let
                                            recordType : Type
                                            recordType =
                                                VarN recordVar

                                            fieldsType : Type
                                            fieldsType =
                                                RecordN (Dict.map (\_ ( _, t, _ ) -> t) fieldDict) (VarN extVar)

                                            fieldsCon : Constraint
                                            fieldsCon =
                                                CEqual region Record recordType (NoExpectation fieldsType)

                                            recordCon : Constraint
                                            recordCon =
                                                CEqual region Record recordType expected

                                            vars : List IO.Variable
                                            vars =
                                                Dict.foldr compare (\_ ( v, _, _ ) vs -> v :: vs) [ recordVar, extVar ] fieldDict

                                            cons : List Constraint
                                            cons =
                                                Dict.foldr compare (\_ ( _, _, c ) cs -> c :: cs) [ recordCon ] fieldDict
                                        in
                                        constrainProg rtv expr (FromContext region (RecordUpdateKeys fields) recordType)
                                            |> Prog.map (\con -> Type.exists vars (CAnd (fieldsCon :: con :: cons)))
                                    )
                        )
            )


constrainUpdateFieldsProg : RigidTypeVar -> A.Region -> List ( Name.Name, Can.FieldUpdate ) -> List ( Name.Name, ( IO.Variable, Type, Constraint ) ) -> Prog (List ( Name.Name, ( IO.Variable, Type, Constraint ) ))
constrainUpdateFieldsProg rtv region fields acc =
    case fields of
        [] ->
            Prog.pure (List.reverse acc)

        ( name, Can.FieldUpdate _ expr ) :: rest ->
            Prog.opMkFlexVar
                |> Prog.andThen
                    (\var ->
                        let
                            tipe : Type
                            tipe =
                                VarN var
                        in
                        constrainProg rtv expr (FromContext region (RecordUpdateValue name) tipe)
                            |> Prog.andThen
                                (\con ->
                                    constrainUpdateFieldsProg rtv region rest (( name, ( var, tipe, con ) ) :: acc)
                                )
                    )


{-| DSL builder for tuple expressions.
-}
constrainTupleProg : RigidTypeVar -> A.Region -> Can.Expr -> Can.Expr -> List Can.Expr -> Expected Type -> Prog Constraint
constrainTupleProg rtv region a b cs expected =
    Prog.opMkFlexVar
        |> Prog.andThen
            (\aVar ->
                Prog.opMkFlexVar
                    |> Prog.andThen
                        (\bVar ->
                            let
                                aType : Type
                                aType =
                                    VarN aVar

                                bType : Type
                                bType =
                                    VarN bVar
                            in
                            constrainProg rtv a (NoExpectation aType)
                                |> Prog.andThen
                                    (\aCon ->
                                        constrainProg rtv b (NoExpectation bType)
                                            |> Prog.andThen
                                                (\bCon ->
                                                    constrainTupleRestProg rtv cs [] []
                                                        |> Prog.map
                                                            (\( cCons, cVars ) ->
                                                                let
                                                                    tupleType : Type
                                                                    tupleType =
                                                                        TupleN aType bType (List.map VarN cVars)

                                                                    tupleCon : Constraint
                                                                    tupleCon =
                                                                        CEqual region Tuple tupleType expected
                                                                in
                                                                Type.exists (aVar :: bVar :: cVars) (CAnd (aCon :: bCon :: cCons ++ [ tupleCon ]))
                                                            )
                                                )
                                    )
                        )
            )


constrainTupleRestProg : RigidTypeVar -> List Can.Expr -> List Constraint -> List IO.Variable -> Prog ( List Constraint, List IO.Variable )
constrainTupleRestProg rtv cs accCons accVars =
    case cs of
        [] ->
            Prog.pure ( List.reverse accCons, List.reverse accVars )

        c :: rest ->
            Prog.opMkFlexVar
                |> Prog.andThen
                    (\cVar ->
                        constrainProg rtv c (NoExpectation (VarN cVar))
                            |> Prog.andThen
                                (\cCon ->
                                    constrainTupleRestProg rtv rest (cCon :: accCons) (cVar :: accVars)
                                )
                    )


{-| DSL builder for accessor expressions (.field).
-}
constrainAccessorProg : A.Region -> Name.Name -> Expected Type -> Prog Constraint
constrainAccessorProg region field expected =
    Prog.opMkFlexVar
        |> Prog.andThen
            (\extVar ->
                Prog.opMkFlexVar
                    |> Prog.map
                        (\fieldVar ->
                            let
                                extType : Type
                                extType =
                                    VarN extVar

                                fieldType : Type
                                fieldType =
                                    VarN fieldVar

                                recordType : Type
                                recordType =
                                    RecordN (Dict.singleton identity field fieldType) extType
                            in
                            Type.exists [ fieldVar, extVar ] (CEqual region (Accessor field) (FunN recordType fieldType) expected)
                        )
            )


{-| DSL builder for access expressions (expr.field).
-}
constrainAccessProg : RigidTypeVar -> A.Region -> Can.Expr -> A.Region -> Name.Name -> Expected Type -> Prog Constraint
constrainAccessProg rtv region expr accessRegion field expected =
    Prog.opMkFlexVar
        |> Prog.andThen
            (\extVar ->
                Prog.opMkFlexVar
                    |> Prog.andThen
                        (\fieldVar ->
                            let
                                extType : Type
                                extType =
                                    VarN extVar

                                fieldType : Type
                                fieldType =
                                    VarN fieldVar

                                recordType : Type
                                recordType =
                                    RecordN (Dict.singleton identity field fieldType) extType

                                context : Context
                                context =
                                    RecordAccess (A.toRegion expr) (getAccessName expr) accessRegion field
                            in
                            constrainProg rtv expr (FromContext region context recordType)
                                |> Prog.map
                                    (\recordCon ->
                                        Type.exists [ fieldVar, extVar ] (CAnd [ recordCon, CEqual region (Access field) fieldType expected ])
                                    )
                        )
            )


{-| DSL builder for shader expressions.
-}
constrainShaderProg : A.Region -> Shader.Types -> Expected Type -> Prog Constraint
constrainShaderProg region (Shader.Types attributes uniforms varyings) expected =
    Prog.opMkFlexVar
        |> Prog.andThen
            (\attrVar ->
                Prog.opMkFlexVar
                    |> Prog.map
                        (\unifVar ->
                            let
                                attrType : Type
                                attrType =
                                    VarN attrVar

                                unifType : Type
                                unifType =
                                    VarN unifVar

                                shaderType : Type
                                shaderType =
                                    AppN ModuleName.webgl
                                        Name.shader
                                        [ toShaderRecord attributes attrType
                                        , toShaderRecord uniforms unifType
                                        , toShaderRecord varyings EmptyRecordN
                                        ]
                            in
                            Type.exists [ attrVar, unifVar ] (CEqual region Shader shaderType expected)
                        )
            )


{-| DSL builder for destructure expressions.
-}
constrainDestructProg : RigidTypeVar -> A.Region -> Can.Pattern -> Can.Expr -> Constraint -> Prog Constraint
constrainDestructProg rtv region pattern expr bodyCon =
    Prog.opMkFlexVar
        |> Prog.andThen
            (\patternVar ->
                let
                    patternType : Type
                    patternType =
                        VarN patternVar
                in
                Prog.opIO (Pattern.add pattern (PNoExpectation patternType) Pattern.emptyState)
                    |> Prog.andThen
                        (\(Pattern.State headers pvars revCons) ->
                            constrainProg rtv expr (FromContext region Destructure patternType)
                                |> Prog.map
                                    (\exprCon ->
                                        CLet [] (patternVar :: pvars) headers (CAnd (List.reverse (exprCon :: revCons))) bodyCon
                                    )
                        )
            )


{-| DSL builder for single definition.
-}
constrainDefProg : RigidTypeVar -> Can.Def -> Constraint -> Prog Constraint
constrainDefProg rtv def bodyCon =
    case def of
        Can.Def (A.At region name) args expr ->
            constrainArgsProg args Pattern.emptyState
                |> Prog.andThen
                    (\(Args props) ->
                        let
                            (Pattern.State headers pvars revCons) =
                                props.state
                        in
                        constrainProg rtv expr (NoExpectation props.result)
                            |> Prog.map
                                (\exprCon ->
                                    CLet []
                                        props.vars
                                        (Dict.singleton identity name (A.At region props.tipe))
                                        (CLet []
                                            pvars
                                            headers
                                            (CAnd (List.reverse revCons))
                                            exprCon
                                        )
                                        bodyCon
                                )
                    )

        Can.TypedDef (A.At region name) freeVars typedArgs expr srcResultType ->
            let
                newNames : Dict String Name ()
                newNames =
                    Dict.diff freeVars rtv
            in
            Prog.opIO (IO.traverseMapWithKey identity compare (\n _ -> Type.nameToRigid n) newNames)
                |> Prog.andThen
                    (\newRigids ->
                        let
                            newRtv : Dict String Name Type
                            newRtv =
                                Dict.union rtv (Dict.map (\_ -> VarN) newRigids)
                        in
                        constrainTypedArgsProg newRtv name typedArgs srcResultType
                            |> Prog.andThen
                                (\(TypedArgs tipe resultType (Pattern.State headers pvars revCons)) ->
                                    let
                                        expected : Expected Type
                                        expected =
                                            FromAnnotation name (List.length typedArgs) TypedBody resultType
                                    in
                                    constrainProg newRtv expr expected
                                        |> Prog.map
                                            (\exprCon ->
                                                CLet (Dict.values compare newRigids)
                                                    []
                                                    (Dict.singleton identity name (A.At region tipe))
                                                    (CLet []
                                                        pvars
                                                        headers
                                                        (CAnd (List.reverse revCons))
                                                        exprCon
                                                    )
                                                    bodyCon
                                            )
                                )
                    )


constrainTypedArgsProg : Dict String Name.Name Type -> Name.Name -> List ( Can.Pattern, Can.Type ) -> Can.Type -> Prog TypedArgs
constrainTypedArgsProg rtv name args srcResultType =
    typedArgsHelpProg rtv name Index.first args srcResultType Pattern.emptyState


typedArgsHelpProg : Dict String Name.Name Type -> Name.Name -> Index.ZeroBased -> List ( Can.Pattern, Can.Type ) -> Can.Type -> Pattern.State -> Prog TypedArgs
typedArgsHelpProg rtv name index args srcResultType state =
    case args of
        [] ->
            Prog.opIO (Instantiate.fromSrcType rtv srcResultType)
                |> Prog.map
                    (\resultType ->
                        TypedArgs resultType resultType state
                    )

        ( (A.At region _) as pattern, srcType ) :: otherArgs ->
            Prog.opIO (Instantiate.fromSrcType rtv srcType)
                |> Prog.andThen
                    (\argType ->
                        let
                            expected : PExpected Type
                            expected =
                                PFromContext region (PTypedArg name index) argType
                        in
                        Prog.opIO (Pattern.add pattern expected state)
                            |> Prog.andThen (typedArgsHelpProg rtv name (Index.next index) otherArgs srcResultType)
                            |> Prog.map
                                (\(TypedArgs tipe resultType newState) ->
                                    TypedArgs (FunN argType tipe) resultType newState
                                )
                    )


{-| DSL builder for recursive definitions.
-}
constrainRecursiveDefsProg : RigidTypeVar -> List Can.Def -> Constraint -> Prog Constraint
constrainRecursiveDefsProg rtv defs bodyCon =
    recDefsHelpProg rtv defs bodyCon emptyInfo emptyInfo


recDefsHelpProg : RigidTypeVar -> List Can.Def -> Constraint -> Info -> Info -> Prog Constraint
recDefsHelpProg rtv defs bodyCon rigidInfo flexInfo =
    case defs of
        [] ->
            let
                (Info rigidVars rigidCons rigidHeaders) =
                    rigidInfo

                (Info flexVars flexCons flexHeaders) =
                    flexInfo
            in
            Prog.pure
                (CAnd [ CAnd rigidCons, bodyCon ]
                    |> CLet [] flexVars flexHeaders (CLet [] [] flexHeaders CTrue (CAnd flexCons))
                    |> CLet rigidVars [] rigidHeaders CTrue
                )

        def :: otherDefs ->
            case def of
                Can.Def (A.At region name) args expr ->
                    let
                        (Info flexVars flexCons flexHeaders) =
                            flexInfo
                    in
                    argsHelpProg args (Pattern.State Dict.empty flexVars [])
                        |> Prog.andThen
                            (\(Args props) ->
                                let
                                    (Pattern.State headers pvars revCons) =
                                        props.state
                                in
                                constrainProg rtv expr (NoExpectation props.result)
                                    |> Prog.andThen
                                        (\exprCon ->
                                            let
                                                defCon : Constraint
                                                defCon =
                                                    CLet []
                                                        pvars
                                                        headers
                                                        (CAnd (List.reverse revCons))
                                                        exprCon
                                            in
                                            recDefsHelpProg rtv otherDefs bodyCon rigidInfo <|
                                                Info props.vars
                                                    (defCon :: flexCons)
                                                    (Dict.insert identity name (A.At region props.tipe) flexHeaders)
                                        )
                            )

                Can.TypedDef (A.At region name) freeVars typedArgs expr srcResultType ->
                    let
                        newNames : Dict String Name ()
                        newNames =
                            Dict.diff freeVars rtv
                    in
                    Prog.opIO (IO.traverseMapWithKey identity compare (\n _ -> Type.nameToRigid n) newNames)
                        |> Prog.andThen
                            (\newRigids ->
                                let
                                    newRtv : Dict String Name Type
                                    newRtv =
                                        Dict.union rtv (Dict.map (\_ -> VarN) newRigids)
                                in
                                constrainTypedArgsProg newRtv name typedArgs srcResultType
                                    |> Prog.andThen
                                        (\(TypedArgs tipe resultType (Pattern.State headers pvars revCons)) ->
                                            constrainProg newRtv expr (FromAnnotation name (List.length typedArgs) TypedBody resultType)
                                                |> Prog.andThen
                                                    (\exprCon ->
                                                        let
                                                            defCon : Constraint
                                                            defCon =
                                                                CLet []
                                                                    pvars
                                                                    headers
                                                                    (CAnd (List.reverse revCons))
                                                                    exprCon

                                                            (Info rigidVars rigidCons rigidHeaders) =
                                                                rigidInfo
                                                        in
                                                        recDefsHelpProg rtv
                                                            otherDefs
                                                            bodyCon
                                                            (Info
                                                                (Dict.foldr compare (\_ -> (::)) rigidVars newRigids)
                                                                (CLet (Dict.values compare newRigids) [] Dict.empty defCon CTrue :: rigidCons)
                                                                (Dict.insert identity name (A.At region tipe) rigidHeaders)
                                                            )
                                                            flexInfo
                                                    )
                                        )
                            )


argsHelpProg : List Can.Pattern -> Pattern.State -> Prog Args
argsHelpProg args state =
    case args of
        [] ->
            Prog.opMkFlexVar
                |> Prog.map
                    (\resultVar ->
                        let
                            resultType : Type
                            resultType =
                                VarN resultVar
                        in
                        makeArgs [ resultVar ] resultType resultType state
                    )

        pattern :: otherArgs ->
            Prog.opMkFlexVar
                |> Prog.andThen
                    (\argVar ->
                        let
                            argType : Type
                            argType =
                                VarN argVar
                        in
                        Prog.opIO (Pattern.add pattern (PNoExpectation argType) state)
                            |> Prog.andThen (argsHelpProg otherArgs)
                            |> Prog.map
                                (\(Args props) ->
                                    makeArgs (argVar :: props.vars) (FunN argType props.tipe) props.result props.state
                                )
                    )
