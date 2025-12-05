module Compiler.Generate.CodeGen.MLIR.Mono exposing (backend)

{-| MLIR code generation backend for the Monomorphized IR.

This backend generates MLIR from fully specialized, monomorphic code.
All polymorphism has been resolved and layout information is embedded
in the types.

-}

import Compiler.AST.Monomorphized as Mono
import Compiler.Data.Name as Name
import Compiler.Generate.CodeGen as CodeGen
import Compiler.Generate.Mode as Mode
import Data.Map as EveryDict
import Dict exposing (Dict)
import Mlir.Loc as Loc exposing (Loc)
import Mlir.Mlir as Mlir
    exposing
        ( MlirAttr(..)
        , MlirModule
        , MlirOp
        , MlirRegion(..)
        , MlirType(..)
        , Visibility(..)
        )
import Mlir.Pretty as Pretty
import OrderedDict
import System.TypeCheck.IO as IO



-- BACKEND


backend : CodeGen.MonoCodeGen
backend =
    { generate =
        \config ->
            CodeGen.TextOutput <|
                generateModule config.mode config.graph
    }



-- ECO DIALECT TYPES


{-| eco.value - boxed runtime value
-}
ecoValue : MlirType
ecoValue =
    NamedStruct "eco.value"


{-| eco.int - unboxed 64-bit signed integer
-}
ecoInt : MlirType
ecoInt =
    I64


{-| eco.float - unboxed 64-bit float
-}
ecoFloat : MlirType
ecoFloat =
    F64


{-| eco.bool - unboxed boolean (i1)
-}
ecoBool : MlirType
ecoBool =
    I1


{-| eco.char - unboxed character (i32 unicode codepoint)
-}
ecoChar : MlirType
ecoChar =
    I32



-- CONVERT MONOTYPE TO MLIR TYPE


monoTypeToMlir : Mono.MonoType -> MlirType
monoTypeToMlir monoType =
    case monoType of
        Mono.MInt ->
            ecoInt

        Mono.MFloat ->
            ecoFloat

        Mono.MBool ->
            ecoBool

        Mono.MChar ->
            ecoChar

        Mono.MString ->
            ecoValue

        Mono.MUnit ->
            ecoValue

        Mono.MList _ ->
            ecoValue

        Mono.MTuple _ ->
            ecoValue

        Mono.MRecord _ ->
            ecoValue

        Mono.MCustom _ _ _ _ ->
            ecoValue

        Mono.MFunction _ _ ->
            ecoValue



-- CONTEXT


type alias Context =
    { nextVar : Int
    , nextOpId : Int
    , mode : Mode.Mode
    , registry : Mono.SpecializationRegistry
    }


initContext : Mode.Mode -> Mono.SpecializationRegistry -> Context
initContext mode registry =
    { nextVar = 0
    , nextOpId = 0
    , mode = mode
    , registry = registry
    }


freshVar : Context -> ( String, Context )
freshVar ctx =
    ( "%" ++ String.fromInt ctx.nextVar
    , { ctx | nextVar = ctx.nextVar + 1 }
    )


freshOpId : Context -> ( String, Context )
freshOpId ctx =
    ( "op" ++ String.fromInt ctx.nextOpId
    , { ctx | nextOpId = ctx.nextOpId + 1 }
    )



-- EXPRESSION RESULT


type alias ExprResult =
    { ops : List MlirOp
    , resultVar : String
    , ctx : Context
    }


emptyResult : Context -> String -> ExprResult
emptyResult ctx var =
    { ops = [], resultVar = var, ctx = ctx }



-- OP BUILDER


type alias OpBuilder =
    { name : String
    , id : String
    , operands : List String
    , results : List ( String, MlirType )
    , attrs : Dict String MlirAttr
    , regions : List MlirRegion
    , isTerminator : Bool
    , loc : Loc
    , successors : List String
    }


mlirOp : String -> Context -> OpBuilder
mlirOp name ctx =
    let
        ( opId, _ ) =
            freshOpId ctx
    in
    { name = name
    , id = opId
    , operands = []
    , results = []
    , attrs = Dict.empty
    , regions = []
    , isTerminator = False
    , loc = Loc.unknown
    , successors = []
    }


withOperands : List String -> OpBuilder -> OpBuilder
withOperands operands builder =
    { builder | operands = operands }


withResult : String -> MlirType -> OpBuilder -> OpBuilder
withResult ssa type_ builder =
    { builder | results = [ ( ssa, type_ ) ] }


withResults : List ( String, MlirType ) -> OpBuilder -> OpBuilder
withResults results builder =
    { builder | results = results }


withAttr : String -> MlirAttr -> OpBuilder -> OpBuilder
withAttr key value builder =
    { builder | attrs = Dict.insert key value builder.attrs }


withRegion : MlirRegion -> OpBuilder -> OpBuilder
withRegion region builder =
    { builder | regions = [ region ] }


