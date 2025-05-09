import Circuitscape_cuda: construct_node_map, compute_omniscape_current
using Circuitscape_cuda

# Omniscape moving window solve test 
# just checking syntax, other tests should be sufficient to ensure correctness.
let
        conductance = [
                1 5   1.;
                2 1   1;
                9 1   6
        ]
        source = [
                1 0 0.;
                0 0 0;
                0 1 0
        ]
        ground = [
                0 0 1.;
                0 0 0;
                0 0 0
        ]

        cs_cfg = Dict{String, String}()

        cs_cfg["ground_file_is_resistances"] = "True"
        cs_cfg["use_direct_grounds"] = "False"
        cs_cfg["output_file"] = "temp"
        cs_cfg["write_cum_cur_map_only"] = "False"
        cs_cfg["scenario"] = "Advanced"
        cs_cfg["suppress_messages"] = "True"
        cs_cfg["connect_four_neighbors_only"] = "False"
        cs_cfg["solver"] = "cholmod"
        cs_cfg["cholmod_batch_size"] = "1000"
        cs_cfg["data_type"] = "raster"
        cs_cfg["use_gpu"] = "False"

        current = compute_omniscape_current(
                conductance,
                source,
                ground,
                cs_cfg
        )
        
end
let
        conductance = [
                1 5   1.;
                2 1   1;
                9 1   6
        ]
        source = [
                1 0 0.;
                0 0 0;
                0 1 0
        ]
        ground = [
                0 0 1.;
                0 0 0;
                0 0 0
        ]

        cs_cfg = Dict{String, String}()

        cs_cfg["ground_file_is_resistances"] = "True"
        cs_cfg["use_direct_grounds"] = "False"
        cs_cfg["output_file"] = "temp"
        cs_cfg["write_cum_cur_map_only"] = "False"
        cs_cfg["scenario"] = "Advanced"
        cs_cfg["suppress_messages"] = "True"
        cs_cfg["connect_four_neighbors_only"] = "False"
        cs_cfg["solver"] = "cg+amg"
        cs_cfg["cholmod_batch_size"] = "1000"
        cs_cfg["data_type"] = "raster"
        cs_cfg["use_gpu"] = "True"

        current = compute_omniscape_current(
                conductance,
                source,
                ground,
                cs_cfg
        )
        
end
# Construct nodemap tests
let
        gmap = [0 1 2
                2 0 0
                2 0 2]
        nodemap = construct_node_map(gmap, Matrix{Int}(undef,0,0))
        @test nodemap == [0 3 4
                          1 0 0
                          2 0 5]
end

let
        gmap = [0 1 2
               2 0 0
               2 0 2]
        polymap = [1 0 1
                   2 1 0
                   0 0 2]
        nodemap = construct_node_map(gmap, polymap)
        @test nodemap == [4  3  4
                          1  4  0
                          2  0  1]
end

let
        gmap = [1 0 1
                0 1 0
                1 0 1]

        polymap = [1 0 1
                0 2 0
                2 0 0]

        r = construct_node_map(gmap, polymap)

        @test r == [1 0 1
                    0 2 0
                    2 0 3]
end

let
    polymap = [ 1.0  2.0  0.0  0.0  0.0
                0.0  0.0  0.0  0.0  0.0
                0.0  0.0  0.0  0.0  0.0
                0.0  0.0  0.0  0.0  0.0
                1.0  0.0  0.0  0.0  2.0]

    gmap = [0    0    0    1.0   1.0
            0    0    0    3.01  2.0
            1.0  2.0  2.0  1.0   1.0
            1.0  2.0  2.0  1.0   1.0
            1.0  2.0  2.0  0     1.0]

    nodemap = construct_node_map(gmap, polymap)

    @test nodemap == [ 3.0  18.0  0.0  10.0  14.0
                       0.0   0.0  0.0  11.0  15.0
                       1.0   4.0  7.0  12.0  16.0
                       2.0   5.0  8.0  13.0  17.0
                       3.0   6.0  9.0   0.0  18.0]
end

