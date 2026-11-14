port module ApiCheck exposing (main)

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
  - `int64`: integer constants beyond 2⁵³ (si64 ±(2⁶² + 1), the most negative and most positive
    i64; u64 2⁶⁴ − 1 and 2⁶³) go through MAX and come back exactly (plans/tensor-eval-in-elm.md,
    V0).

Each prints `PASS` or `FAIL` lines.

-}

import Bitwise
import Bytes exposing (Bytes, Endianness(..))
import Bytes.Decode as BD
import Bytes.Encode as Encode
import Dict exposing (Dict)
import Graph exposing (Graph)
import Infer
import Json.Decode as D
import Json.Encode as JE
import Max.Safetensors as Safetensors
import Max.Session as Session exposing (Event(..), Session)
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
import Tensor as T exposing (Dim, F16, F32, I64, R0, R1, R2, R3, R4, Tensor)
import Tensor.Axis as Axis
import Train
import Transform


port maxOut : Bytes -> Cmd msg


port maxIn : (Bytes -> msg) -> Sub msg


port logOut : String -> Cmd msg



-- BYTES


f32s : List Float -> Bytes
f32s values =
    Encode.encode (Encode.sequence (List.map (Encode.float32 LE) values))


byteList : Bytes -> List Int
byteList b =
    BD.decode (BD.loop ( Bytes.width b, [] ) (\( k, acc ) -> if k == 0 then BD.succeed (BD.Done (List.reverse acc)) else BD.map (\v -> BD.Loop ( k - 1, v :: acc )) BD.unsignedInt8)) b
        |> Maybe.withDefault []


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


feedForward : Layer -> Tensor Float F32 (R2 s Width) -> Tensor Float F32 (R2 s Width)
feedForward l h =
    h |> T.plus (h |> RmsNorm.apply l.norm2 |> FeedForward.applyGated T.silu l.ff)


fullForward : Rotary -> Llama -> Tensor Int I64 (R1 Ctx) -> Tensor Float F32 (R2 Ctx Vocab)
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


stepForward : Rotary -> Llama -> List Cache -> ( Tensor Int I64 (R1 Now), Tensor Int I64 R0 ) -> ( List Cache, Tensor Float F32 (R2 Now Vocab) )
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


{-| Each pairing's graphs are `full_` and `step_` followed by the pairing's name.
-}
cacheGraphs : List (Result (List String) Graph)
cacheGraphs =
    Param.initInPlace "init_params" llama
        :: Infer.initGraph "init_cache" cacheSig (List.repeat 2 { keys = T.zeros T.float32 (T.r3 kvHeads ctx head), values = T.zeros T.float32 (T.r3 kvHeads ctx head) })
        :: List.concatMap
            (\( name, rot ) ->
                [ Infer.step ("full_" ++ name) llama Sig.unit (Sig.label "tokens" (Sig.i64 (T.r1 ctx))) (Sig.label "logits" (Sig.f32 (T.r2 ctx vocab))) (\p () tokens -> ( (), fullForward rot p tokens ))
                , Infer.step ("step_" ++ name) llama cacheSig (Sig.pair (Sig.label "token" (Sig.i64 (T.r1 now))) (Sig.label "position" (Sig.i64 T.scalar))) (Sig.label "logits" (Sig.f32 (T.r2 now vocab))) (stepForward rot)
                ]
            )
            pairings


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
    { w : Tensor Float F32 (R2 Fused M), b : Tensor Float F32 (R1 Fused) }


