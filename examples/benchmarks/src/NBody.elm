module NBody exposing (bench, output)

{-| n-body: simulate the Jovian planets around the Sun for `n` steps of 0.01 days, reporting the
system's energy before and after. Float arithmetic on records, rebuilt at every step.
-}

import Output


type alias Body =
    { x : Float
    , y : Float
    , z : Float
    , vx : Float
    , vy : Float
    , vz : Float
    , mass : Float
    }


solarMass : Float
solarMass =
    4 * pi * pi


daysPerYear : Float
daysPerYear =
    365.24


planet : Float -> Float -> Float -> Float -> Float -> Float -> Float -> Body
planet x y z vx vy vz mass =
    Body x y z (vx * daysPerYear) (vy * daysPerYear) (vz * daysPerYear) (mass * solarMass)


initialBodies : List Body
initialBodies =
    [ Body 0 0 0 0 0 0 solarMass
    , planet 4.8414314424647209 -1.16032004402742839 -0.103622044471123109 1.66007664274403694e-3 7.69901118419740425e-3 -6.90460016972063023e-5 9.54791938424326609e-4
    , planet 8.34336671824457987 4.12479856412430479 -0.403523417114321381 -2.76742510726862411e-3 4.99852801234917238e-3 2.30417297573763929e-5 2.85885980666130812e-4
    , planet 12.894369562139131 -15.1111514016986312 -0.223307578892655734 2.96460137564761618e-3 2.37847173959480950e-3 -2.96589568540237556e-5 4.36624404335156298e-5
    , planet 15.3796971148509165 -25.9193146099879641 0.179258772950371181 2.68067772490389322e-3 1.62824170038242295e-3 -9.51592254519715870e-5 5.15138902046611451e-5
    ]


{-| Give the Sun the velocity that makes the system's total momentum zero.
-}
offsetMomentum : List Body -> List Body
offsetMomentum bodies =
    let
        momentum f =
            List.foldl (\b p -> p - f b * b.mass) 0 bodies
    in
    case bodies of
        sun :: planets ->
            { sun | vx = momentum .vx / solarMass, vy = momentum .vy / solarMass, vz = momentum .vz / solarMass } :: planets

        [] ->
            []


{-| One step: every pair pulls on each other, in the order (0,1), (0,2), ..., (3,4), then every
body moves.
-}
advance : Float -> List Body -> List Body
advance dt bodies =
    List.map (move dt) (interactAll dt bodies)


interactAll : Float -> List Body -> List Body
interactAll dt bodies =
    case bodies of
        [] ->
            []

        b :: rest ->
            let
                ( b2, rest2 ) =
                    pullAll dt b rest
            in
            b2 :: interactAll dt rest2


pullAll : Float -> Body -> List Body -> ( Body, List Body )
pullAll dt b others =
    case others of
        [] ->
            ( b, [] )

        o :: rest ->
            let
                ( b2, o2 ) =
                    pull dt b o

                ( b3, rest2 ) =
                    pullAll dt b2 rest
            in
            ( b3, o2 :: rest2 )


pull : Float -> Body -> Body -> ( Body, Body )
pull dt a b =
    let
        dx =
            a.x - b.x

        dy =
            a.y - b.y

        dz =
            a.z - b.z

        d2 =
            dx * dx + dy * dy + dz * dz

        mag =
            dt / (d2 * sqrt d2)

        am =
            a.mass * mag

        bm =
            b.mass * mag
    in
    ( { a | vx = a.vx - dx * bm, vy = a.vy - dy * bm, vz = a.vz - dz * bm }
    , { b | vx = b.vx + dx * am, vy = b.vy + dy * am, vz = b.vz + dz * am }
    )


move : Float -> Body -> Body
move dt b =
    { b | x = b.x + dt * b.vx, y = b.y + dt * b.vy, z = b.z + dt * b.vz }


energy : List Body -> Float
energy bodies =
    let
        potential others b e =
            List.foldl
                (\o acc ->
                    let
                        dx =
                            b.x - o.x

                        dy =
                            b.y - o.y

                        dz =
                            b.z - o.z
                    in
                    acc - (b.mass * o.mass) / sqrt (dx * dx + dy * dy + dz * dz)
                )
                e
                others

        pairs bs e =
            case bs of
                [] ->
                    e

                b :: rest ->
                    pairs rest (potential rest b e)
    in
    List.foldl (\b e -> e + b.mass * (b.vx * b.vx + b.vy * b.vy + b.vz * b.vz) / 2) (pairs bodies 0) bodies


steps : Int -> List Body -> List Body
steps n bodies =
    if n <= 0 then
        bodies

    else
        steps (n - 1) (advance 0.01 bodies)


{-| The benchmark's standard output: the energy before and after `n` steps.
-}
output : Int -> String
output n =
    let
        start =
            offsetMomentum initialBodies
    in
    Output.fixed9 (energy start) ++ "\n" ++ Output.fixed9 (energy (steps n start)) ++ "\n"


bench : Int -> Int
bench n =
    Output.checksum (output n)
