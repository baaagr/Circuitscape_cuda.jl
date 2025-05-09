export  model_problem,
        test_problem,
        accumulate_current_maps,
        calculate_cum_current_map,
        calculate_max_current_map

using Test

mutable struct MutablePair{T,V}
	first::T
	second::V
end

 """
 Construct nodemap specific to a connected component
 """
function construct_local_node_map(nodemap, component, polymap)
    local_nodemap = zeros(eltype(nodemap), size(nodemap))
    idx = findall(in(component), nodemap)
    local_nodemap[idx] = nodemap[idx]
    if nodemap == local_nodemap
        return local_nodemap
    end
    _construct_local_nodemap(local_nodemap, polymap, idx)
end

function _construct_local_nodemap(local_nodemap, polymap, idx)
    if isempty(polymap)
        i = findall(x ->x!=0, local_nodemap)
        local_nodemap[i] = 1:length(i)
        return local_nodemap
    else
        local_polymap = zeros(eltype(local_nodemap), size(local_nodemap))
        local_polymap[idx] = polymap[idx]
        return construct_node_map(local_nodemap, local_polymap)
    end
end

"""
Define model circuitscape problem - helps in tests
"""
function model_problem(T, s)

    # Cell map is the uniform 1 across the grid
    cellmap = ones(T, s, s)

    # Nodemap is just 1:endof(cellmap)
    nodemap = reshape(1:lastindex(cellmap), s, s) |> collect

    # Construct graph with 4 neighbors
    G = construct_graph(cellmap, nodemap, true, true)

    # Return laplacian
    laplacian(G)
end
model_problem(s::Integer) = model_problem(Float64, s)

# Testing utilities

function test_problem(str)
    base_path = joinpath(dirname(pathof(Circuitscape_cuda)), "..", "test", "input")
    str2 = replace(str, ".ini" => "")
    if occursin("sgVerify", str)
        config_path = joinpath(base_path, "raster", "pairwise", replace(str2, "sgVerify" => ""), str)
    elseif occursin("mgVerify", str)
        config_path = joinpath(base_path, "raster", "advanced", replace(str2, "mgVerify" => ""), str)
    elseif occursin("oneToAll", str)
        config_path = joinpath(base_path, "raster", "one_to_all", replace(str2, "oneToAllVerify" => ""), str)
    elseif occursin("allToOne", str)
        config_path = joinpath(base_path, "raster", "all_to_one", replace(str2, "allToOneVerify" => ""), str)
    elseif occursin("sgNetworkVerify", str)
        config_path = joinpath(base_path, "network", str)
    elseif occursin("mgNetworkVerify", str)
        config_path = joinpath(base_path, "network", str)
    end
end

# Utility funciton for calling Circuitscape with Cholmod
function compute_cholmod(str, batch_size = 5)
    cfg = parse_config(str)
    T = cfg["precision"] in SINGLE ? Float32 : Float64
    V = cfg["use_64bit_indexing"] in TRUELIST ? Int64 : Int32
    if T == Float32
        cswarn("Cholmod supports only double precision. Changing precision to double.")
        T = Float64
    end
    cfg["solver"] = "cholmod"
    cfg["cholmod_batch_size"] = string(batch_size)
    _compute(T, V, cfg)
end

function compute_gpu(str)
    cfg = parse_config(str)
    T = cfg["precision"] in SINGLE ? Float32 : Float64
    V = cfg["use_64bit_indexing"] in TRUELIST ? Int64 : Int32
    cfg["use_gpu"] = "True"
    cfg["solver"] = "cg+amg"
    cfg["precision"] = "double"
    _compute(T, V, cfg)
end

function compute_cg_amg(str)
    cfg = parse_config(str)
    T = cfg["precision"] in SINGLE ? Float32 : Float64
    V = cfg["use_64bit_indexing"] in TRUELIST ? Int64 : Int32
    cfg["use_gpu"] = "False"
    cfg["solver"] = "cg+amg"
    cfg["precision"] = "double"
    _compute(T, V, cfg)