type alias Raw =
    { linW : Tensor Float F32 (R2 Out In)
    , linB : Tensor Float F32 (R1 Out)
    , convW : Tensor Float F32 (R4 Cout Cin Conv2d.KernelH Conv2d.KernelW)
    , convB : Tensor Float F32 (R1 Cout)
    , qkv : RawQkv
    , half : Tensor Float F16 (R2 Out In)
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


importGraphs : List (Result (List String) Graph)
importGraphs =
    [ Param.importGraph "import_qkv" qkvSpec rawQkvSig convertQkv
    , Param.importGraph "import_all" importedSpec rawSig convert
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
    { x : Tensor Float F32 (R4 Batch H W Ch), t : Tensor Float F32 (R1 Batch), memory : Tensor Float F32 (R2 Mem MemW) }


blockInSig : Sig BlockIn
blockInSig =
    Sig.record BlockIn
        |> Sig.field .x (Sig.label "x" (Sig.f32 (T.r4 batch hD wD ch)))
        |> Sig.field .t (Sig.label "t" (Sig.f32 (T.r1 batch)))
        |> Sig.field .memory (Sig.label "memory" (Sig.f32 (T.r2 mem memW)))


blockForward : Block -> BlockIn -> Tensor Float F32 (R4 Batch H2 W2 Ch)
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


{-| `init_block`, `block` and `train_step`.
-}
blockGraphs : List (Result (List String) Graph)
blockGraphs =
    [ Param.initInPlace "init_block" blockSpec
    , Infer.step "block" blockSpec Sig.unit blockInSig (Sig.label "y" (Sig.f32 (T.r4 batch h2D w2D ch))) (\p () i -> ( (), blockForward p i ))
    , Train.step blockSpec blockOptim blockInSig (\p i -> blockForward p i |> Nn.mseLoss (T.zeros T.float32 (T.r4 batch h2D w2D ch)))
    ]


blockInputs : List Bytes
blockInputs =
    [ f32s (noise 11 (2 * 8 * 8 * 16)), f32s [ 10, 500 ], f32s (noise 12 (6 * 24)) ]


{-| `blockInputs` as the fed inputs of a graph that names them `names`: `x`, `t` and `memory` for
`block`, `batch0` .. `batch2` for `train_step`.
-}
blockFeeds : List String -> List ( String, Session.Input )
blockFeeds names =
    List.map2 (\n b -> ( n, Session.fromBytes b )) names blockInputs


trainSteps : Int
trainSteps =
    40



-- PROGRAM


type alias Model =
    { session : Session Msg
    , graphs : Dict String Session.Handle
    , check : String
    , dir : String
    , pending : Int
    , failed : Bool

    -- cache
    , pairing : Int
    , fed : List Int
    , stepLogits : List (List Float)

    -- import
    , headerLength : Maybe Int
    , entries : List Safetensors.Entry
    , expected : Dict String (List Int)
    , got : List ( String, List Int )

    -- block
    , losses : List Float
    }


type Msg
    = GotMax Session.Message


graphsFor : String -> List (Result (List String) Graph)
graphsFor check =
    case check of
        "cache" ->
            cacheGraphs

        "import" ->
            importGraphs

        "int64" ->
            int64Graphs

        _ ->
            blockGraphs


expectedNames : List String
expectedNames =
    Param.names importedSpec


checkpointPath : Model -> String
checkpointPath model =
    model.dir ++ "/synthetic.safetensors"


expectedPath : Model -> String -> String
expectedPath model name =
    model.dir ++ "/expected/" ++ name ++ ".bin"


init : D.Value -> ( Model, Cmd Msg )
init flags =
    let
        check =
            D.decodeValue (D.field "check" D.string) flags |> Result.withDefault "cache"

        graphs =
            graphsFor check

        errors =
            List.concatMap
                (\r ->
                    case r of
                        Err e ->
                            e

                        Ok _ ->
                            []
                )
                graphs

        compileOne graph ( session, known, cmds ) =
            let
                ( s, h, cmd ) =
                    Session.compile graph session
            in
            ( s, Dict.insert (Graph.name graph) h known, cmd :: cmds )

        ( compiled, handles, compiles ) =
            List.foldl compileOne ( Session.host { send = maxOut, receive = maxIn } GotMax, Dict.empty, [] ) (List.filterMap Result.toMaybe graphs)

        model =
            { session = compiled
            , graphs = handles
            , check = check
            , dir = D.decodeValue (D.field "dir" D.string) flags |> Result.withDefault "."
            , pending = List.length graphs
            , failed = False
            , pairing = 0
            , fed = []
            , stepLogits = []
            , headerLength = Nothing
            , entries = []
            , expected = Dict.empty
            , got = []
            , losses = []
            }

        -- for `import`: the checkpoint's header and the parameters NumPy expects
        reads =
            if check == "import" then
                Safetensors.readLength (checkpointPath model) :: List.map (expectedPath model >> Session.load) expectedNames

            else
                []

        ( m, readCmd ) =
            send reads { model | pending = model.pending + List.length reads }
    in
    if List.isEmpty errors then
        ( m, Cmd.batch (logOut ("apicheck " ++ check) :: List.reverse compiles ++ [ readCmd ]) )

    else
        finish { model | failed = True } [ logOut ("FAIL graphs: " ++ String.join "; " errors) ]


send : List Session.Command -> Model -> ( Model, Cmd Msg )
send commands model =
    let
        ( session, cmd ) =
            Session.send commands model.session
    in
    ( { model | session = session }, cmd )


{-| The command that runs the graph named `graph`, compiled in `init`.
-}
run : String -> List ( String, Session.Input ) -> Model -> List Session.Command
run graph inputs model =
    case Dict.get graph model.graphs of
        Just h ->
            [ Session.run h inputs ]

        Nothing ->
            []


graphName : Session.Handle -> Model -> String
graphName h model =
    Dict.toList model.graphs |> List.filter (\( _, x ) -> x == h) |> List.map Tuple.first |> List.head |> Maybe.withDefault ""


report : Bool -> String -> Model -> ( Model, Cmd Msg )
report ok text model =
    ( { model | failed = model.failed || not ok }
    , logOut
        ((if ok then
            "PASS "

          else
            "FAIL "
         )
            ++ text
        )
    )


{-| Runs `cmds`, then ends the program: exit code 1 if anything failed.
-}
finish : Model -> List (Cmd Msg) -> ( Model, Cmd Msg )
finish model cmds =
    let
        ( m, cmd ) =
            send
                [ Session.finish
                    (if model.failed then
                        1

                     else
                        0
                    )
                ]
                model
    in
    ( m, Cmd.batch (cmds ++ [ cmd ]) )


{-| Everything compiled (and, for `import`, the header and expected files loaded): start.
-}
start : Model -> ( Model, Cmd Msg )
start model =
    case model.check of
        "cache" ->
            let
                m =
                    { model | fed = List.take 1 prompt }
            in
            send (run "init_params" [ ( "seed", Session.fromInts [ 7 ] ) ] m ++ run "init_cache" [] m ++ stepRun m 0 (List.head prompt |> Maybe.withDefault 0)) m

        "import" ->
            startImport model

        "int64" ->
            send (run "int64" [] model) model

        _ ->
            let
                residentNames =
                    Param.names blockSpec

                state =
                    Train.initial blockSpec blockOptim 1 |> List.filter (\( n, _ ) -> not (List.member n residentNames))

                saves =
                    List.map (\n -> Session.save n (model.dir ++ "/block/" ++ n ++ ".bin")) residentNames
            in
            send
                (run "init_block" [ ( "seed", Session.fromInts [ 5 ] ) ] model
                    ++ List.map (\( n, b ) -> Session.put n b) state
                    ++ saves
                    ++ run "block" (blockFeeds [ "x", "t", "memory" ]) model
                )
                model


pairingName : Model -> String
pairingName model =
    List.drop model.pairing pairings |> List.head |> Maybe.map Tuple.first |> Maybe.withDefault "?"


stepRun : Model -> Int -> Int -> List Session.Command
stepRun model position token =
    run ("step_" ++ pairingName model) [ ( "token", Session.fromInts [ token ] ), ( "position", Session.fromInts [ position ] ) ] model


update : Msg -> Model -> ( Model, Cmd Msg )
update (GotMax message) model0 =
    let
        ( session, event ) =
            Session.update message model0.session

        model =
            { model0 | session = session }
    in
    case event of
        Compiled _ ->
            ready { model | pending = model.pending - 1 }

        CompileFailed h _ ->
            finish { model | failed = True } [ logOut ("FAIL compile of " ++ graphName h model) ]

        Loaded path bytes ->
            loaded path bytes model

        Got name bytes ->
            got name bytes model

        Ran h outputs ->
            ran (graphName h model) outputs model

        Failed why ->
            finish { model | failed = True } [ logOut ("FAIL " ++ why) ]

        Finished _ ->
            ( model, Cmd.none )


ready : Model -> ( Model, Cmd Msg )
ready model =
    if model.pending == 0 then
        start model

    else
        ( model, Cmd.none )


{-| The first output named `name`, as floats.
-}
floats : String -> Session.Outputs -> List Float
floats name outputs =
    Session.floats name outputs |> Maybe.withDefault []



-- CACHE


ran : String -> Session.Outputs -> Model -> ( Model, Cmd Msg )
ran graph outputs model =
    case model.check of
        "cache" ->
            ranCache graph outputs model

        "import" ->
            ( model, Cmd.none )

        "int64" ->
            ranInt64 graph outputs model

        _ ->
            ranBlock graph outputs model


ranCache : String -> Session.Outputs -> Model -> ( Model, Cmd Msg )
ranCache graph outputs model =
    let
        name =
            pairingName model
    in
    if graph == "step_" ++ name then
        let
            row =
                floats "logits" outputs

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
            let
                m2 =
                    { m | fed = m.fed ++ [ next ] }
            in
            send (stepRun m2 (position + 1) next) m2

        else
            send (run ("full_" ++ name) [ ( "tokens", Session.fromInts (m.fed ++ List.repeat (32 - List.length m.fed) 0) ) ] m) m

    else if graph == "full_" ++ name then
        let
            full =
                floats "logits" outputs

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

                ( m4, c3 ) =
                    send (run "init_cache" [] m3 ++ stepRun m3 0 (List.head prompt |> Maybe.withDefault 0)) m3
            in
            ( m4, Cmd.batch [ c1, c2, c3 ] )

        else
            finish m2 [ c1, c2 ]

    else
        ( model, Cmd.none )



-- IMPORT


{-| The checkpoint's header length and header, which come in that order, or one of the parameters
NumPy expects.
-}
loaded : String -> Bytes -> Model -> ( Model, Cmd Msg )
loaded path bytes model =
    if path == checkpointPath model then
        case model.headerLength of
            Nothing ->
                case Safetensors.headerLength bytes of
                    Just n ->
                        send [ Safetensors.readHeader path n ] { model | headerLength = Just n }

                    Nothing ->
                        finish { model | failed = True } [ logOut "FAIL header length" ]

            Just _ ->
                case Safetensors.parse bytes of
                    Ok entries ->
                        ready { model | entries = entries, pending = model.pending - 1 }

                    Err e ->
                        finish { model | failed = True } [ logOut ("FAIL parse: " ++ e) ]

    else
        case List.filter (\n -> expectedPath model n == path) expectedNames of
            name :: _ ->
                ready { model | expected = Dict.insert name (byteList bytes) model.expected, pending = model.pending - 1 }

            [] ->
                ( model, Cmd.none )


{-| The graphs compiled, the header parsed, the expected parameters loaded: every raw tensor into a
resident buffer, the part's import and its parameters, the whole import and its parameters, then
the raw buffers dropped and one of them asked for.
-}
startImport : Model -> ( Model, Cmd Msg )
startImport model =
    let
        path =
            checkpointPath model

        ( m, cmd ) =
            send
                (Safetensors.loadAll path (Safetensors.dataStart (Maybe.withDefault 0 model.headerLength)) (\e -> "raw." ++ e.name) model.entries
                    ++ run "import_qkv" [] model
                    ++ List.map Session.get (Param.names qkvSpec)
                    ++ run "import_all" [] model
                    ++ List.map Session.get expectedNames
                    ++ List.map (\e -> Session.drop ("raw." ++ e.name)) model.entries
                    ++ [ Session.get "raw.lin.weight" ]
                )
                model
    in
    ( m
    , Cmd.batch
        [ logOut ("checkpoint: " ++ String.join ", " (List.map (\e -> e.name ++ " " ++ e.dtype ++ " [" ++ String.join "," (List.map String.fromInt e.shape) ++ "]") model.entries))
        , cmd
        ]
    )


{-| The buffers `startImport` asked for, in the order it asked: the part's parameters, the whole's,
then the dropped raw buffer.
-}
got : String -> Bytes -> Model -> ( Model, Cmd Msg )
got name bytes model =
    let
        m =
            { model | got = model.got ++ [ ( name, byteList bytes ) ] }

        partCount =
            List.length (Param.names qkvSpec)

        wholeCount =
            List.length expectedNames
    in
    if List.length m.got < partCount + wholeCount + 1 then
        ( m, Cmd.none )

    else
        let
            check results =
                List.map (\( n, b ) -> ( n, Dict.get n m.expected == Just b )) results

            failures results =
                List.filter (not << Tuple.second) results |> List.map Tuple.first

            part =
                check (List.take partCount m.got)

            whole =
                check (List.take wholeCount (List.drop partCount m.got))

            ( m1, c1 ) =
                report (List.isEmpty (failures part)) ("import of the named part qkv alone: " ++ String.fromInt (List.length part) ++ " parameters byte-identical to NumPy's" ++ failureList (failures part)) m

            ( m2, c2 ) =
                report (List.isEmpty (failures whole)) ("import of the whole: " ++ String.fromInt (List.length whole) ++ " parameters byte-identical to NumPy's" ++ failureList (failures whole)) m1

            ( m3, c3 ) =
                report (List.drop (partCount + wholeCount) m.got == [ ( "raw.lin.weight", [] ) ]) "raw buffers dropped (get of a dropped name answers nothing)" m2
        in
        finish m3 [ c1, c2, c3 ]


failureList : List String -> String
failureList names =
    if List.isEmpty names then
        ""

    else
        "; differ: " ++ String.join ", " names



-- BLOCK


ranBlock : String -> Session.Outputs -> Model -> ( Model, Cmd Msg )
ranBlock graph outputs model =
    if graph == "block" then
        let
            y =
                floats "y" outputs

            manifest =
                JE.encode 0
                    (JE.object
                        [ ( "params", JE.list JE.string (Param.names blockSpec) )
                        , ( "inputs", JE.list JE.string [ "x", "t", "memory" ] )
                        ]
                    )

            putSave name bytes =
                [ Session.put name bytes, Session.save name (model.dir ++ "/block/" ++ name ++ ".bin") ]

            files =
                List.concat
                    (List.map2 putSave [ "in.x", "in.t", "in.memory" ] blockInputs
                        ++ [ putSave "out.y" (f32s y)
                           , [ Session.put "manifest" (Encode.encode (Encode.string manifest)), Session.save "manifest" (model.dir ++ "/block/manifest.json") ]
                           ]
                    )

            ( m, cmd ) =
                send (files ++ run "train_step" (blockFeeds [ "batch0", "batch1", "batch2" ]) model) model
        in
        ( m, Cmd.batch [ logOut ("block output: " ++ String.fromInt (List.length y) ++ " values, saved for ref_block.py"), cmd ] )

    else if graph == "train_step" then
        let
            losses =
                model.losses ++ [ floats "loss" outputs |> List.head |> Maybe.withDefault 0 ]

            m =
                { model | losses = losses }
        in
        if List.length losses < trainSteps then
            send (run "train_step" (blockFeeds [ "batch0", "batch1", "batch2" ]) m) m

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
        , subscriptions = \model -> Session.subscriptions model.session
        }



-- INT64


type Two
    = Two


type Four
    = Four


{-| Built at run time: no literal beyond 2⁵³ may appear in the source (eco's front end runs under
Node and refuses it).
-}
signedValues : List Int
signedValues =
    let
        big =
            Bitwise.shiftLeftBy 62 1 + 1

        minInt =
            Bitwise.shiftLeftBy 63 1
    in
    [ big, negate big, minInt, minInt - 1 ]


unsignedValues : List Int
unsignedValues =
    [ -1, Bitwise.shiftLeftBy 63 1 ]


int64Graphs : List (Result (List String) Graph)
int64Graphs =
    [ Graph.build "int64"
        Sig.unit
        (Sig.pair (Sig.i64 (T.r1 (T.dim Four 4))) (Sig.tensor T.uint64 (T.r1 (T.dim Two 2))))
        (\() ->
            ( T.fromList T.int64 (T.r1 (T.dim Four 4)) signedValues
            , T.fromList T.uint64 (T.r1 (T.dim Two 2)) unsignedValues
            )
        )
    ]


{-| The graph's two outputs are unlabelled, so named `result0` and `result1`; a `ui64` element
comes back as the `Int` with the same 64 bits.
-}
ranInt64 : String -> Session.Outputs -> Model -> ( Model, Cmd Msg )
ranInt64 graph outputs model =
    if graph == "int64" then
        let
            signed =
                Session.ints "result0" outputs |> Maybe.withDefault []

            unsigned =
                Session.ints "result1" outputs |> Maybe.withDefault []

            show l =
                String.join ", " (List.map String.fromInt l)

            ( m1, c1 ) =
                report (signed == signedValues) ("int64: si64 [" ++ show signed ++ "] (want [" ++ show signedValues ++ "])") model

            ( m2, c2 ) =
                report (unsigned == unsignedValues) ("int64: ui64 bits [" ++ show unsigned ++ "] (want [" ++ show unsignedValues ++ "])") m1
        in
        finish m2 [ c1, c2 ]

    else
        ( model, Cmd.none )