withRegions : List MlirRegion -> OpBuilder -> OpBuilder
withRegions regions builder =
    { builder | regions = regions }


withLoc : Loc -> OpBuilder -> OpBuilder
withLoc loc builder =
    { builder | loc = loc }


asTerminator : OpBuilder -> OpBuilder
asTerminator builder =
    { builder | isTerminator = True }


build : OpBuilder -> MlirOp
build builder =
    { name = builder.name
    , id = builder.id
    , operands = builder.operands
    , results = builder.results
    , attrs = builder.attrs
    , regions = builder.regions
    , isTerminator = builder.isTerminator
    , loc = builder.loc
    , successors = builder.successors
    }



-- ECO DIALECT OP HELPERS


{-| eco.construct - create a heap object
-}
ecoConstruct : Context -> String -> Int -> Int -> Int -> List String -> MlirOp
ecoConstruct ctx resultVar tag size unboxedBitmap operands =
    mlirOp "eco.construct" ctx
        |> withOperands operands
        |> withResult resultVar ecoValue
        |> withAttr "tag" (IntAttr tag)
        |> withAttr "size" (IntAttr size)
        |> withAttr "unboxed_bitmap" (IntAttr unboxedBitmap)
        |> build


{-| eco.call - call a function by spec id
-}
ecoCall : Context -> String -> Int -> List String -> MlirOp
ecoCall ctx resultVar specId operands =
    mlirOp "eco.call" ctx
        |> withOperands operands
        |> withResult resultVar ecoValue
        |> withAttr "spec_id" (IntAttr specId)
        |> build


{-| eco.call\_named - call a function by name
-}
ecoCallNamed : Context -> String -> String -> List String -> MlirOp
ecoCallNamed ctx resultVar funcName operands =
    mlirOp "eco.call" ctx
        |> withOperands operands
        |> withResult resultVar ecoValue
        |> withAttr "callee" (SymbolRefAttr funcName)
        |> build


{-| eco.project - extract a field from a record/custom/tuple
-}
ecoProject : Context -> String -> Int -> Bool -> String -> MlirOp
ecoProject ctx resultVar index isUnboxed operand =
    let
        resultType =
            if isUnboxed then
                I64

            else
                ecoValue
    in
    mlirOp "eco.project" ctx
        |> withOperands [ operand ]
        |> withResult resultVar resultType
        |> withAttr "index" (IntAttr index)
        |> withAttr "unboxed" (BoolAttr isUnboxed)
        |> build


{-| eco.return - return a value
-}
ecoReturn : Context -> String -> MlirOp
ecoReturn ctx operand =
    mlirOp "eco.return" ctx
        |> withOperands [ operand ]
        |> asTerminator
        |> build


{-| eco.string\_literal - create a string constant
-}
ecoStringLiteral : Context -> String -> String -> MlirOp
ecoStringLiteral ctx resultVar value =
    mlirOp "eco.string_literal" ctx
        |> withResult resultVar ecoValue
        |> withAttr "value" (StringAttr value)
        |> build


{-| arith.constant for integers
-}
arithConstantInt : Context -> String -> Int -> MlirOp
arithConstantInt ctx resultVar value =
    mlirOp "arith.constant" ctx
        |> withResult resultVar I64
        |> withAttr "value" (IntAttr value)
        |> build


{-| arith.constant for floats
-}
arithConstantFloat : Context -> String -> Float -> MlirOp
arithConstantFloat ctx resultVar value =
    mlirOp "arith.constant" ctx
        |> withResult resultVar F64
        |> withAttr "value" (FloatAttr value)
        |> build


{-| arith.constant for booleans
-}
arithConstantBool : Context -> String -> Bool -> MlirOp
arithConstantBool ctx resultVar value =
    mlirOp "arith.constant" ctx
        |> withResult resultVar I1
        |> withAttr "value"
            (IntAttr
                (if value then
                    1

                 else
                    0
                )
            )
        |> build


{-| arith.constant for characters
-}
arithConstantChar : Context -> String -> Int -> MlirOp
arithConstantChar ctx resultVar codepoint =
    mlirOp "arith.constant" ctx
        |> withResult resultVar I32
        |> withAttr "value" (IntAttr codepoint)
        |> build


{-| func.func - define a function
-}
funcFunc : Context -> String -> Int -> List ( String, MlirType ) -> MlirType -> MlirRegion -> MlirOp
funcFunc ctx funcName specId args returnType bodyRegion =
    mlirOp "func.func" ctx
        |> withRegion bodyRegion
        |> withAttr "sym_name" (StringAttr funcName)
        |> withAttr "spec_id" (IntAttr specId)
        |> withAttr "sym_visibility" (VisibilityAttr Private)
        |> withAttr "function_type"
            (TypeAttr
                (FunctionType
                    { inputs = List.map Tuple.second args
                    , results = [ returnType ]
                    }
                )
            )
        |> build