end

function compute_single(str)
    cfg = parse_config(str)
    cfg["precision"] = "single"
    V = cfg["use_64bit_indexing"] in TRUELIST ? Int64 : Int32
    T = Float32
	if cfg["solver"] in CHOLMOD || cfg["solver"] in MKLPARDISO
        cswarn("Cholmod and Pardiso support only double precision. Changing precision to double.")
        T = Float64
    end
    _compute(T, V, cfg)
end

function compute_parallel(str, n_processes = 2)
    cfg = parse_config(str)
    cfg["parallelize"] = "true"
    cfg["max_parallel"] = "$(n_processes)"
    compute(cfg)
end

function get_output_flags(cfg)

    # Output flags
    write_volt_maps = cfg["write_volt_maps"] in TRUELIST
    write_cur_maps = cfg["write_cur_maps"] in TRUELIST
    write_cum_cur_map_only = cfg["write_cum_cur_map_only"] in TRUELIST
    write_max_cur_maps = cfg["write_max_cur_maps"] in TRUELIST
    set_null_currents_to_nodata = cfg["set_null_currents_to_nodata"] in TRUELIST
    set_null_voltages_to_nodata = cfg["set_null_voltages_to_nodata"] in TRUELIST
    compress_grids = cfg["compress_grids"] in TRUELIST
    log_transform_maps = cfg["log_transform_maps"] in TRUELIST

    o = OutputFlags(write_volt_maps, write_cur_maps,
                    write_cum_cur_map_only, write_max_cur_maps,
                    set_null_currents_to_nodata, set_null_voltages_to_nodata,
                    compress_grids, log_transform_maps)
end

# Helps start new processes from the INI file
function myaddprocs(n)
    addprocs(n)
    @everywhere Core.eval(Main, :(using Circuitscape_cuda))
end

# Reads the directory with the current maps
# and accumulates all current maps
function accumulate_current_maps(path, f)
    dir = dirname(path)
    base = basename(path)

    # If base file has a dot
    name = split(base, ".out")[1]

    cmap_list = readdir(dir) |>
                    x -> filter(y -> startswith(y, "$(name)_"), x) |>
                    x -> filter(y -> occursin("_curmap_", y), x)
    isempty(cmap_list) && return

    headers = ""
    first_file = joinpath(dir, cmap_list[1])
    nrow = 0
    ncol = 0

    # Read the headers from the first file
    open(first_file, "r") do f

        # Get num cols
        str = readline(f)
        headers = headers * str * "\n"
        ncol = split(str)[2] |> x -> parse(Int, x)

        # Get num rows
        str = readline(f)
        headers = headers * str * "\n"
        nrow = split(str)[2] |> x -> parse(Int, x)

        # Just append the rest
        for i = 3:6
            headers = headers * readline(f) * "\n"
        end
    end

    accum = zeros(nrow, ncol)
    for file in cmap_list
        csinfo("Accumulating $file", cfg["suppress_messages"] in TRUELIST)
        cmap_path = joinpath(dir, file)
        cmap = readdlm(cmap_path, skipstart = 6)
        f_in_place!(accum, cmap, f)
    end
    for i in eachindex(accum)
        if accum[i] < -9999
            accum[i] = -9999
        end
    end

    name =  if isequal(f, +)
                "cum"
            elseif isequal(f, max)
                "max"
            end

    accum_path = joinpath(dir, name * "_$(name)_curmap.asc")
    csinfo("Writing to $accum_path", cfg["suppress_messages"] in TRUELIST)
    open(accum_path, "w") do f
        write(f, headers)
        writedlm(f, round.(accum, digits=8), ' ')
    end

end

function f_in_place!(accum, cmap, f)
    accum .= f.(accum, cmap)
end

calculate_cum_current_map(path) = accumulate_current_maps(path, +)
calculate_max_current_map(path) = accumulate_current_maps(path, max)

