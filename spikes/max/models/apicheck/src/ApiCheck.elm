module ApiCheck exposing (main)

{-| End-to-end checks of round 2's API on synthetic models (plans/tensor-api-round2.md, A2), no
downloads. Flag `check`:

  - `cache`: a Llama-shaped model generates with a KV cache (`Infer`, `selfCached`) and without one
    (a padded full-context graph): the logits agree and so do the greedy tokens, for both rotary
    pairings.
  - `import`: a synthetic safetensors checkpoint in PyTorch's layouts goes from the file into
    resident buffers and through typed import graphs (one part alone, then the whole), byte for byte
    what NumPy expects; the raw buffers are then dropped.
  - `block`: a UNet-shaped block (convolutions, GroupNorm, a timestep embedding, upsampling,
    cross-attention under `vmap`) runs once with its parameters and inputs saved for a NumPy
    reference (`ref_block.py`), then trains.

Each prints `PASS` or `FAIL` lines.

-}

import Bridge
import Bytes exposing (Bytes, Endianness(..))
import Bytes.Decode as BD
import Bytes.Encode as Encode
import Checkpoint.Safetensors as Safetensors
import Dict exposing (Dict)
import Graph exposing (Graph)
import Infer
import Json.Decode as D
import Json.Encode as JE
import Nn
import Nn.Attention as Attention
import Nn.Conv2d as Conv2d exposing (Conv2d)
import Nn.Embedding as Embedding exposing (Embedding)
import Nn.FeedForward as FeedForward
import Nn.GroupNorm as GroupNorm exposing (GroupNorm)
import Nn.KvCache as KvCache
import Nn.Linear as Linear exposing (Linear)
import Nn.RmsNorm as RmsNorm exposing (RmsNorm)
import Nn.Rotary as Rotary exposing (Rotary)
import Optim
import Param
import Platform
import Signature as Sig exposing (Sig)
import Tensor as T exposing (Dim, F16, F32, Floating, I64, Integral, R0, R1, R2, R3, R4, Tensor)
import Tensor.Axis as Axis
import Train
import Transform



-- BYTES


f32s : List Float -> Bytes
f32s values =
    Encode.encode (Encode.sequence (List.map (Encode.float32 LE) values))


i64s : List Int -> Bytes
i64s values =
    Encode.encode (Encode.sequence (List.concatMap (\v -> [ Encode.unsignedInt32 LE v, Encode.unsignedInt32 LE 0 ]) values))


decodeF32s : Bytes -> List Float
decodeF32s b =
    let
        n =
            Bytes.width b // 4
    in
    BD.decode (BD.loop ( n, [] ) (\( k, acc ) -> if k == 0 then BD.succeed (BD.Done (List.reverse acc)) else BD.map (\v -> BD.Loop ( k - 1, v :: acc )) (BD.float32 LE))) b
        |> Maybe.withDefault []


byteList : Bytes -> List Int
byteList b =
    BD.decode (BD.loop ( Bytes.width b, [] ) (\( k, acc ) -> if k == 0 then BD.succeed (BD.Done (List.reverse acc)) else BD.map (\v -> BD.Loop ( k - 1, v :: acc )) BD.unsignedInt8)) b
        |> Maybe.withDefault []