{-| Create a region with a single entry block
-}
mkRegion : List ( String, MlirType ) -> List MlirOp -> MlirOp -> MlirRegion
mkRegion args body terminator =
    MlirRegion
        { entry =
            { args = args
            , body = body
            , terminator = terminator
            }
        , blocks = OrderedDict.empty
        }



-- GENERATE MODULE


generateModule : Mode.Mode -> Mono.MonoGraph -> String
generateModule mode ((Mono.MonoGraph { nodes, main, registry }) as monoGraph) =
    let
        ctx : Context
        ctx =
            initContext mode registry

        -- Generate all nodes (they are already only reachable ones from monomorphization)
        ops : List MlirOp
        ops =
            EveryDict.foldl compare
                (\specId node acc ->
                    generateNode ctx specId node :: acc
                )
                []
                nodes
                |> List.reverse

        -- Generate main entry point if present
        mainOps : List MlirOp
        mainOps =
            case main of
                Just mainSpecId ->
                    [ generateMainEntry ctx mainSpecId ]

                Nothing ->
                    []

        mlirModule : MlirModule
        mlirModule =
            { body = ops ++ mainOps
            , loc = Loc.unknown
            }
    in
    Pretty.ppModule mlirModule


generateMainEntry : Context -> Mono.SpecId -> MlirOp
generateMainEntry ctx mainSpecId =
    let
        ( callVar, ctx1 ) =
            freshVar ctx

        callOp : MlirOp
        callOp =
            ecoCall ctx1 callVar mainSpecId []

        returnOp : MlirOp
        returnOp =
            ecoReturn ctx1 callVar

        region : MlirRegion
        region =
            mkRegion [] [ callOp ] returnOp
    in
    funcFunc ctx "main" (-1) [] ecoValue region



-- GENERATE NODE


generateNode : Context -> Mono.SpecId -> Mono.MonoNode -> MlirOp
generateNode ctx specId node =
    let
        funcName : String
        funcName =
            specIdToFuncName ctx.registry specId
    in
    case node of
        Mono.MonoDefine expr _ monoType ->
            generateDefine ctx funcName specId expr monoType

        Mono.MonoTailFunc params expr _ monoType ->
            generateTailFunc ctx funcName specId params expr monoType

        Mono.MonoCtor ctorLayout monoType ->
            generateCtor ctx funcName specId ctorLayout monoType

        Mono.MonoEnum tag monoType ->
            generateEnum ctx funcName specId tag monoType

        Mono.MonoExtern monoType ->
            generateExtern ctx funcName specId monoType

        Mono.MonoPortIncoming expr _ monoType ->
            generateDefine ctx funcName specId expr monoType

        Mono.MonoPortOutgoing expr _ monoType ->
            generateDefine ctx funcName specId expr monoType


specIdToFuncName : Mono.SpecializationRegistry -> Mono.SpecId -> String
specIdToFuncName registry specId =
    case Mono.lookupSpecKey specId registry of
        Just ( Mono.Global home name, _, _ ) ->
            canonicalToMLIRName home ++ "_" ++ sanitizeName name ++ "_$_" ++ String.fromInt specId

        Nothing ->
            "unknown_$_" ++ String.fromInt specId



-- GENERATE DEFINE


generateDefine : Context -> String -> Mono.SpecId -> Mono.MonoExpr -> Mono.MonoType -> MlirOp
generateDefine ctx funcName specId expr monoType =
    case expr of
        Mono.MonoClosure closureInfo body _ ->
            generateClosureFunc ctx funcName specId closureInfo body monoType

        _ ->
            -- Value (thunk) - wrap in nullary function
            let
                exprResult : ExprResult
                exprResult =
                    generateExpr ctx expr

                returnOp : MlirOp
                returnOp =
                    ecoReturn exprResult.ctx exprResult.resultVar

                region : MlirRegion
                region =
                    mkRegion [] exprResult.ops returnOp
            in
            funcFunc ctx funcName specId [] (monoTypeToMlir monoType) region


generateClosureFunc : Context -> String -> Mono.SpecId -> Mono.ClosureInfo -> Mono.MonoExpr -> Mono.MonoType -> MlirOp
generateClosureFunc ctx funcName specId closureInfo body monoType =
    let
        -- Build arg pairs from params
        argPairs : List ( String, MlirType )
        argPairs =
            List.map
                (\( name, ty ) -> ( "%" ++ name, monoTypeToMlir ty ))
                closureInfo.params

        -- Create context with args bound
        ctxWithArgs : Context
        ctxWithArgs =
            { ctx | nextVar = List.length closureInfo.params }

        exprResult : ExprResult
        exprResult =
            generateExpr ctxWithArgs body

        returnOp : MlirOp
        returnOp =
            ecoReturn exprResult.ctx exprResult.resultVar

        region : MlirRegion
        region =
            mkRegion argPairs exprResult.ops returnOp
    in
    funcFunc ctx funcName specId argPairs (monoTypeToMlir monoType) region