let

    println("pwd = $(pwd())")
    cfg = Circuitscape_cuda.parse_config("input/raster/one_to_all/11/oneToAllVerify11.ini")
    r = Circuitscape_cuda.load_raster_data(Float64, Int32, cfg)

    cellmap = r.cellmap
    polymap = r.polymap
    points_rc = r.points_rc
    point_map = [ 1.0  2.0  0.0  0.0  0.0
                  0.0  0.0  0.0  0.0  0.0
                  3.0  0.0  0.0  7.0  0.0
                  4.0  0.0  0.0  0.0  0.0
                  1.0  0.0  0.0  0.0  2.0 ]

    r = Circuitscape_cuda.create_new_polymap(cellmap, polymap, points_rc, 0, 0, point_map)

    @test r == [ 1.0  2.0  0.0  0.0  0.0
                 0.0  0.0  0.0  0.0  0.0
                 12.0  0.0  0.0  2.0  0.0
                 1.0  0.0  0.0  0.0  0.0
                 1.0  0.0  0.0  0.0  2.0 ]
end

import Circuitscape_cuda: resolve_conflicts

@test resolve_conflicts([1.,0.,0.], [1.,0.,0.], :rmvgnd) == ([1, 0, 0], [0, 0, 0], [1, 0, 0])
@test resolve_conflicts([1.,0.,0.], [1.,0.,0.], :rmvsrc) == ([0, 0, 0], [1, 0, 0], [1, 0, 0])
@test resolve_conflicts([1.,0.,0.], [1.,0.,0.], :keepall) == ([1, 0, 0], [1, 0, 0], [1, 0, 0])
@test resolve_conflicts([1.,0.,0.], [1.,0.,0.], :rmvall) == ([0, 0, 0], [1, 0, 0], [1, 0, 0])

# Construct graph
import Circuitscape_cuda: construct_graph
let
        gmap = Float64[0 1 2
                2 0 0
                2 0 2]
        nodemap = [0 3 4
                   1 0 0
                   2 0 5]
        A = construct_graph(gmap, nodemap, false, true)
        r = Matrix(A) - [0 2 0 0 0
                       2 0 0 0 0
                       0 0 0 1.5 0
                       0 0 1.5 0 0
                       0 0 0 0 0]
        @test sum(abs2, r) < 1e-6
        A = construct_graph(gmap, nodemap, true, true)
        r = Matrix(A) - [0 2 0 0 0
                       2 0 0 0 0
                       0 0 0 1.3333 0
                       0 0 1.33333 0 0
                       0 0 0 0 0]
        @test sum(abs2, r) < 1e-6
        A = construct_graph(gmap, nodemap, false, false)
        r = Matrix(A) - [0 2 1.06066 0 0
                       2 0 0 0 0
                       1.06066 0 0 1.5 0
                       0 0 1.5 0 0
                       0 0 0 0 0]
        @test sum(abs2, r) < 1e-6
        A = construct_graph(gmap, nodemap, true, false)
        r = Matrix(A) - [0 2 0.942809 0 0
                       2 0 0 0 0
                       0.942809 0 0 1.3333 0
                       0 0 1.3333 0 0
                       0 0 0 0 0]
        @test sum(abs2, r) < 1e-6

end

# 2D Model Problems

SIZE_2 =

[2.0  -1.0  -1.0   0.0
-1.0   2.0   0.0  -1.0
-1.0   0.0   2.0  -1.0
 0.0  -1.0  -1.0   2.0]

@test model_problem(2) == SIZE_2

SIZE_3 =

[2.0  -1.0   0.0  -1.0   0.0   0.0   0.0   0.0   0.0
-1.0   3.0  -1.0   0.0  -1.0   0.0   0.0   0.0   0.0
 0.0  -1.0   2.0   0.0   0.0  -1.0   0.0   0.0   0.0
-1.0   0.0   0.0   3.0  -1.0   0.0  -1.0   0.0   0.0
 0.0  -1.0   0.0  -1.0   4.0  -1.0   0.0  -1.0   0.0
 0.0   0.0  -1.0   0.0  -1.0   3.0   0.0   0.0  -1.0
 0.0   0.0   0.0  -1.0   0.0   0.0   2.0  -1.0   0.0
 0.0   0.0   0.0   0.0  -1.0   0.0  -1.0   3.0  -1.0
 0.0   0.0   0.0   0.0   0.0  -1.0   0.0  -1.0   2.0]

 @test model_problem(3) == SIZE_3

# Issue 151
# Issue 151
try
    Circuitscape_cuda.read_point_map(Int32, "samples.txt",
                                Circuitscape_cuda.RasterMeta(50, 50, 0.0, 0.0, 0.5, -9999.0, [0.0], ""))
catch e
    @test e == "At least one focal node location falls outside of habitat map"
end

# Users with dots in their names - issue #181
# Just check that this does not break
#compute("input/raster/extra.one/1/oneToAllVerify1.ini")