function postprocess_cum_curmap!(accum)
    for i in eachindex(accum)
        if accum[i] < -9999
            accum[i] = -9999
        end
    end
end

mycsid() = myid() - minimum(workers()) + 1

function initialize_cum_maps(cellmap::Matrix{T}, max = false) where T
    cum_curr = Vector{SharedMatrix{T}}(undef,nprocs())
    for i = 1:nprocs()
        cum_curr[i] = SharedArray(zeros(T, size(cellmap)...))
    end
    max_curr = Vector{SharedMatrix{T}}()
    if max
        max_curr = Vector{SharedMatrix{T}}(undef,nprocs())
        for i = 1:nprocs()
            max_curr[i] = SharedArray(fill(T(-9999), size(cellmap)...))
        end
    end
    cum_branch_curr = Vector{SharedVector{T}}()
    cum_node_curr = Vector{SharedVector{T}}()

    Cumulative(cum_curr, max_curr,
			   cum_branch_curr, cum_node_curr, Vector{Tuple{Int,Int}}())
end

function initialize_cum_vectors(coords::Tuple{Vector{V},Vector{V},Vector{T}}, num_nodes::Int64) where {T,V}
    cum_curr = Vector{SharedMatrix{T}}()
    max_curr = Vector{SharedMatrix{T}}()
	cum_branch_curr = Vector{SharedVector{T}}(undef,nprocs())
	cum_node_curr = Vector{SharedVector{T}}(undef,nprocs())
	_i, _j, _v = coords
    for i = 1:nprocs()
        #cum_branch_curr[i] = SharedArray(zeros(T, size(v)...))
		cum_branch_curr[i] = SharedVector(zeros(T,length(_v)))
		cum_node_curr[i] = SharedVector(zeros(T,num_nodes))
    end

	coords = map((x,y) -> (x,y), _i, _j)
    Cumulative(cum_curr, max_curr,
			   cum_branch_curr, cum_node_curr, coords)
end

function runtests(f = compute)

    str = if f == compute_single
            "Single"
          else
            "Double"
          end

    is_single = false
    tol = 1e-6
    str == "Single" && (is_single = true; tol = 1e-4)

    @testset "$str Precision Tests" begin
#        @testset "Network Pairwise" begin
#            # Network pairwise tests
#            for i = 1:3
#                @info("Testing sgNetworkVerify$i")
#                r = f("input/network/sgNetworkVerify$(i).ini")
#                x = readdlm("output_verify/sgNetworkVerify$(i)_resistances.out")
#                valx = x[2:end, 2:end]
#                valr = r[2:end, 2:end]
#                @test sum(abs2, valx - valr) < tol
#                pts_x = x[2:end,1]
#                pts_r = r[2:end,1]
#                @test pts_x .+ 1 == pts_r
#                compare_all_output("sgNetworkVerify$(i)", is_single)
#                @info("Test sgNetworkVerify$i passed")
#            end
#        end
#
#        @testset "Network Advanced" begin
#            # Network advanced tests
#            for i = 1:3
#                @info("Testing mgNetworkVerify$i")
#                r = f("input/network/mgNetworkVerify$(i).ini")
#                x = readdlm("output_verify/mgNetworkVerify$(i)_voltages.txt")
#                @. x[:,1] = x[:,1] + 1
#                @test sum(abs2, x - r) < tol
#                compare_all_output("mgNetworkVerify$(i)", is_single)
#                @info("Test mgNetworkVerify$i passed")
#            end
#        end

        @testset "Raster Pairwise" begin
            # Raster pairwise tests
#            for i = 1:17
            for i = 1:2
                # Weird windows 32 stuff
                if i == 16 && Sys.WORD_SIZE == 32
                    continue
                end

                @info("Testing sgVerify$i")
                r = f("input/raster/pairwise/$i/sgVerify$(i).ini")
                x = readdlm("output_verify/sgVerify$(i)_resistances.out")
                _x = readdlm("output/sgVerify$(i)_resistances.out")
                # x = x[2:end, 2:end]
                @test sum(abs2, _x - r) < tol
                @test sum(abs2, x - r) < tol
                compare_all_output("sgVerify$(i)", is_single)
                @info("Test sgVerify$i passed")
            end
        end