-- GENERATE TAIL FUNC


generateTailFunc : Context -> String -> Mono.SpecId -> List ( Name.Name, Mono.MonoType ) -> Mono.MonoExpr -> Mono.MonoType -> MlirOp
generateTailFunc ctx funcName specId params expr monoType =
    let
        argPairs : List ( String, MlirType )
        argPairs =
            List.map
                (\( name, ty ) -> ( "%" ++ name, monoTypeToMlir ty ))
                params

        ctxWithArgs : Context
        ctxWithArgs =
            { ctx | nextVar = List.length params }

        exprResult : ExprResult
        exprResult =
            generateExpr ctxWithArgs expr

        returnOp : MlirOp
        returnOp =
            ecoReturn exprResult.ctx exprResult.resultVar

        region : MlirRegion
        region =
            mkRegion argPairs exprResult.ops returnOp
    in
    funcFunc ctx funcName specId argPairs (monoTypeToMlir monoType) region



-- GENERATE CTOR


generateCtor : Context -> String -> Mono.SpecId -> Mono.CtorLayout -> Mono.MonoType -> MlirOp
generateCtor ctx funcName specId ctorLayout monoType =
    let
        arity : Int
        arity =
            List.length ctorLayout.fields
    in
    if arity == 0 then
        -- Nullary constructor
        let
            ( resultVar, ctx1 ) =
                freshVar ctx

            constructOp : MlirOp
            constructOp =
                ecoConstruct ctx1 resultVar ctorLayout.tag 0 0 []

            returnOp : MlirOp
            returnOp =
                ecoReturn ctx1 resultVar

            region : MlirRegion
            region =
                mkRegion [] [ constructOp ] returnOp
        in
        funcFunc ctx funcName specId [] ecoValue region

    else
        -- Constructor with arguments
        let
            argNames : List String
            argNames =
                List.indexedMap
                    (\i _ -> "%arg" ++ String.fromInt i)
                    ctorLayout.fields

            argTypes : List MlirType
            argTypes =
                List.map
                    (\field ->
                        if field.isUnboxed then
                            monoTypeToMlir field.monoType

                        else
                            ecoValue
                    )
                    ctorLayout.fields

            argPairs : List ( String, MlirType )
            argPairs =
                List.map2 Tuple.pair argNames argTypes

            ( resultVar, ctx1 ) =
                freshVar { ctx | nextVar = arity }

            constructOp : MlirOp
            constructOp =
                ecoConstruct ctx1 resultVar ctorLayout.tag arity ctorLayout.unboxedBitmap argNames

            returnOp : MlirOp
            returnOp =
                ecoReturn ctx1 resultVar

            region : MlirRegion
            region =
                mkRegion argPairs [ constructOp ] returnOp
        in
        funcFunc ctx funcName specId argPairs ecoValue region



-- GENERATE ENUM


generateEnum : Context -> String -> Mono.SpecId -> Int -> Mono.MonoType -> MlirOp
generateEnum ctx funcName specId tag monoType =
    let
        ( resultVar, ctx1 ) =
            freshVar ctx

        constructOp : MlirOp
        constructOp =
            ecoConstruct ctx1 resultVar tag 0 0 []

        returnOp : MlirOp
        returnOp =
            ecoReturn ctx1 resultVar

        region : MlirRegion
        region =
            mkRegion [] [ constructOp ] returnOp
    in
    funcFunc ctx funcName specId [] ecoValue region



-- GENERATE EXTERN


generateExtern : Context -> String -> Mono.SpecId -> Mono.MonoType -> MlirOp
generateExtern ctx funcName specId monoType =
    -- Generate an extern declaration (no body)
    mlirOp "func.func" ctx
        |> withAttr "sym_name" (StringAttr funcName)
        |> withAttr "spec_id" (IntAttr specId)
        |> withAttr "sym_visibility" (VisibilityAttr Private)
        |> withAttr "function_type"
            (TypeAttr
                (FunctionType
                    { inputs = []
                    , results = [ monoTypeToMlir monoType ]
                    }
                )
            )
        |> build



-- GENERATE EXPRESSION


