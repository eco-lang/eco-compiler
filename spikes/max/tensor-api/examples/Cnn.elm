module Cnn exposing (..)

import Nn
import Nn.Conv2d as Conv2d exposing (Conv2d)
import Nn.Linear as Linear exposing (Linear)
import Param
import Tensor as T exposing (Dim, F32, Floating, R2, R4, Tensor)


type H28
    = H28


type H14
    = H14


type H7
    = H7


type Gray
    = Gray


type C32
    = C32


type C64
    = C64


type Flat
    = Flat


type Classes
    = Classes


gray : Dim Gray
gray =
    T.dim Gray 1


c32 : Dim C32
c32 =
    T.dim C32 32


c64 : Dim C64
c64 =
    T.dim C64 64


h14 : Dim H14
h14 =
    T.dim H14 14


h7 : Dim H7
h7 =
    T.dim H7 7


flat : Dim Flat
flat =
    T.dim Flat (7 * 7 * 64)


classes : Dim Classes
classes =
    T.dim Classes 10


type alias Params =
    { conv1 : Conv2d F32 Gray C32, conv2 : Conv2d F32 C32 C64, out : Linear F32 Flat Classes }


params : Param.Spec Params
params =
    Param.record Params
        |> Param.sub .conv1 (Conv2d.params T.float32 { kernel = ( 3, 3 ) } gray c32)
        |> Param.sub .conv2 (Conv2d.params T.float32 { kernel = ( 3, 3 ) } c32 c64)
        |> Param.sub .out (Linear.params T.float32 flat classes)


pool : Dim h2 -> Tensor Floating F32 (R4 n h w c) -> Tensor Floating F32 (R4 n h2 h2 c)
pool d =
    Nn.maxPool2d 2 d d


network : Params -> Tensor Floating F32 (R4 n H28 H28 Gray) -> Tensor Floating F32 (R2 n Classes)
network p images =
    images
        |> Conv2d.applySame p.conv1
        |> T.relu
        |> pool h14
        |> Conv2d.applySame p.conv2
        |> T.relu
        |> pool h7
        |> T.flattenTail4 flat
        |> Linear.apply p.out