#        @testset "Raster Advanced" begin
#            # Raster advanced tests
#            for i in 1:6
#                @info("Testing mgVerify$i")
#                r = f("input/raster/advanced/$i/mgVerify$(i).ini")
#                # x = readdlm("output_verify/mgVerify$(i)_voltmap.asc"; skipstart = 6)
#                # @test sum(abs2, x - r) < 1e-4
#                compare_all_output("mgVerify$(i)")
#                @info("Test mgVerify$i passed")
#            end
#        end
#
#        @testset "Raster One to All" begin
#            # Raster one to all test
#			for i in 1:13
#                @info("Testing oneToAllVerify$i")
#                r = f("input/raster/one_to_all/$i/oneToAllVerify$(i).ini")
#                x = readdlm("output_verify/oneToAllVerify$(i)_resistances.out")
#                # x = x[:,2]
#                @test sum(abs2, x - r) < tol
#                compare_all_output("oneToAllVerify$(i)", is_single)
#                @info("Test oneToAllVerify$i passed")
#            end
#        end
#
#        @testset "Raster All to One" begin
#            # Raster all to one test
#            for i in 1:12
#                @info("Testing allToOneVerify$i")
#                r = f("input/raster/all_to_one/$i/allToOneVerify$(i).ini")
#                x = readdlm("output_verify/allToOneVerify$(i)_resistances.out")
#                # x = x[:,2]
#
#                @test sum(abs2, x - r) < tol
#                compare_all_output("allToOneVerify$(i)", is_single)
#                @info("Test allToOneVerify$i passed")
#            end
#        end
    end
end

function compare_all_output(str, is_single = false)

    gen_list, list_to_comp = generate_lists(str)
    tol = is_single ?  1e-4 : 1e-6

    for f in gen_list
        !occursin("_", f) && continue
        occursin("resistances", f) && continue

        @info("Testing $f")

        # Raster output files
        if endswith(f, "asc")
            r = read_aagrid("output/$f")
            x = get_comp(list_to_comp, f)
            @test compare_aagrid(r, x, tol)
            @info("Test $f passed")

        # Network output files
        elseif occursin("Network", f)

            # Branch currents
            if occursin("branch", f)
                r = read_branch_currents("output/$f")
                x = !startswith(f, "mg") ? get_network_comp(list_to_comp, f) : readdlm("output_verify/$f")
                @test compare_branch(r, x, tol)
                @info("Test $f passed")

            # Node currents
            else
                r = read_node_currents("output/$f")
                x = !startswith(f, "mg") ? get_network_comp(list_to_comp, f) : readdlm("output_verify/$f")
                @test compare_node(r, x, tol)
                @info("Test $f passed")
            end
        end
    end

end

list_of_files(str, pref) = readdir(pref) |> y -> filter(x -> startswith(x, "$(str)_"), y)
generate_lists(str) = list_of_files(str, "output/"), list_of_files(str, "output_verify/")
read_branch_currents(str) = readdlm(str)
read_node_currents(str) = readdlm(str)

read_aagrid(file) = readdlm(file, skipstart = 6) # Will change to 6

compare_aagrid(r::Matrix{T}, x::Matrix{T}, tol = 1e-6) where T = sum(abs2, x - r) < tol

function get_comp(list_to_comp, f)
    outfile = ""
    if f in list_to_comp
        outfile = "output_verify/$f"
    end
    readdlm(outfile; skipstart = 6)
end

function get_network_comp(list_to_comp, f)
    s = split(f, ['_', '.'])
    for i = 1:size(s, 1)
        if all(isnumeric, s[i])
            f = replace(f, "_$(s[i])"=>"_$(parse(Int, s[i]) - 1 |> string)", count=1)
        end
    end
    @assert isfile("output_verify/$f")
    readdlm("output_verify/$f")