generateExpr : Context -> Mono.MonoExpr -> ExprResult
generateExpr ctx expr =
    case expr of
        Mono.MonoLiteral lit _ ->
            generateLiteral ctx lit

        Mono.MonoVarLocal name _ ->
            emptyResult ctx ("%" ++ name)

        Mono.MonoVarGlobal _ specId _ ->
            generateVarGlobal ctx specId

        Mono.MonoVarKernel _ home name _ ->
            generateVarKernel ctx home name

        Mono.MonoList _ items _ ->
            generateList ctx items

        Mono.MonoClosure closureInfo body monoType ->
            generateClosure ctx closureInfo body monoType

        Mono.MonoCall _ func args _ ->
            generateCall ctx func args

        Mono.MonoTailCall name args _ ->
            generateTailCall ctx name args

        Mono.MonoIf branches final _ ->
            generateIf ctx branches final

        Mono.MonoLet def body _ ->
            generateLet ctx def body

        Mono.MonoDestruct destructor body _ ->
            generateDestruct ctx destructor body

        Mono.MonoCase scrutinee1 scrutinee2 decider jumps _ ->
            generateCase ctx scrutinee1 scrutinee2 decider jumps

        Mono.MonoRecordCreate fields layout _ ->
            generateRecordCreate ctx fields layout

        Mono.MonoRecordAccess record fieldName index isUnboxed _ ->
            generateRecordAccess ctx record fieldName index isUnboxed

        Mono.MonoRecordUpdate record updates layout _ ->
            generateRecordUpdate ctx record updates layout

        Mono.MonoTupleCreate _ elements layout _ ->
            generateTupleCreate ctx elements layout

        Mono.MonoTupleAccess tuple index isUnboxed _ ->
            generateTupleAccess ctx tuple index isUnboxed

        Mono.MonoCustomCreate ctorName tag fields layout _ ->
            generateCustomCreate ctx ctorName tag fields layout

        Mono.MonoUnit ->
            generateUnit ctx

        Mono.MonoAccessor _ fieldName _ ->
            generateAccessor ctx fieldName



-- LITERAL GENERATION


generateLiteral : Context -> Mono.Literal -> ExprResult
generateLiteral ctx lit =
    case lit of
        Mono.LBool value ->
            let
                ( var, ctx1 ) =
                    freshVar ctx
            in
            { ops = [ arithConstantBool ctx1 var value ]
            , resultVar = var
            , ctx = ctx1
            }

        Mono.LInt value ->
            let
                ( var, ctx1 ) =
                    freshVar ctx
            in
            { ops = [ arithConstantInt ctx1 var value ]
            , resultVar = var
            , ctx = ctx1
            }

        Mono.LFloat value ->
            let
                ( var, ctx1 ) =
                    freshVar ctx
            in
            { ops = [ arithConstantFloat ctx1 var value ]
            , resultVar = var
            , ctx = ctx1
            }

        Mono.LChar value ->
            let
                ( var, ctx1 ) =
                    freshVar ctx

                codepoint : Int
                codepoint =
                    String.uncons value
                        |> Maybe.map (Tuple.first >> Char.toCode)
                        |> Maybe.withDefault 0
            in
            { ops = [ arithConstantChar ctx1 var codepoint ]
            , resultVar = var
            , ctx = ctx1
            }

        Mono.LStr value ->
            let
                ( var, ctx1 ) =
                    freshVar ctx
            in
            { ops = [ ecoStringLiteral ctx1 var value ]
            , resultVar = var
            , ctx = ctx1
            }



-- VARIABLE GENERATION


generateVarGlobal : Context -> Mono.SpecId -> ExprResult
generateVarGlobal ctx specId =
    let
        ( var, ctx1 ) =
            freshVar ctx
    in
    { ops = [ ecoCall ctx1 var specId [] ]
    , resultVar = var
    , ctx = ctx1
    }


generateVarKernel : Context -> Name.Name -> Name.Name -> ExprResult
generateVarKernel ctx home name =
    let
        ( var, ctx1 ) =
            freshVar ctx

        kernelName : String
        kernelName =
            "Elm_Kernel_" ++ home ++ "_" ++ name
    in
    { ops = [ ecoCallNamed ctx1 var kernelName [] ]
    , resultVar = var
    , ctx = ctx1
    }



-- LIST GENERATION


generateList : Context -> List Mono.MonoExpr -> ExprResult
generateList ctx items =
    case items of
        [] ->
            -- Empty list: Nil tag 0
            let
                ( var, ctx1 ) =
                    freshVar ctx
            in
            { ops = [ ecoConstruct ctx1 var 0 0 0 [] ]
            , resultVar = var
            , ctx = ctx1
            }

        _ ->
            -- Build list from right to left
            let
                ( nilVar, ctx1 ) =
                    freshVar ctx

                nilOp : MlirOp
                nilOp =
                    ecoConstruct ctx1 nilVar 0 0 0 []

                -- Fold from right
                ( consOps, finalVar, finalCtx ) =
                    List.foldr
                        (\item ( accOps, tailVar, accCtx ) ->
                            let
                                itemResult : ExprResult
                                itemResult =
                                    generateExpr accCtx item

                                ( consVar, ctx2 ) =
                                    freshVar itemResult.ctx

                                -- Cons tag 1, size 2
                                consOp : MlirOp
                                consOp =
                                    ecoConstruct ctx2 consVar 1 2 0 [ itemResult.resultVar, tailVar ]
                            in
                            ( itemResult.ops ++ [ consOp ] ++ accOps, consVar, ctx2 )
                        )
                        ( [], nilVar, ctx1 )
                        items
            in
            { ops = [ nilOp ] ++ consOps
            , resultVar = finalVar
            , ctx = finalCtx
            }



