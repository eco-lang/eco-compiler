module Compiler.Type.Constrain.Expression exposing
    ( RTV
    , constrainDef, constrainRecursiveDefs
    )

{-| Type constraint generation for expressions.

This module walks through canonical expression AST nodes and generates type constraints
that will be solved during type inference. It handles all expression forms including
literals, variables, function calls, pattern matching, records, and more.

The constraint generation process creates relationships between types (e.g., "this
function argument must have the same type as this parameter") without immediately
solving them. The actual unification happens in a separate solving phase.


# Types

@docs RTV


# Constraint Generation

@docs constrainDef, constrainRecursiveDefs

-}

import Compiler.AST.Canonical as Can
import Compiler.AST.Utils.Shader as Shader
import Compiler.Data.Index as Index
import Compiler.Data.Name as Name exposing (Name)
import Compiler.Elm.ModuleName as ModuleName
import Compiler.Reporting.Annotation as A
import Compiler.Reporting.Error.Type as E exposing (Category(..), Context(..), Expected(..), MaybeName(..), PContext(..), PExpected(..), SubContext(..))
import Compiler.Type.Constrain.Pattern as Pattern
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
type alias RTV =
    Dict String Name.Name Type


{-| Generate type constraints for an expression given the current rigid type
variable environment and an expected type. Returns a constraint that will be
solved during type inference.
-}
constrain : RTV -> Can.Expr -> E.Expected Type -> IO Constraint
constrain rtv (A.At region expression) expected =
    case expression of
        Can.VarLocal name ->
            IO.pure (CLocal region name expected)

        Can.VarTopLevel _ name ->
            IO.pure (CLocal region name expected)

        Can.VarKernel _ _ ->
            IO.pure CTrue

        Can.VarForeign _ name annotation ->
            IO.pure (CForeign region name annotation expected)

        Can.VarCtor _ _ name _ annotation ->
            IO.pure (CForeign region name annotation expected)

        Can.VarDebug _ name annotation ->
            IO.pure (CForeign region name annotation expected)

        Can.VarOperator op _ _ annotation ->
            IO.pure (CForeign region op annotation expected)

        Can.Str _ ->
            IO.pure (CEqual region String Type.string expected)

        Can.Chr _ ->
            IO.pure (CEqual region Char Type.char expected)

        Can.Int _ ->
            Type.mkFlexNumber
                |> IO.map
                    (\var ->
                        Type.exists [ var ] (CEqual region E.Number (VarN var) expected)
                    )

        Can.Float _ ->
            IO.pure (CEqual region Float Type.float expected)

        Can.List elements ->
            constrainList rtv region elements expected

        Can.Negate expr ->
            Type.mkFlexNumber
                |> IO.andThen
                    (\numberVar ->
                        let
                            numberType : Type
                            numberType =
                                VarN numberVar
                        in
                        constrain rtv expr (FromContext region Negate numberType)
                            |> IO.map
                                (\numberCon ->
                                    let
                                        negateCon : Constraint
                                        negateCon =
                                            CEqual region E.Number numberType expected
                                    in
                                    Type.exists [ numberVar ] (CAnd [ numberCon, negateCon ])
                                )
                    )

        Can.Binop op _ _ annotation leftExpr rightExpr ->
            constrainBinop rtv region op annotation leftExpr rightExpr expected

        Can.Lambda args body ->
            constrainLambda rtv region args body expected

        Can.Call func args ->
            constrainCall rtv region func args expected

        Can.If branches finally ->
            constrainIf rtv region branches finally expected

        Can.Case expr branches ->
            constrainCase rtv region expr branches expected

        Can.Let def body ->
            constrain rtv body expected |> IO.andThen (constrainDef rtv def)

        Can.LetRec defs body ->
            constrain rtv body expected |> IO.andThen (constrainRecursiveDefs rtv defs)

        Can.LetDestruct pattern expr body ->
            constrain rtv body expected |> IO.andThen (constrainDestruct rtv region pattern expr)

        Can.Accessor field ->
            Type.mkFlexVar
                |> IO.andThen
                    (\extVar ->
                        Type.mkFlexVar
                            |> IO.map
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

        Can.Access expr (A.At accessRegion field) ->
            Type.mkFlexVar
                |> IO.andThen
                    (\extVar ->
                        Type.mkFlexVar
                            |> IO.andThen
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
                                    constrain rtv expr (FromContext region context recordType)
                                        |> IO.map
                                            (\recordCon ->
                                                Type.exists [ fieldVar, extVar ] (CAnd [ recordCon, CEqual region (Access field) fieldType expected ])
                                            )
                                )
                    )

        Can.Update expr fields ->
            constrainUpdate rtv region expr fields expected

        Can.Record fields ->
            constrainRecord rtv region fields expected

        Can.Unit ->
            IO.pure (CEqual region Unit UnitN expected)

        Can.Tuple a b cs ->
            constrainTuple rtv region a b cs expected

        Can.Shader _ types ->
            constrainShader region types expected



-- CONSTRAIN LAMBDA


{-| Generate constraints for a lambda expression (anonymous function). Creates
fresh type variables for each argument pattern, constrains the patterns and body,
and ensures the overall function type matches the expected type.
-}
constrainLambda : RTV -> A.Region -> List Can.Pattern -> Can.Expr -> E.Expected Type -> IO Constraint
constrainLambda rtv region args body expected =
    constrainArgs args
        |> IO.andThen
            (\(Args props) ->
                let
                    (Pattern.State headers pvars revCons) =
                        props.state
                in
                constrain rtv body (NoExpectation props.result)
                    |> IO.map
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



-- CONSTRAIN CALL


{-| Generate constraints for a function call. Creates fresh type variables for
the function and each argument, constrains them appropriately, and ensures the
function type matches the expected arity and result type.
-}
constrainCall : RTV -> A.Region -> Can.Expr -> List Can.Expr -> E.Expected Type -> IO Constraint
constrainCall rtv region ((A.At funcRegion _) as func) args expected =
    let
        maybeName : MaybeName
        maybeName =
            getName func
    in
    Type.mkFlexVar
        |> IO.andThen
            (\funcVar ->
                Type.mkFlexVar
                    |> IO.andThen
                        (\resultVar ->
                            let
                                funcType : Type
                                funcType =
                                    VarN funcVar

                                resultType : Type
                                resultType =
                                    VarN resultVar
                            in
                            constrain rtv func (E.NoExpectation funcType)
                                |> IO.andThen
                                    (\funcCon ->
                                        IO.map Utils.unzip3 (IO.traverseIndexed (constrainArg rtv region maybeName) args)
                                            |> IO.map
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


{-| Generate constraints for a single function call argument at the given index.
Returns the type variable, type, and constraint for the argument.
-}
constrainArg : RTV -> A.Region -> E.MaybeName -> Index.ZeroBased -> Can.Expr -> IO ( IO.Variable, Type, Constraint )
constrainArg rtv region maybeName index arg =
    Type.mkFlexVar
        |> IO.andThen
            (\argVar ->
                let
                    argType : Type
                    argType =
                        VarN argVar
                in
                constrain rtv arg (FromContext region (CallArg maybeName index) argType)
                    |> IO.map
                        (\argCon ->
                            ( argVar, argType, argCon )
                        )
            )


{-| Extract the name from an expression for better error messages. Returns
FuncName, CtorName, OpName, or NoName depending on the expression form.
-}
getName : Can.Expr -> MaybeName
getName (A.At _ expr) =
    case expr of
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
getAccessName (A.At _ expr) =
    case expr of
        Can.VarLocal name ->
            Just name

        Can.VarTopLevel _ name ->
            Just name

        Can.VarForeign _ name _ ->
            Just name

        _ ->
            Nothing



-- CONSTRAIN BINOP


{-| Generate constraints for a binary operator application. Creates fresh type
variables for left operand, right operand, and result, then ensures the operator
type matches the pattern (left -> right -> result).
-}
constrainBinop : RTV -> A.Region -> Name.Name -> Can.Annotation -> Can.Expr -> Can.Expr -> E.Expected Type -> IO Constraint
constrainBinop rtv region op annotation leftExpr rightExpr expected =
    Type.mkFlexVar
        |> IO.andThen
            (\leftVar ->
                Type.mkFlexVar
                    |> IO.andThen
                        (\rightVar ->
                            Type.mkFlexVar
                                |> IO.andThen
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
                                        constrain rtv leftExpr (FromContext region (OpLeft op) leftType)
                                            |> IO.andThen
                                                (\leftCon ->
                                                    constrain rtv rightExpr (FromContext region (OpRight op) rightType)
                                                        |> IO.map
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



-- CONSTRAIN LISTS


{-| Generate constraints for a list literal. Creates a fresh type variable for
the element type and ensures all list entries match that type, producing a
List elementType.
-}
constrainList : RTV -> A.Region -> List Can.Expr -> E.Expected Type -> IO Constraint
constrainList rtv region entries expected =
    Type.mkFlexVar
        |> IO.andThen
            (\entryVar ->
                let
                    entryType : Type
                    entryType =
                        VarN entryVar

                    listType : Type
                    listType =
                        AppN ModuleName.list Name.list [ entryType ]
                in
                IO.traverseIndexed (constrainListEntry rtv region entryType) entries
                    |> IO.map
                        (\entryCons ->
                            Type.exists [ entryVar ]
                                (CAnd
                                    [ CAnd entryCons
                                    , CEqual region List listType expected
                                    ]
                                )
                        )
            )


{-| Generate constraints for a single list entry at the given index, ensuring
it matches the expected element type.
-}
constrainListEntry : RTV -> A.Region -> Type -> Index.ZeroBased -> Can.Expr -> IO Constraint
constrainListEntry rtv region tipe index expr =
    constrain rtv expr (FromContext region (ListEntry index) tipe)



-- CONSTRAIN IF EXPRESSIONS


{-| Generate constraints for an if-expression with multiple branches. Ensures
all conditions are Bool and all branch bodies have the same type.
-}
constrainIf : RTV -> A.Region -> List ( Can.Expr, Can.Expr ) -> Can.Expr -> E.Expected Type -> IO Constraint
constrainIf rtv region branches final expected =
    let
        boolExpect : Expected Type
        boolExpect =
            FromContext region IfCondition Type.bool

        ( conditions, exprs ) =
            List.foldr (\( c, e ) ( cs, es ) -> ( c :: cs, e :: es )) ( [], [ final ] ) branches
    in
    IO.traverseList (\c -> constrain rtv c boolExpect) conditions
        |> IO.andThen
            (\condCons ->
                case expected of
                    FromAnnotation name arity _ tipe ->
                        IO.indexedForA exprs (\index expr -> constrain rtv expr (FromAnnotation name arity (TypedIfBranch index) tipe))
                            |> IO.map
                                (\branchCons ->
                                    CAnd (CAnd condCons :: branchCons)
                                )

                    _ ->
                        Type.mkFlexVar
                            |> IO.andThen
                                (\branchVar ->
                                    let
                                        branchType : Type
                                        branchType =
                                            VarN branchVar
                                    in
                                    IO.indexedForA exprs
                                        (\index expr ->
                                            constrain rtv expr (FromContext region (IfBranch index) branchType)
                                        )
                                        |> IO.map
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



-- CONSTRAIN CASE EXPRESSIONS


{-| Generate constraints for a case-expression. Creates a fresh type variable
for the scrutinee pattern type and ensures all branches match that pattern type
and produce the same result type.
-}
constrainCase : RTV -> A.Region -> Can.Expr -> List Can.CaseBranch -> Expected Type -> IO Constraint
constrainCase rtv region expr branches expected =
    Type.mkFlexVar
        |> IO.andThen
            (\ptrnVar ->
                let
                    ptrnType : Type
                    ptrnType =
                        VarN ptrnVar
                in
                constrain rtv expr (NoExpectation ptrnType)
                    |> IO.andThen
                        (\exprCon ->
                            case expected of
                                FromAnnotation name arity _ tipe ->
                                    IO.indexedForA branches
                                        (\index branch ->
                                            constrainCaseBranch rtv
                                                branch
                                                (PFromContext region (PCaseMatch index) ptrnType)
                                                (FromAnnotation name arity (TypedCaseBranch index) tipe)
                                        )
                                        |> IO.map
                                            (\branchCons ->
                                                Type.exists [ ptrnVar ] (CAnd (exprCon :: branchCons))
                                            )

                                _ ->
                                    Type.mkFlexVar
                                        |> IO.andThen
                                            (\branchVar ->
                                                let
                                                    branchType : Type
                                                    branchType =
                                                        VarN branchVar
                                                in
                                                IO.indexedForA branches
                                                    (\index branch ->
                                                        constrainCaseBranch rtv
                                                            branch
                                                            (PFromContext region (PCaseMatch index) ptrnType)
                                                            (FromContext region (CaseBranch index) branchType)
                                                    )
                                                    |> IO.map
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


{-| Generate constraints for a single case branch. Constrains the pattern to
match the expected pattern type and the branch expression to match the expected
branch result type.
-}
constrainCaseBranch : RTV -> Can.CaseBranch -> PExpected Type -> Expected Type -> IO Constraint
constrainCaseBranch rtv (Can.CaseBranch pattern expr) pExpect bExpect =
    Pattern.add pattern pExpect Pattern.emptyState
        |> IO.andThen
            (\(Pattern.State headers pvars revCons) ->
                IO.map (CLet [] pvars headers (CAnd (List.reverse revCons)))
                    (constrain rtv expr bExpect)
            )



-- CONSTRAIN RECORD


{-| Generate constraints for a record literal. Creates fresh type variables
for each field value and constructs a record type from the field types.
-}
constrainRecord : RTV -> A.Region -> Dict String (A.Located Name.Name) Can.Expr -> Expected Type -> IO Constraint
constrainRecord rtv region fields expected =
    IO.traverseMap A.toValue A.compareLocated (constrainField rtv) fields
        |> IO.map
            (\dict ->
                let
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


{-| Generate constraints for a single record field expression. Returns the
type variable, type, and constraint for the field value.
-}
constrainField : RTV -> Can.Expr -> IO ( IO.Variable, Type, Constraint )
constrainField rtv expr =
    Type.mkFlexVar
        |> IO.andThen
            (\var ->
                let
                    tipe : Type
                    tipe =
                        VarN var
                in
                constrain rtv expr (NoExpectation tipe)
                    |> IO.map
                        (\con ->
                            ( var, tipe, con )
                        )
            )



-- CONSTRAIN RECORD UPDATE


{-| Generate constraints for a record update expression. Ensures the base
expression is a record with the updated fields and that the updated fields
have appropriate types.
-}
constrainUpdate : RTV -> A.Region -> Can.Expr -> Dict String (A.Located Name.Name) Can.FieldUpdate -> Expected Type -> IO Constraint
constrainUpdate rtv region expr locatedFields expected =
    Type.mkFlexVar
        |> IO.andThen
            (\extVar ->
                let
                    fields : Dict String Name.Name Can.FieldUpdate
                    fields =
                        Utils.mapMapKeys identity A.compareLocated A.toValue locatedFields
                in
                IO.traverseMapWithKey identity compare (constrainUpdateField rtv region) fields
                    |> IO.andThen
                        (\fieldDict ->
                            Type.mkFlexVar
                                |> IO.andThen
                                    (\recordVar ->
                                        let
                                            recordType : Type
                                            recordType =
                                                VarN recordVar

                                            fieldsType : Type
                                            fieldsType =
                                                RecordN (Dict.map (\_ ( _, t, _ ) -> t) fieldDict) (VarN extVar)

                                            -- NOTE: fieldsType is separate so that Error propagates better
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
                                        constrain rtv expr (FromContext region (RecordUpdateKeys fields) recordType)
                                            |> IO.map (\con -> Type.exists vars (CAnd (fieldsCon :: con :: cons)))
                                    )
                        )
            )


{-| Generate constraints for a single field in a record update. Returns the
type variable, type, and constraint for the updated field value.
-}
constrainUpdateField : RTV -> A.Region -> Name.Name -> Can.FieldUpdate -> IO ( IO.Variable, Type, Constraint )
constrainUpdateField rtv region field (Can.FieldUpdate _ expr) =
    Type.mkFlexVar
        |> IO.andThen
            (\var ->
                let
                    tipe : Type
                    tipe =
                        VarN var
                in
                constrain rtv expr (FromContext region (RecordUpdateValue field) tipe)
                    |> IO.map (\con -> ( var, tipe, con ))
            )



-- CONSTRAIN TUPLE


{-| Generate constraints for a tuple literal. Creates fresh type variables for
each element and constructs a tuple type from those element types.
-}
constrainTuple : RTV -> A.Region -> Can.Expr -> Can.Expr -> List Can.Expr -> Expected Type -> IO Constraint
constrainTuple rtv region a b cs expected =
    Type.mkFlexVar
        |> IO.andThen
            (\aVar ->
                Type.mkFlexVar
                    |> IO.andThen
                        (\bVar ->
                            let
                                aType : Type
                                aType =
                                    VarN aVar

                                bType : Type
                                bType =
                                    VarN bVar
                            in
                            constrain rtv a (NoExpectation aType)
                                |> IO.andThen
                                    (\aCon ->
                                        constrain rtv b (NoExpectation bType)
                                            |> IO.andThen
                                                (\bCon ->
                                                    List.foldr
                                                        (\c ->
                                                            IO.andThen
                                                                (\( cons, vars ) ->
                                                                    Type.mkFlexVar
                                                                        |> IO.andThen
                                                                            (\cVar ->
                                                                                constrain rtv c (NoExpectation (VarN cVar))
                                                                                    |> IO.map (\cCon -> ( cCon :: cons, cVar :: vars ))
                                                                            )
                                                                )
                                                        )
                                                        (IO.pure ( [], [] ))
                                                        cs
                                                        |> IO.map
                                                            (\( cons, vars ) ->
                                                                let
                                                                    tupleType : Type
                                                                    tupleType =
                                                                        TupleN aType bType (List.map VarN vars)

                                                                    tupleCon : Constraint
                                                                    tupleCon =
                                                                        CEqual region Tuple tupleType expected
                                                                in
                                                                Type.exists (aVar :: bVar :: vars) (CAnd (aCon :: bCon :: cons ++ [ tupleCon ]))
                                                            )
                                                )
                                    )
                        )
            )



-- CONSTRAIN SHADER


{-| Generate constraints for a shader literal (WebGL shader). Constructs a
Shader type with appropriate attribute, uniform, and varying record types
based on the shader's declarations.
-}
constrainShader : A.Region -> Shader.Types -> Expected Type -> IO Constraint
constrainShader region (Shader.Types attributes uniforms varyings) expected =
    Type.mkFlexVar
        |> IO.andThen
            (\attrVar ->
                Type.mkFlexVar
                    |> IO.map
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


{-| Generate constraints for a let-destructure (let pattern = expression).
Ensures the pattern matches the type of the expression and wraps the body
constraint with the pattern bindings.
-}
constrainDestruct : RTV -> A.Region -> Can.Pattern -> Can.Expr -> Constraint -> IO Constraint
constrainDestruct rtv region pattern expr bodyCon =
    Type.mkFlexVar
        |> IO.andThen
            (\patternVar ->
                let
                    patternType : Type
                    patternType =
                        VarN patternVar
                in
                Pattern.add pattern (PNoExpectation patternType) Pattern.emptyState
                    |> IO.andThen
                        (\(Pattern.State headers pvars revCons) ->
                            constrain rtv expr (FromContext region Destructure patternType)
                                |> IO.map
                                    (\exprCon ->
                                        CLet [] (patternVar :: pvars) headers (CAnd (List.reverse (exprCon :: revCons))) bodyCon
                                    )
                        )
            )



-- CONSTRAIN DEF


{-| Generate constraints for a single definition in a let-expression. Handles
both unannotated definitions (where types are inferred) and typed definitions
(where explicit type annotations guide constraint generation).
-}
constrainDef : RTV -> Can.Def -> Constraint -> IO Constraint
constrainDef rtv def bodyCon =
    case def of
        Can.Def (A.At region name) args expr ->
            constrainArgs args
                |> IO.andThen
                    (\(Args props) ->
                        let
                            (Pattern.State headers pvars revCons) =
                                props.state
                        in
                        constrain rtv expr (NoExpectation props.result)
                            |> IO.map
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
            IO.traverseMapWithKey identity compare (\n _ -> Type.nameToRigid n) newNames
                |> IO.andThen
                    (\newRigids ->
                        let
                            newRtv : Dict String Name Type
                            newRtv =
                                Dict.union rtv (Dict.map (\_ -> VarN) newRigids)
                        in
                        constrainTypedArgs newRtv name typedArgs srcResultType
                            |> IO.andThen
                                (\(TypedArgs tipe resultType (Pattern.State headers pvars revCons)) ->
                                    let
                                        expected : Expected Type
                                        expected =
                                            FromAnnotation name (List.length typedArgs) TypedBody resultType
                                    in
                                    constrain newRtv expr expected
                                        |> IO.map
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
-}
constrainRecursiveDefs : RTV -> List Can.Def -> Constraint -> IO Constraint
constrainRecursiveDefs rtv defs bodyCon =
    recDefsHelp rtv defs bodyCon emptyInfo emptyInfo


{-| Helper for constraining recursive definitions. Accumulates rigid (typed)
and flexible (untyped) definition constraints separately to handle their
different scoping rules.
-}
recDefsHelp : RTV -> List Can.Def -> Constraint -> Info -> Info -> IO Constraint
recDefsHelp rtv defs bodyCon rigidInfo flexInfo =
    case defs of
        [] ->
            let
                (Info rigidVars rigidCons rigidHeaders) =
                    rigidInfo

                (Info flexVars flexCons flexHeaders) =
                    flexInfo
            in
            CAnd [ CAnd rigidCons, bodyCon ] |> CLet [] flexVars flexHeaders (CLet [] [] flexHeaders CTrue (CAnd flexCons)) |> CLet rigidVars [] rigidHeaders CTrue |> IO.pure

        def :: otherDefs ->
            case def of
                Can.Def (A.At region name) args expr ->
                    let
                        (Info flexVars flexCons flexHeaders) =
                            flexInfo
                    in
                    argsHelp args (Pattern.State Dict.empty flexVars [])
                        |> IO.andThen
                            (\(Args props) ->
                                let
                                    (Pattern.State headers pvars revCons) =
                                        props.state
                                in
                                constrain rtv expr (NoExpectation props.result)
                                    |> IO.andThen
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
                                            recDefsHelp rtv otherDefs bodyCon rigidInfo <|
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
                    IO.traverseMapWithKey identity compare (\n _ -> Type.nameToRigid n) newNames
                        |> IO.andThen
                            (\newRigids ->
                                let
                                    newRtv : Dict String Name Type
                                    newRtv =
                                        Dict.union rtv (Dict.map (\_ -> VarN) newRigids)
                                in
                                constrainTypedArgs newRtv name typedArgs srcResultType
                                    |> IO.andThen
                                        (\(TypedArgs tipe resultType (Pattern.State headers pvars revCons)) ->
                                            constrain newRtv expr (FromAnnotation name (List.length typedArgs) TypedBody resultType)
                                                |> IO.andThen
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
                                                        recDefsHelp rtv
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


{-| Generate constraints for a list of function argument patterns. Creates fresh
type variables for each argument and accumulates pattern constraints.
-}
constrainArgs : List Can.Pattern -> IO Args
constrainArgs args =
    argsHelp args Pattern.emptyState


{-| Helper for constraining function arguments. Recursively processes patterns,
threading through the pattern state and building up the function type.
-}
argsHelp : List Can.Pattern -> Pattern.State -> IO Args
argsHelp args state =
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
                        makeArgs [ resultVar ] resultType resultType state
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
                        Pattern.add pattern (PNoExpectation argType) state
                            |> IO.andThen (argsHelp otherArgs)
                            |> IO.map
                                (\(Args props) ->
                                    makeArgs (argVar :: props.vars) (FunN argType props.tipe) props.result props.state
                                )
                    )



-- CONSTRAIN TYPED ARGS


{-| Information about typed function arguments including the full function type,
the result type, and the pattern state from argument patterns.
-}
type TypedArgs
    = TypedArgs Type Type Pattern.State


{-| Generate constraints for explicitly typed function arguments (from a type
annotation). Instantiates the source types and ensures patterns match them.
-}
constrainTypedArgs : Dict String Name.Name Type -> Name.Name -> List ( Can.Pattern, Can.Type ) -> Can.Type -> IO TypedArgs
constrainTypedArgs rtv name args srcResultType =
    typedArgsHelp rtv name Index.first args srcResultType Pattern.emptyState


{-| Helper for constraining typed arguments. Recursively processes pattern-type
pairs, instantiating source types and ensuring patterns match, building up the
function type with proper arity tracking for error messages.
-}
typedArgsHelp : Dict String Name.Name Type -> Name.Name -> Index.ZeroBased -> List ( Can.Pattern, Can.Type ) -> Can.Type -> Pattern.State -> IO TypedArgs
typedArgsHelp rtv name index args srcResultType state =
    case args of
        [] ->
            Instantiate.fromSrcType rtv srcResultType
                |> IO.map
                    (\resultType ->
                        TypedArgs resultType resultType state
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
                        Pattern.add pattern expected state
                            |> IO.andThen (typedArgsHelp rtv name (Index.next index) otherArgs srcResultType)
                            |> IO.map
                                (\(TypedArgs tipe resultType newState) ->
                                    TypedArgs (FunN argType tipe) resultType newState
                                )
                    )