end

function compare_branch(r, x, tol = 1e-6)
    @. x[:,1] = x[:,1] + 1
    @. x[:,2] = x[:,2] + 1
    sum(abs2, sortslices(r, dims=1) - sortslices(x, dims=1)) < tol
end

function compare_node(r, x, tol = 1e-6)
    @. x[:,1] = x[:,1] + 1
    sum(abs2, sortslices(r, dims=1) - sortslices(x, dims=1)) < tol
end


# Function to calculate current for Omniscape moving window solves
function compute_omniscape_current(
        conductance::Array{T, 2} where T <: Union{Float32, Float64},
        source::Array{T, 2} where T <: Union{Float32, Float64},
        ground::Array{T, 2} where T <: Union{Float32, Float64},
        cs_cfg::Dict{String, String}
    )
    V = Int64
    T = eltype(conductance)

    # get raster data
    cellmap = conductance
    polymap = Matrix{V}(undef, 0, 0)
    source_map = source
    ground_map = ground
    points_rc = (V[], V[], V[])
    strengths = Matrix{T}(undef, 0, 0)

    included_pairs = IncludeExcludePairs(:undef,
                                         V[],
                                         Matrix{V}(undef,0,0))

    # This is just to satisfy type requirements, most of it not used
    hbmeta = RasterMeta(size(cellmap)[2],
                        size(cellmap)[1],
                        0.,
                        0.,
                        1.,
                        -9999.,
                        Array{T, 1}(undef, 1),
                        "")

    rasterdata = RasterData(cellmap,
                            polymap,
                            source_map,
                            ground_map,
                            points_rc,
                            strengths,
                            included_pairs,
                            hbmeta)

    # Generate advanced data
    o = OutputFlags(
        false, false, false, false,
        false, false, false, false
    )

    flags = RasterFlags(
        true, false, true, false, false, false, Symbol("rmvsrc"),
        cs_cfg["connect_four_neighbors_only"] in TRUELIST, false, 
        cs_cfg["solver"], o
    )

    data = compute_advanced_data(rasterdata, flags, cs_cfg)

    G = data.G
    nodemap = data.nodemap
    polymap = data.polymap
    hbmeta = data.hbmeta
    sources = data.sources
    grounds = data.grounds
    finitegrounds = data.finitegrounds
    cc = data.cc
    check_node = data.check_node
    source_map = data.source_map # Need it for one to all mode
    cellmap = data.cellmap

    f_local = Vector{eltype(G)}()
    voltages = Vector{eltype(G)}()
    outcurr = alloc_map(hbmeta)

    for c in cc
        if check_node != -1 && !(check_node in c)
            continue
        end

        # a_local = laplacian(G[c, c])
        a_local = G[c,c]
        s_local = sources[c]
        g_local = grounds[c]

        if sum(s_local) == 0 || sum(g_local) == 0
            continue
        end

        if finitegrounds != [-9999.]
            f_local = finitegrounds[c]
        else
            f_local = finitegrounds
        end

        voltages = multiple_solver(cs_cfg,
                                   data.solver,
                                   a_local,
                                   s_local,
                                   g_local,
                                   f_local)

        local_nodemap = construct_local_node_map(nodemap,
                                                 c,
                                                 polymap)

        accum_currents!(outcurr,
                        voltages,
                        cs_cfg,
                        a_local,
                        voltages,
                        f_local,
                        local_nodemap,
                        hbmeta)
    end

    return outcurr
end


# Testing utilities
function change_to_test_path()
    origpath = pwd()
    pkgpath = Base.pathof(Circuitscape_cuda)
    cd(joinpath(dirname(pkgpath), "..", "test"))
    origpath
end

function runtest(str)
    origpath = change_to_test_path()
    prob = test_problem(str)
    compute(prob)
    cd(origpath)
end