-- CLOSURE GENERATION


generateClosure : Context -> Mono.ClosureInfo -> Mono.MonoExpr -> Mono.MonoType -> ExprResult
generateClosure ctx closureInfo body monoType =
    -- Generate captured values and create a PAP
    let
        ( captureOps, captureVars, ctx1 ) =
            List.foldl
                (\( name, expr, isUnboxed ) ( accOps, accVars, accCtx ) ->
                    let
                        result : ExprResult
                        result =
                            generateExpr accCtx expr
                    in
                    ( accOps ++ result.ops, accVars ++ [ result.resultVar ], result.ctx )
                )
                ( [], [], ctx )
                closureInfo.captures

        ( resultVar, ctx2 ) =
            freshVar ctx1

        arity : Int
        arity =
            List.length closureInfo.params

        numCaptured : Int
        numCaptured =
            List.length closureInfo.captures

        -- Create a papCreate op
        papOp : MlirOp
        papOp =
            mlirOp "eco.papCreate" ctx2
                |> withOperands captureVars
                |> withResult resultVar ecoValue
                |> withAttr "lambda_id" (StringAttr (lambdaIdToString closureInfo.lambdaId))
                |> withAttr "arity" (IntAttr arity)
                |> withAttr "num_captured" (IntAttr numCaptured)
                |> build
    in
    { ops = captureOps ++ [ papOp ]
    , resultVar = resultVar
    , ctx = ctx2
    }


lambdaIdToString : Mono.LambdaId -> String
lambdaIdToString lambdaId =
    case lambdaId of
        Mono.NamedFunction (Mono.Global home name) ->
            canonicalToMLIRName home ++ "_" ++ sanitizeName name

        Mono.AnonymousLambda home uid _ ->
            canonicalToMLIRName home ++ "_lambda_" ++ String.fromInt uid



-- CALL GENERATION


generateCall : Context -> Mono.MonoExpr -> List Mono.MonoExpr -> ExprResult
generateCall ctx func args =
    case func of
        Mono.MonoVarGlobal _ specId _ ->
            -- Direct call to known specialization
            let
                ( argsOps, argVars, ctx1 ) =
                    generateExprList ctx args

                ( resultVar, ctx2 ) =
                    freshVar ctx1
            in
            { ops = argsOps ++ [ ecoCall ctx2 resultVar specId argVars ]
            , resultVar = resultVar
            , ctx = ctx2
            }

        Mono.MonoVarLocal name _ ->
            -- Call through local variable (closure)
            let
                ( argsOps, argVars, ctx1 ) =
                    generateExprList ctx args

                ( resultVar, ctx2 ) =
                    freshVar ctx1

                papExtendOp : MlirOp
                papExtendOp =
                    mlirOp "eco.papExtend" ctx2
                        |> withOperands (("%" ++ name) :: argVars)
                        |> withResult resultVar ecoValue
                        |> build
            in
            { ops = argsOps ++ [ papExtendOp ]
            , resultVar = resultVar
            , ctx = ctx2
            }

        _ ->
            -- General case: evaluate function then call
            let
                funcResult : ExprResult
                funcResult =
                    generateExpr ctx func

                ( argsOps, argVars, ctx1 ) =
                    generateExprList funcResult.ctx args

                ( resultVar, ctx2 ) =
                    freshVar ctx1

                papExtendOp : MlirOp
                papExtendOp =
                    mlirOp "eco.papExtend" ctx2
                        |> withOperands (funcResult.resultVar :: argVars)
                        |> withResult resultVar ecoValue
                        |> build
            in
            { ops = funcResult.ops ++ argsOps ++ [ papExtendOp ]
            , resultVar = resultVar
            , ctx = ctx2
            }


generateExprList : Context -> List Mono.MonoExpr -> ( List MlirOp, List String, Context )
generateExprList ctx exprs =
    List.foldl
        (\expr ( accOps, accVars, accCtx ) ->
            let
                result : ExprResult
                result =
                    generateExpr accCtx expr
            in
            ( accOps ++ result.ops, accVars ++ [ result.resultVar ], result.ctx )
        )
        ( [], [], ctx )
        exprs



-- TAIL CALL GENERATION


generateTailCall : Context -> Name.Name -> List ( Name.Name, Mono.MonoExpr ) -> ExprResult
generateTailCall ctx name args =
    let
        ( argsOps, argVars, ctx1 ) =
            List.foldl
                (\( _, expr ) ( accOps, accVars, accCtx ) ->
                    let
                        result : ExprResult
                        result =
                            generateExpr accCtx expr
                    in
                    ( accOps ++ result.ops, accVars ++ [ result.resultVar ], result.ctx )
                )
                ( [], [], ctx )
                args

        jumpOp : MlirOp
        jumpOp =
            mlirOp "eco.jump" ctx1
                |> withOperands argVars
                |> withAttr "target" (StringAttr name)
                |> asTerminator
                |> build

        -- Need a placeholder result since jump is a terminator
        ( resultVar, ctx2 ) =
            freshVar ctx1
    in
    { ops = argsOps ++ [ jumpOp, ecoConstruct ctx2 resultVar 0 0 0 [] ]
    , resultVar = resultVar
    , ctx = ctx2
    }