{-| A run's fed outputs: after the 16-byte header, each padded to 16 bytes.
-}
outputs : List Int -> Bytes -> List (List Float)
outputs counts reply =
    let
        body =
            Bridge.payload reply

        go offset cs =
            case cs of
                n :: rest ->
                    decodeF32s (Bridge.slice offset (4 * n) body) :: go (offset + (4 * n + 15) // 16 * 16) rest

                [] ->
                    []
    in
    go 0 counts


lcg : Int -> Int
lcg s =
    modBy 4294967296 (1664525 * s + 1013904223)


{-| `n` values in [−1, 1) from `seed`.
-}
noise : Int -> Int -> List Float
noise seed n =
    List.range 1 n
        |> List.foldl (\_ ( s, acc ) -> let s1 = lcg s in ( s1, (toFloat s1 / 2147483648 - 1) :: acc )) ( seed, [] )
        |> Tuple.second
        |> List.reverse


argmax : List Float -> Int
argmax row =
    List.indexedMap Tuple.pair row
        |> List.foldl (\( i, v ) ( bi, bv ) -> if v > bv then ( i, v ) else ( bi, bv )) ( 0, -1 / 0 )
        |> Tuple.first


{-| max |a − b| / max |b|.
-}
relError : List Float -> List Float -> Float
relError a b =
    let
        diff =
            List.map2 (\x y -> abs (x - y)) a b |> List.maximum |> Maybe.withDefault 0

        scale =
            List.map abs b |> List.maximum |> Maybe.withDefault 1
    in
    diff / max scale 1.0e-30


fmt : Float -> String
fmt x =
    String.fromFloat (toFloat (round (x * 1.0e9)) / 1.0e9)



-- A2.1: A LLAMA-SHAPED MODEL, CACHED AND NOT


type Vocab
    = Vocab


type Width
    = Width


type Kv
    = Kv


type Heads
    = Heads


type KvHeads
    = KvHeads


type Head
    = Head


type Ffn
    = Ffn


type Ctx
    = Ctx


type Now
    = Now


vocab : Dim Vocab
vocab =
    T.dim Vocab 256


width : Dim Width
width =
    T.dim Width 64


kvWidth : Dim Kv
kvWidth =
    T.dim Kv 32


heads : Dim Heads
heads =
    T.dim Heads 4


kvHeads : Dim KvHeads
kvHeads =
    T.dim KvHeads 2


head : Dim Head
head =
    T.dim Head 16


ffn : Dim Ffn
ffn =
    T.dim Ffn 128


ctx : Dim Ctx
ctx =
    T.dim Ctx 32


now : Dim Now
now =
    T.dim Now 1


type alias Layer =
    { norm1 : RmsNorm F32 Width
    , attn : Attention.Grouped F32 Width Kv Heads KvHeads Head
    , norm2 : RmsNorm F32 Width
    , ff : FeedForward.Gated F32 Width Ffn
    }


type alias Llama =
    { embed : Embedding F32 Vocab Width, layers : List Layer, norm : RmsNorm F32 Width }


layerSpec : Param.Spec Layer
layerSpec =
    Param.record Layer
        |> Param.sub .norm1 (RmsNorm.params T.float32 { epsilon = 1.0e-5 } width)
        |> Param.sub .attn (Attention.groupedParams T.float32 { projectionBias = False, outBias = False } width kvWidth heads kvHeads head)
        |> Param.sub .norm2 (RmsNorm.params T.float32 { epsilon = 1.0e-5 } width)
        |> Param.sub .ff (FeedForward.gatedParams T.float32 { bias = False } width ffn)


llama : Param.Spec Llama
llama =
    Param.record Llama
        |> Param.sub .embed (Embedding.params T.float32 vocab width)
        |> Param.sub .layers (Param.list 2 layerSpec)
        |> Param.sub .norm (RmsNorm.params T.float32 { epsilon = 1.0e-5 } width)


feedForward : Layer -> Tensor Floating F32 (R2 s Width) -> Tensor Floating F32 (R2 s Width)
feedForward l h =
    h |> T.plus (h |> RmsNorm.apply l.norm2 |> FeedForward.applyGated T.silu l.ff)


fullForward : Rotary -> Llama -> Tensor Integral I64 (R1 Ctx) -> Tensor Floating F32 (R2 Ctx Vocab)
fullForward rot p tokens =
    let
        positions =
            T.iota ctx

        block l h =
            h
                |> T.plus (h |> RmsNorm.apply l.norm1 |> Attention.selfGrouped { causal = True, rotary = Just ( rot, positions ) } l.attn)
                |> feedForward l
    in
    List.foldl block (Embedding.apply p.embed tokens) p.layers
        |> RmsNorm.apply p.norm
        |> Embedding.unembed p.embed


type alias Cache =
    KvCache.Cache F32 KvHeads Ctx Head


cacheSig : Sig (List Cache)
cacheSig =
    Sig.list 2 (KvCache.sig T.float32 kvHeads ctx head)


stepForward : Rotary -> Llama -> List Cache -> ( Tensor Integral I64 (R1 Now), Tensor Integral I64 R0 ) -> ( List Cache, Tensor Floating F32 (R2 Now Vocab) )
stepForward rot p caches ( token, position ) =
    let
        layer ( l, c ) ( done, h ) =
            let
                ( c2, a ) =
                    Attention.selfCached { rotary = Just rot } l.attn position c (RmsNorm.apply l.norm1 h)
            in
            ( c2 :: done, h |> T.plus a |> feedForward l )

        ( reversed, x ) =
            List.foldl layer ( [], Embedding.apply p.embed token ) (List.map2 Tuple.pair p.layers caches)
    in
    ( List.reverse reversed, x |> RmsNorm.apply p.norm |> Embedding.unembed p.embed )


pairings : List ( String, Rotary )
pairings =
    [ ( "interleaved", { base = 10000, pairing = Rotary.Interleaved } ), ( "halves", { base = 10000, pairing = Rotary.Halves } ) ]


cacheGraphs : List ( Int, Result (List String) Graph )
cacheGraphs =
    ( 1, Param.initInPlace "init_params" llama )
        :: ( 2, Infer.initGraph "init_cache" cacheSig (List.repeat 2 { keys = T.zeros T.float32 (T.r3 kvHeads ctx head), values = T.zeros T.float32 (T.r3 kvHeads ctx head) }) )
        :: List.concat
            (List.indexedMap
                (\i ( name, rot ) ->
                    [ ( 3 + 2 * i, Infer.step ("full_" ++ name) llama Sig.unit (Sig.label "tokens" (Sig.i64 (T.r1 ctx))) (Sig.label "logits" (Sig.f32 (T.r2 ctx vocab))) (\p () tokens -> ( (), fullForward rot p tokens )) )
                    , ( 4 + 2 * i, Infer.step ("step_" ++ name) llama cacheSig (Sig.pair (Sig.label "token" (Sig.i64 (T.r1 now))) (Sig.label "position" (Sig.i64 T.scalar))) (Sig.label "logits" (Sig.f32 (T.r2 now vocab))) (stepForward rot) )
                    ]
                )
                pairings
            )


prompt : List Int
prompt =
    [ 3, 14, 15, 92, 65, 35, 89, 79 ]


generated : Int
generated =
    16



-- A2.2: IMPORT


type In
    = In


type Out
    = Out


type Cin
    = Cin


type Cout
    = Cout


type M
    = M


type Fused
    = Fused


inD : Dim In
inD =
    T.dim In 4


outD : Dim Out
outD =
    T.dim Out 5


cin : Dim Cin
cin =
    T.dim Cin 3


cout : Dim Cout
cout =
    T.dim Cout 6


mD : Dim M
mD =
    T.dim M 8


fused : Dim Fused
fused =
    T.dim Fused 24


type alias Qkv =
    { q : Linear F32 M M, k : Linear F32 M M, v : Linear F32 M M }


type alias Imported =
    { lin : Linear F32 In Out, conv : Conv2d F32 Cin Cout, qkv : Qkv, half : Linear F32 In Out }


qkvSpec : Param.Spec Qkv
qkvSpec =
    Param.named "qkv"
        (Param.record Qkv
            |> Param.sub .q (Linear.params T.float32 mD mD)
            |> Param.sub .k (Linear.params T.float32 mD mD)
            |> Param.sub .v (Linear.params T.float32 mD mD)
        )


importedSpec : Param.Spec Imported
importedSpec =
    Param.record Imported
        |> Param.sub .lin (Linear.params T.float32 inD outD)
        |> Param.sub .conv (Conv2d.params T.float32 { kernel = ( 3, 3 ) } cin cout)
        |> Param.sub .qkv qkvSpec
        |> Param.sub .half (Param.named "half" (Linear.paramsWithoutBias T.float32 inD outD))


type alias RawQkv =
    { w : Tensor Floating F32 (R2 Fused M), b : Tensor Floating F32 (R1 Fused) }


type alias Raw =
    { linW : Tensor Floating F32 (R2 Out In)
    , linB : Tensor Floating F32 (R1 Out)
    , convW : Tensor Floating F32 (R4 Cout Cin Conv2d.KernelH Conv2d.KernelW)
    , convB : Tensor Floating F32 (R1 Cout)
    , qkv : RawQkv
    , half : Tensor Floating F16 (R2 Out In)
    }


rawQkvSig : Sig RawQkv
rawQkvSig =
    Sig.record RawQkv
        |> Sig.field .w (Sig.label "raw.qkv.weight" (Sig.f32 (T.r2 fused mD)))
        |> Sig.field .b (Sig.label "raw.qkv.bias" (Sig.f32 (T.r1 fused)))


rawSig : Sig Raw
rawSig =
    let
        ( kh, kw ) =
            Conv2d.kernel ( 3, 3 )
    in
    Sig.record Raw
        |> Sig.field .linW (Sig.label "raw.lin.weight" (Sig.f32 (T.r2 outD inD)))
        |> Sig.field .linB (Sig.label "raw.lin.bias" (Sig.f32 (T.r1 outD)))
        |> Sig.field .convW (Sig.label "raw.conv.weight" (Sig.f32 (T.r4 cout cin kh kw)))
        |> Sig.field .convB (Sig.label "raw.conv.bias" (Sig.f32 (T.r1 cout)))
        |> Sig.field .qkv rawQkvSig
        |> Sig.field .half (Sig.label "raw.half.weight" (Sig.tensor T.float16 (T.r2 outD inD)))


{-| PyTorch's fused [3m, m] projection: transposed to [m, 3m], split into three.
-}
convertQkv : RawQkv -> Qkv
convertQkv r =
    let
        w =
            T.transpose r.w

        part i =
            { weight = T.slice Axis.retag1of2 (8 * i) mD w, bias = T.slice Axis.retag0of1 (8 * i) mD r.b }
    in
    { q = part 0, k = part 1, v = part 2 }


convert : Raw -> Imported
convert r =
    { lin = { weight = T.transpose r.linW, bias = r.linB }
    , conv =
        -- OIHW to RSCF (kernel h, kernel w, in, out)
        { filter = r.convW |> T.permute Axis.swap03of4 |> T.permute Axis.swap02of4 |> T.permute Axis.swap12of4
        , bias = r.convB
        }
    , qkv = convertQkv r.qkv
    , half = { weight = T.cast T.float32 (T.transpose r.half), bias = T.zeros T.float32 (T.r1 outD) }
    }


importGraphs : List ( Int, Result (List String) Graph )
importGraphs =
    [ ( 11, Param.importGraph "import_qkv" qkvSpec rawQkvSig convertQkv )
    , ( 12, Param.importGraph "import_all" importedSpec rawSig convert )
    ]



-- A2.3: A UNET-SHAPED BLOCK


type Batch
    = Batch


type H
    = H


type W
    = W


type H2
    = H2


type W2
    = W2


type Ch
    = Ch


type Emb
    = Emb


type Mem
    = Mem


type MemW
    = MemW


type Heads2
    = Heads2


type Head8
    = Head8


type Pos
    = Pos


batch : Dim Batch
batch =
    T.dim Batch 2


hD : Dim H
hD =
    T.dim H 8


wD : Dim W
wD =
    T.dim W 8


h2D : Dim H2
h2D =
    T.dim H2 16


w2D : Dim W2
w2D =
    T.dim W2 16


ch : Dim Ch
ch =
    T.dim Ch 16


emb : Dim Emb
emb =
    T.dim Emb 16


mem : Dim Mem
mem =
    T.dim Mem 6


memW : Dim MemW
memW =
    T.dim MemW 24


pos : Dim Pos
pos =
    T.dim Pos 256


type alias Block =
    { conv1 : Conv2d F32 Ch Ch
    , norm : GroupNorm F32 Ch
    , time : Linear F32 Emb Ch
    , conv2 : Conv2d F32 Ch Ch
    , cross : Attention.Cross F32 Ch MemW Heads2 Head8
    , conv3 : Conv2d F32 Ch Ch
    }


blockSpec : Param.Spec Block
blockSpec =
    Param.record Block
        |> Param.sub .conv1 (Conv2d.params T.float32 { kernel = ( 3, 3 ) } ch ch)
        |> Param.sub .norm (GroupNorm.params T.float32 { groups = 4, epsilon = 1.0e-5 } ch)
        |> Param.sub .time (Linear.params T.float32 emb ch)
        |> Param.sub .conv2 (Conv2d.params T.float32 { kernel = ( 3, 3 ) } ch ch)
        |> Param.sub .cross (Attention.crossParams T.float32 { projectionBias = False, outBias = True } ch memW (T.dim Heads2 2) (T.dim Head8 8))
        |> Param.sub .conv3 (Conv2d.params T.float32 { kernel = ( 1, 1 ) } ch ch)


type alias BlockIn =
    { x : Tensor Floating F32 (R4 Batch H W Ch), t : Tensor Floating F32 (R1 Batch), memory : Tensor Floating F32 (R2 Mem MemW) }


blockInSig : Sig BlockIn
blockInSig =
    Sig.record BlockIn
        |> Sig.field .x (Sig.label "x" (Sig.f32 (T.r4 batch hD wD ch)))
        |> Sig.field .t (Sig.label "t" (Sig.f32 (T.r1 batch)))
        |> Sig.field .memory (Sig.label "memory" (Sig.f32 (T.r2 mem memW)))


blockForward : Block -> BlockIn -> Tensor Floating F32 (R4 Batch H2 W2 Ch)
blockForward p i =
    let
        time =
            i.t
                |> Nn.timestepEmbedding { maxPeriod = 10000, cosFirst = True, shift = 0 } emb
                |> Linear.apply p.time
                |> T.broadcast Axis.axis1of3
                |> T.broadcast Axis.axis2of4

        h3 =
            i.x
                |> Conv2d.applySame p.conv1
                |> GroupNorm.apply p.norm
                |> T.silu
                |> T.plus time
                |> Conv2d.applySame p.conv2
                |> Nn.upsampleNearest2d 2 h2D w2D

        attended =
            h3
                |> T.reshape (T.r3 batch pos ch)
                |> Transform.vmap Axis.liftRank2 Axis.liftRank2 (Attention.attendTo p.cross i.memory)
                |> T.reshape (T.r4 batch h2D w2D ch)
    in
    attended |> T.plus h3 |> Conv2d.applySame p.conv3


blockOptim : Optim.Optimizer
blockOptim =
    Optim.adamW 3.0e-3


blockGraphs : List ( Int, Result (List String) Graph )
blockGraphs =
    [ ( 21, Param.initInPlace "init_block" blockSpec )
    , ( 23, Infer.step "block" blockSpec Sig.unit blockInSig (Sig.label "y" (Sig.f32 (T.r4 batch h2D w2D ch))) (\p () i -> ( (), blockForward p i )) )
    , ( 24, Train.step blockSpec blockOptim blockInSig (\p i -> blockForward p i |> Nn.mseLoss (T.zeros T.float32 (T.r4 batch h2D w2D ch))) )
    ]


blockInputs : List Bytes
blockInputs =
    [ f32s (noise 11 (2 * 8 * 8 * 16)), f32s [ 10, 500 ], f32s (noise 12 (6 * 24)) ]


trainSteps : Int
trainSteps =
    40



-- PROGRAM


type alias Model =
    { check : String
    , dir : String
    , pending : Int
    , failed : Bool

    -- cache
    , pairing : Int
    , fed : List Int
    , stepLogits : List (List Float)

    -- import
    , headerLength : Int
    , entries : List Safetensors.Entry
    , expected : Dict String (List Int)
    , got : Dict Int (List Int)
    , gets : Dict Int String

    -- block
    , losses : List Float
    }


type Msg
    = Compiled D.Value
    | Ran Bytes
    | Loaded Bytes
    | Got Bytes


graphsFor : String -> List ( Int, Result (List String) Graph )
graphsFor check =
    case check of
        "cache" ->
            cacheGraphs

        "import" ->
            importGraphs

        _ ->
            blockGraphs


expectedNames : List String
expectedNames =
    Param.names importedSpec


init : D.Value -> ( Model, Cmd Msg )
init flags =
    let
        check =
            D.decodeValue (D.field "check" D.string) flags |> Result.withDefault "cache"

        dir =
            D.decodeValue (D.field "dir" D.string) flags |> Result.withDefault "."

        graphs =
            graphsFor check

        errors =
            List.concatMap
                (\( _, r ) ->
                    case r of
                        Err e ->
                            e

                        Ok _ ->
                            []
                )
                graphs

        compiles =
            List.filterMap (\( id, r ) -> Result.toMaybe r |> Maybe.map (\g -> Tuple.first (Bridge.compile Bridge.Bytecode id g))) graphs

        model =
            { check = check
            , dir = dir
            , pending = List.length graphs
            , failed = False
            , pairing = 0
            , fed = []
            , stepLogits = []
            , headerLength = 0
            , entries = []
            , expected = Dict.empty
            , got = Dict.empty
            , gets = Dict.empty
            , losses = []
            }

        extra =
            if check == "import" then
                Bridge.send [ Bridge.loadRange 1 (dir ++ "/synthetic.safetensors") 0 8 ]
                    :: List.indexedMap (\i n -> Bridge.load (200 + i) (dir ++ "/expected/" ++ n ++ ".bin")) expectedNames

            else
                []
    in
    if List.isEmpty errors then
        ( { model | pending = model.pending + List.length extra }, Cmd.batch (Bridge.log ("apicheck " ++ check) :: compiles ++ extra) )

    else
        ( model, Cmd.batch [ Bridge.log ("FAIL graphs: " ++ String.join "; " errors), Bridge.done 1 ] )


report : Bool -> String -> Model -> ( Model, Cmd Msg )
report ok text model =
    ( { model | failed = model.failed || not ok }
    , Bridge.log
        ((if ok then
            "PASS "

          else
            "FAIL "
         )
            ++ text
        )
    )


finish : Model -> List (Cmd Msg) -> ( Model, Cmd Msg )
finish model cmds =
    ( model
    , Cmd.batch
        (cmds
            ++ [ Bridge.done
                    (if model.failed then
                        1

                     else
                        0
                    )
               ]
        )
    )


{-| Everything compiled (and, for `import`, the header and expected files loaded): start.
-}
start : Model -> ( Model, Cmd Msg )
start model =
    case model.check of
        "cache" ->
            ( { model | fed = List.take 1 prompt }, Bridge.send [ Bridge.run 1 [ Bridge.packed (i64s [ 7 ]) ], Bridge.run 2 [], stepRun model 0 (List.head prompt |> Maybe.withDefault 0) ] )

        "import" ->
            startImport model

        _ ->
            let
                residentNames =
                    Param.names blockSpec

                state =
                    Train.initial blockSpec blockOptim 1 |> List.filter (\( n, _ ) -> not (List.member n residentNames))

                saves =
                    List.map (\n -> Bridge.save n (model.dir ++ "/block/" ++ n ++ ".bin")) residentNames
            in
            ( model
            , Bridge.send
                (Bridge.run 21 [ Bridge.packed (i64s [ 5 ]) ]
                    :: List.map (\( n, b ) -> Bridge.put n b) state
                    ++ saves
                    ++ [ Bridge.run 23 (List.map Bridge.packed blockInputs) ]
                )
            )


stepRun : Model -> Int -> Int -> Bridge.Command
stepRun model position token =
    Bridge.run (4 + 2 * model.pairing) [ Bridge.packed (i64s [ token ]), Bridge.packed (i64s [ position ]) ]


update : Msg -> Model -> ( Model, Cmd Msg )
update msg model =
    case msg of
        Compiled v ->
            case D.decodeValue (D.field "ok" D.bool) v of
                Ok True ->
                    ready { model | pending = model.pending - 1 }

                _ ->
                    finish { model | failed = True } [ Bridge.log "FAIL compile" ]

        Loaded bytes ->
            loaded (Bridge.headerId bytes) (Bridge.payload bytes) model

        Got bytes ->
            got (Bridge.headerId bytes) (Bridge.payload bytes) model

        Ran bytes ->
            ran (Bridge.headerId bytes) bytes model


ready : Model -> ( Model, Cmd Msg )
ready model =
    if model.pending == 0 then
        start model

    else
        ( model, Cmd.none )



-- CACHE


ran : Int -> Bytes -> Model -> ( Model, Cmd Msg )
ran id reply model =
    case model.check of
        "cache" ->
            ranCache id reply model

        "import" ->
            ( model, Cmd.none )

        _ ->
            ranBlock id reply model


ranCache : Int -> Bytes -> Model -> ( Model, Cmd Msg )
ranCache id reply model =
    let
        name =
            List.drop model.pairing pairings |> List.head |> Maybe.map Tuple.first |> Maybe.withDefault "?"
    in
    if id == 4 + 2 * model.pairing then
        let
            row =
                outputs [ 256 ] reply |> List.head |> Maybe.withDefault []

            position =
                List.length model.stepLogits

            m =
                { model | stepLogits = model.stepLogits ++ [ row ] }

            -- the prompt's next token, then the most likely one
            next =
                if position + 1 < List.length prompt then
                    List.drop (position + 1) prompt |> List.head |> Maybe.withDefault 0

                else
                    argmax row
        in
        if position + 1 < generated then
            ( { m | fed = m.fed ++ [ next ] }, Bridge.send [ stepRun m (position + 1) next ] )

        else
            ( m, Bridge.send [ Bridge.run (3 + 2 * model.pairing) [ Bridge.packed (i64s (m.fed ++ List.repeat (32 - List.length m.fed) 0)) ] ] )

    else if id == 3 + 2 * model.pairing then
        let
            full =
                outputs [ 32 * 256 ] reply |> List.head |> Maybe.withDefault []

            rows =
                List.range 0 (generated - 1) |> List.map (\p -> List.take 256 (List.drop (256 * p) full))

            errors =
                List.map2 relError model.stepLogits rows

            worst =
                List.maximum errors |> Maybe.withDefault 1

            greedyFull =
                List.map argmax (List.drop (List.length prompt - 1) (List.take (generated - 1) rows))

            greedyCached =
                List.drop (List.length prompt) model.fed

            ( m1, c1 ) =
                report (worst <= 1.0e-4 && List.length errors == generated) (name ++ ": cached and full logits at " ++ String.fromInt (List.length errors) ++ " positions, max |Δ| / max |ref| = " ++ fmt worst) model

            ( m2, c2 ) =
                report (greedyFull == greedyCached) (name ++ ": greedy tokens " ++ String.join " " (List.map String.fromInt greedyCached) ++ " (full: " ++ String.join " " (List.map String.fromInt greedyFull) ++ ")") m1
        in
        if model.pairing + 1 < List.length pairings then
            let
                m3 =
                    { m2 | pairing = model.pairing + 1, fed = List.take 1 prompt, stepLogits = [] }
            in
            ( m3, Cmd.batch [ c1, c2, Bridge.send [ Bridge.run 2 [], stepRun m3 0 (List.head prompt |> Maybe.withDefault 0) ] ] )

        else
            finish m2 [ c1, c2 ]

    else
        ( model, Cmd.none )



-- IMPORT


loaded : Int -> Bytes -> Model -> ( Model, Cmd Msg )
loaded id bytes model =
    if id == 1 then
        case Safetensors.headerLength bytes of
            Just n ->
                ( { model | headerLength = n }, Bridge.send [ Bridge.loadRange 2 (model.dir ++ "/synthetic.safetensors") 8 n ] )

            Nothing ->
                finish { model | failed = True } [ Bridge.log "FAIL header length" ]

    else if id == 2 then
        case Safetensors.parse bytes of
            Ok entries ->
                ready { model | entries = entries, pending = model.pending - 1 }

            Err e ->
                finish { model | failed = True } [ Bridge.log ("FAIL parse: " ++ e) ]

    else if id >= 200 then
        let
            name =
                List.drop (id - 200) expectedNames |> List.head |> Maybe.withDefault "?"
        in
        ready { model | expected = Dict.insert name (byteList bytes) model.expected, pending = model.pending - 1 }

    else
        ( model, Cmd.none )


got : Int -> Bytes -> Model -> ( Model, Cmd Msg )
got id bytes model =
    let
        m =
            { model | got = Dict.insert id (byteList bytes) model.got }
    in
    if Dict.size m.got < Dict.size m.gets then
        ( m, Cmd.none )

    else
        let
            check lo hi =
                Dict.toList m.gets
                    |> List.filter (\( i, _ ) -> i >= lo && i < hi)
                    |> List.map (\( i, n ) -> ( n, Dict.get i m.got == Dict.get n m.expected && Dict.get n m.expected /= Nothing ))

            failures results =
                List.filter (not << Tuple.second) results |> List.map Tuple.first

            part =
                check 100 120

            whole =
                check 120 199

            ( m1, c1 ) =
                report (List.isEmpty (failures part)) ("import of the named part qkv alone: " ++ String.fromInt (List.length part) ++ " parameters byte-identical to NumPy's" ++ failureList (failures part)) m

            ( m2, c2 ) =
                report (List.isEmpty (failures whole)) ("import of the whole: " ++ String.fromInt (List.length whole) ++ " parameters byte-identical to NumPy's" ++ failureList (failures whole)) m1

            ( m3, c3 ) =
                report (Dict.get 199 m.got == Just []) "raw buffers dropped (get of a dropped name answers nothing)" m2
        in
        finish m3 [ c1, c2, c3 ]


failureList : List String -> String
failureList names =
    if List.isEmpty names then
        ""

    else
        "; differ: " ++ String.join ", " names



-- BLOCK


ranBlock : Int -> Bytes -> Model -> ( Model, Cmd Msg )
ranBlock id reply model =
    if id == 23 then
        let
            y =
                outputs [ 2 * 16 * 16 * 16 ] reply |> List.head |> Maybe.withDefault []

            manifest =
                JE.encode 0
                    (JE.object
                        [ ( "params", JE.list JE.string (Param.names blockSpec) )
                        , ( "inputs", JE.list JE.string [ "x", "t", "memory" ] )
                        ]
                    )

            putSave name bytes =
                [ Bridge.put name bytes, Bridge.save name (model.dir ++ "/block/" ++ name ++ ".bin") ]

            files =
                List.concat
                    (List.map2 putSave [ "in.x", "in.t", "in.memory" ] blockInputs
                        ++ [ putSave "out.y" (f32s y)
                           , [ Bridge.put "manifest" (Encode.encode (Encode.string manifest)), Bridge.save "manifest" (model.dir ++ "/block/manifest.json") ]
                           ]
                    )
        in
        ( model, Cmd.batch [ Bridge.log ("block output: " ++ String.fromInt (List.length y) ++ " values, saved for ref_block.py"), Bridge.send (files ++ [ Bridge.run 24 (List.map Bridge.packed blockInputs) ]) ] )

    else if id == 24 then
        let
            losses =
                model.losses ++ [ Train.loss reply ]

            m =
                { model | losses = losses }
        in
        if List.length losses < trainSteps then
            ( m, Bridge.send [ Bridge.run 24 (List.map Bridge.packed blockInputs) ] )

        else
            let
                mean l =
                    List.sum l / toFloat (max 1 (List.length l))

                first =
                    mean (List.take 5 losses)

                last =
                    mean (List.drop (trainSteps - 5) losses)

                ( m1, c1 ) =
                    report (last < first / 2) ("block trains: mean loss of the first 5 steps " ++ fmt first ++ ", of the last 5 " ++ fmt last) m
            in
            finish m1 [ c1 ]

    else
        ( model, Cmd.none )


main : Program D.Value Model Msg
main =
    Platform.worker
        { init = init
        , update = update
        , subscriptions = \_ -> Sub.batch [ Bridge.compiledIn Compiled, Bridge.runIn Ran, Bridge.loadIn Loaded, Bridge.getIn Got ]
        }


{-| The graphs compiled, the header parsed, the expected parameters loaded: every raw tensor into a
resident buffer, the part's import and its parameters, the whole import and its parameters, then
the raw buffers dropped.
-}
startImport : Model -> ( Model, Cmd Msg )
startImport model =
    let
        path =
            model.dir ++ "/synthetic.safetensors"

        qkvNames =
            Param.names qkvSpec

        gets =
            Dict.fromList
                (List.indexedMap (\i n -> ( 100 + i, n )) qkvNames
                    ++ List.indexedMap (\i n -> ( 120 + i, n )) expectedNames
                    ++ [ ( 199, "raw.lin.weight" ) ]
                )

        getCommands lo names =
            List.indexedMap (\i n -> Bridge.get (lo + i) n) names
    in
    ( { model | gets = gets }
    , Cmd.batch
        [ Bridge.log ("checkpoint: " ++ String.join ", " (List.map (\e -> e.name ++ " " ++ e.dtype ++ " [" ++ String.join "," (List.map String.fromInt e.shape) ++ "]") model.entries))
        , Bridge.send
            (Safetensors.loadAll path (Safetensors.dataStart model.headerLength) (\e -> "raw." ++ e.name) model.entries
                ++ [ Bridge.run 11 [] ]
                ++ getCommands 100 qkvNames
                ++ [ Bridge.run 12 [] ]
                ++ getCommands 120 expectedNames
                ++ List.map (\e -> Bridge.drop ("raw." ++ e.name)) model.entries
                ++ [ Bridge.get 199 "raw.lin.weight" ]
            )
        ]
    )