-- IF GENERATION


generateIf : Context -> List ( Mono.MonoExpr, Mono.MonoExpr ) -> Mono.MonoExpr -> ExprResult
generateIf ctx branches final =
    case branches of
        [] ->
            generateExpr ctx final

        ( cond, thenBranch ) :: restBranches ->
            let
                condResult : ExprResult
                condResult =
                    generateExpr ctx cond

                thenResult : ExprResult
                thenResult =
                    generateExpr condResult.ctx thenBranch

                elseResult : ExprResult
                elseResult =
                    generateIf thenResult.ctx restBranches final

                -- TODO: Proper scf.if implementation
            in
            { ops = condResult.ops ++ thenResult.ops ++ elseResult.ops
            , resultVar = elseResult.resultVar
            , ctx = elseResult.ctx
            }



-- LET GENERATION


generateLet : Context -> Mono.MonoDef -> Mono.MonoExpr -> ExprResult
generateLet ctx def body =
    case def of
        Mono.MonoDef _ name expr _ ->
            let
                exprResult : ExprResult
                exprResult =
                    generateExpr ctx expr

                -- Bind the name
                aliasOp : MlirOp
                aliasOp =
                    ecoConstruct exprResult.ctx ("%" ++ name) 0 1 0 [ exprResult.resultVar ]

                bodyResult : ExprResult
                bodyResult =
                    generateExpr exprResult.ctx body
            in
            { ops = exprResult.ops ++ [ aliasOp ] ++ bodyResult.ops
            , resultVar = bodyResult.resultVar
            , ctx = bodyResult.ctx
            }

        Mono.MonoTailDef _ name params expr _ ->
            -- TODO: Proper joinpoint handling
            let
                bodyResult : ExprResult
                bodyResult =
                    generateExpr ctx body
            in
            bodyResult



-- DESTRUCT GENERATION


generateDestruct : Context -> Mono.MonoDestructor -> Mono.MonoExpr -> ExprResult
generateDestruct ctx (Mono.MonoDestructor name path _) body =
    let
        ( pathOps, pathVar, ctx1 ) =
            generateMonoPath ctx path

        aliasOp : MlirOp
        aliasOp =
            ecoConstruct ctx1 ("%" ++ name) 0 1 0 [ pathVar ]

        bodyResult : ExprResult
        bodyResult =
            generateExpr ctx1 body
    in
    { ops = pathOps ++ [ aliasOp ] ++ bodyResult.ops
    , resultVar = bodyResult.resultVar
    , ctx = bodyResult.ctx
    }


generateMonoPath : Context -> Mono.MonoPath -> ( List MlirOp, String, Context )
generateMonoPath ctx path =
    case path of
        Mono.MonoRoot name ->
            ( [], "%" ++ name, ctx )

        Mono.MonoIndex index subPath ->
            let
                ( subOps, subVar, ctx1 ) =
                    generateMonoPath ctx subPath

                ( resultVar, ctx2 ) =
                    freshVar ctx1
            in
            ( subOps ++ [ ecoProject ctx2 resultVar index False subVar ]
            , resultVar
            , ctx2
            )

        Mono.MonoField name index subPath ->
            let
                ( subOps, subVar, ctx1 ) =
                    generateMonoPath ctx subPath

                ( resultVar, ctx2 ) =
                    freshVar ctx1
            in
            ( subOps ++ [ ecoProject ctx2 resultVar index False subVar ]
            , resultVar
            , ctx2
            )

        Mono.MonoUnbox subPath ->
            generateMonoPath ctx subPath



-- CASE GENERATION


generateCase : Context -> Name.Name -> Name.Name -> Mono.Decider Mono.MonoChoice -> List ( Int, Mono.MonoExpr ) -> ExprResult
generateCase ctx scrutinee1 scrutinee2 decider jumps =
    -- TODO: Proper decision tree compilation
    let
        ( resultVar, ctx1 ) =
            freshVar ctx
    in
    { ops = [ ecoConstruct ctx1 resultVar 0 0 0 [] ]
    , resultVar = resultVar
    , ctx = ctx1
    }



-- RECORD GENERATION


generateRecordCreate : Context -> List Mono.MonoExpr -> Mono.RecordLayout -> ExprResult
generateRecordCreate ctx fields layout =
    let
        ( fieldsOps, fieldVars, ctx1 ) =
            generateExprList ctx fields

        ( resultVar, ctx2 ) =
            freshVar ctx1
    in
    { ops = fieldsOps ++ [ ecoConstruct ctx2 resultVar 0 layout.fieldCount layout.unboxedBitmap fieldVars ]
    , resultVar = resultVar
    , ctx = ctx2
    }


generateRecordAccess : Context -> Mono.MonoExpr -> Name.Name -> Int -> Bool -> ExprResult
generateRecordAccess ctx record fieldName index isUnboxed =
    let
        recordResult : ExprResult
        recordResult =
            generateExpr ctx record

        ( resultVar, ctx1 ) =
            freshVar recordResult.ctx
    in
    { ops = recordResult.ops ++ [ ecoProject ctx1 resultVar index isUnboxed recordResult.resultVar ]
    , resultVar = resultVar
    , ctx = ctx1
    }


generateRecordUpdate : Context -> Mono.MonoExpr -> List ( Int, Mono.MonoExpr ) -> Mono.RecordLayout -> ExprResult
generateRecordUpdate ctx record updates layout =
    -- TODO: Proper record update implementation
    let
        recordResult : ExprResult
        recordResult =
            generateExpr ctx record

        ( resultVar, ctx1 ) =
            freshVar recordResult.ctx
    in
    { ops = recordResult.ops ++ [ ecoConstruct ctx1 resultVar 0 1 0 [ recordResult.resultVar ] ]
    , resultVar = resultVar
    , ctx = ctx1
    }



-- TUPLE GENERATION


generateTupleCreate : Context -> List Mono.MonoExpr -> Mono.TupleLayout -> ExprResult
generateTupleCreate ctx elements layout =
    let
        ( elemOps, elemVars, ctx1 ) =
            generateExprList ctx elements

        ( resultVar, ctx2 ) =
            freshVar ctx1
    in
    { ops = elemOps ++ [ ecoConstruct ctx2 resultVar 0 layout.arity layout.unboxedBitmap elemVars ]
    , resultVar = resultVar
    , ctx = ctx2
    }


generateTupleAccess : Context -> Mono.MonoExpr -> Int -> Bool -> ExprResult
generateTupleAccess ctx tuple index isUnboxed =
    let
        tupleResult : ExprResult
        tupleResult =
            generateExpr ctx tuple

        ( resultVar, ctx1 ) =
            freshVar tupleResult.ctx
    in
    { ops = tupleResult.ops ++ [ ecoProject ctx1 resultVar index isUnboxed tupleResult.resultVar ]
    , resultVar = resultVar
    , ctx = ctx1
    }



-- CUSTOM TYPE GENERATION


generateCustomCreate : Context -> Name.Name -> Int -> List Mono.MonoExpr -> Mono.CtorLayout -> ExprResult
generateCustomCreate ctx ctorName tag fields layout =
    let
        ( fieldsOps, fieldVars, ctx1 ) =
            generateExprList ctx fields

        ( resultVar, ctx2 ) =
            freshVar ctx1

        arity : Int
        arity =
            List.length fields
    in
    { ops = fieldsOps ++ [ ecoConstruct ctx2 resultVar tag arity layout.unboxedBitmap fieldVars ]
    , resultVar = resultVar
    , ctx = ctx2
    }



-- UNIT GENERATION


generateUnit : Context -> ExprResult
generateUnit ctx =
    let
        ( var, ctx1 ) =
            freshVar ctx
    in
    { ops = [ ecoConstruct ctx1 var 0 0 0 [] ]
    , resultVar = var
    , ctx = ctx1
    }



-- ACCESSOR GENERATION


generateAccessor : Context -> Name.Name -> ExprResult
generateAccessor ctx fieldName =
    let
        ( var, ctx1 ) =
            freshVar ctx

        papOp : MlirOp
        papOp =
            mlirOp "eco.papCreate" ctx1
                |> withResult var ecoValue
                |> withAttr "lambda_id" (StringAttr ("accessor_" ++ fieldName))
                |> withAttr "arity" (IntAttr 1)
                |> withAttr "num_captured" (IntAttr 0)
                |> build
    in
    { ops = [ papOp ]
    , resultVar = var
    , ctx = ctx1
    }



-- HELPERS


canonicalToMLIRName : IO.Canonical -> String
canonicalToMLIRName (IO.Canonical _ moduleName) =
    String.replace "." "_" moduleName


sanitizeName : String -> String
sanitizeName name =
    name
        |> String.replace "+" "_plus_"
        |> String.replace "-" "_minus_"
        |> String.replace "*" "_star_"
        |> String.replace "/" "_slash_"
        |> String.replace "<" "_lt_"
        |> String.replace ">" "_gt_"
        |> String.replace "=" "_eq_"
        |> String.replace "&" "_amp_"
        |> String.replace "|" "_pipe_"
        |> String.replace "!" "_bang_"
        |> String.replace "?" "_question_"
        |> String.replace ":" "_colon_"
        |> String.replace "." "_dot_"
        |> String.replace "$" "_dollar_"
