struct AdvancedProblem{T,V,W}
    G::SparseMatrixCSC{T,V}
    cc::Vector{Vector{V}}
    nodemap::Matrix{V}
    polymap::Matrix{V}
    hbmeta::RasterMeta
    sources::Vector{T}
    grounds::Vector{T}
    source_map::Matrix{T} # Needed for one to all mode
    finitegrounds::Vector{T}
    check_node::V
    src::V
    cellmap::Matrix{T}
    solver::W
end

function raster_advanced(T, V, cfg)::Matrix{T}

    # Load raster data
    rasterdata = load_raster_data(T, V, cfg)

    # Get flags
    flags = get_raster_flags(cfg)


    # Generate advanced
    advanced_data = compute_advanced_data(rasterdata, flags, cfg)

    # Send to main kernel
    v, _ = advanced_kernel(advanced_data, flags, cfg)

    v
end


function compute_advanced_data(data::RasterData{T,V},
                        flags,cfg)::AdvancedProblem{T,V} where {T,V}

    # Data
    cellmap = data.cellmap
    polymap = data.polymap
    points_rc = data.points_rc
    included_pairs = data.included_pairs
    hbmeta = data.hbmeta
    source_map = data.source_map


    # Flags
    avg_res = flags.avg_res
    four_neighbors = flags.four_neighbors
    policy = flags.policy

    # Nodemap and graph construction
    nodemap = construct_node_map(cellmap, polymap)
    A = construct_graph(cellmap, nodemap, avg_res, four_neighbors)
    G = laplacian(A)

    # Connected Components
    cc = connected_components(SimpleWeightedGraph(G))

    # Advanced mode specific stuff
    sources, grounds, finitegrounds =
            get_sources_and_grounds(data, flags, G, nodemap)

    solver = get_solver(cfg)

    AdvancedProblem(G, cc, nodemap, polymap, hbmeta,
                sources, grounds, source_map,
                finitegrounds, V(-1), V(0), cellmap, solver)

end

function get_sources_and_grounds(data, flags, G, nodemap)

    # Data
    source_map = data.source_map
    ground_map = data.ground_map

    _get_sources_and_grounds(source_map, ground_map, flags, G, nodemap)
end

function _get_sources_and_grounds(source_map, ground_map,
                                  flags, G, nodemap::Matrix{V}, override_policy = :none) where V
    # Flags
    is_raster = flags.is_raster
    grnd_file_is_res = flags.grnd_file_is_res
    policy = override_policy == :none ? flags.policy : override_policy

    # Initialize sources and grounds
    sources = zeros(eltype(G), size(G, 1))
    grounds = zeros(eltype(G), size(G, 1))

    if is_raster
        (i1, j1, v1) = begin _I = findall(!iszero, source_map); getindex.(_I, 1), getindex.(_I, 2), source_map[_I] end
        (i2, j2, v2) = begin _I = findall(!iszero, ground_map); getindex.(_I, 1), getindex.(_I, 2), ground_map[_I] end
        for i = 1:size(i1, 1)
            v = V(nodemap[i1[i], j1[i]])
            if v != 0
                sources[v] += v1[i]
            end
        end
        for i = 1:size(i2, 1)
            v = V(nodemap[i2[i], j2[i]])
            if v != 0
                grounds[v] += v2[i]
            end
        end
    else
        if grnd_file_is_res
            ground_map[:,2] = 1 ./ ground_map[:,2]
        end
        sources[V.(source_map[:,1])] = source_map[:,2]
        grounds[V.(ground_map[:,1])] = ground_map[:,2]
    end
    sources, grounds, finitegrounds =
        resolve_conflicts(sources, grounds, policy)
end

function resolve_conflicts(sources::Vector{T},
                            grounds::Vector{T}, policy) where T

    l = size(sources, 1)

    finitegrounds = map(x -> x < T(Inf) ? x : T(0.), grounds)
    if count(x -> x != 0, finitegrounds) == 0
        finitegrounds = T.([-9999.])
    end

    conflicts = falses(l)
    for i = 1:l
        conflicts[i] = sources[i] != 0 && grounds[i] != 0
    end

    if any(conflicts)
        if policy == :rmvsrc
            sources[findall(x->x!=0,conflicts)] .= 0
        elseif policy == :rmvgnd
            grounds[findall(x->x!=0,conflicts)] .= 0
        elseif policy == :rmvall
            sources[findall(x->x!=0,conflicts)] .= 0
        end
    end

    infgrounds = map(x -> x == Inf, grounds)
    infconflicts = map((x,y) -> x > 0 && y > 0, infgrounds, sources)
    grounds[infconflicts] .= 0

    sources, grounds, finitegrounds
end

function advanced_kernel(prob::AdvancedProblem{T,V,S}, flags, cfg)::Tuple{Matrix{T},Matrix{T}} where {T,V,S}

    # Data
    G = prob.G
    nodemap = prob.nodemap
    polymap = prob.polymap
    hbmeta = prob.hbmeta
    sources = prob.sources
    grounds = prob.grounds
    finitegrounds = prob.finitegrounds
    cc = prob.cc
    src = prob.src
    check_node = prob.check_node
    source_map = prob.source_map # Need it for one to all mode
    cellmap = prob.cellmap


    # Flags
    is_raster = flags.is_raster
    is_alltoone = flags.is_alltoone
    is_onetoall = flags.is_onetoall
    write_v_maps = flags.outputflags.write_volt_maps
    write_c_maps = flags.outputflags.write_cur_maps
    write_cum_cur_map_only = flags.outputflags.write_cum_cur_map_only

    volt = zeros(eltype(G), size(nodemap))
    ind = findall(x->x!=0,nodemap)
    f_local = Vector{eltype(G)}()
    solver_called = false
	voltages = zeros(eltype(G), size(G, 1))
    outvolt = alloc_map(hbmeta)
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

		voltages[c] .+= multiple_solver(cfg, prob.solver, a_local, s_local, g_local, f_local)

        local_nodemap = construct_local_node_map(nodemap, c, polymap)
        solver_called = true

        if write_v_maps
			is_raster ? accum_voltages!(outvolt, voltages[c], local_nodemap, hbmeta) :
				accum_voltages!(outvolt, voltages, local_nodemap, hbmeta)
        end
        if write_c_maps
			is_raster ? accum_currents!(outcurr, voltages[c], cfg, a_local, voltages[c], f_local, local_nodemap, hbmeta) :
				accum_currents!(outcurr, voltages, cfg, G, voltages, finitegrounds, local_nodemap, hbmeta)
        end

		_is = map(i -> Int(local_nodemap[i]), 1:length(volt))
		_isn0 = findall(!iszero, _is)
		volt[_isn0] .= voltages[c][_is[_isn0]]
    end

    name = src == 0 ? "" : "_$(V(src))"
    if write_v_maps
        if !is_raster
            write_volt_maps(name, voltages, FullGraph(G, cellmap), flags, cfg)
        else
            write_grid(outvolt, name, cfg, hbmeta, cellmap, voltage = true)
        end
    end

    if write_c_maps || write_cum_cur_map_only
        if !is_raster
            write_cur_maps(name, voltages, FullGraph(G, cellmap), finitegrounds, flags, cfg)
        else
            write_grid(outcurr, name, cfg, hbmeta, cellmap)
        end
    end

    if !is_raster
        v = [collect(1:size(G, 1))  voltages]
        return v, outcurr
    end

    scenario = cfg["scenario"]
    if !solver_called
        ret = Matrix{T}(undef,1,1)
        ret[1] = -1
        return ret, outcurr
    end

    if is_onetoall
        idx = findall(x->x!=0,source_map)
        val = volt[idx] ./ source_map[idx]
        if val[1] ≈ 0
            ret = Matrix{T}(undef,1,1)
            ret[1] = -1
            return ret, outcurr
        else
            ret = Matrix{T}(undef,length(val),1)
            ret[:,1] = val
            return ret, outcurr
        end
    elseif is_alltoone
        ret = Matrix{T}(undef,1,1)
        ret[1] = 0
        return ret, outcurr
    end

    return volt, outcurr
end


function multiple_solver(cfg, solver, a::SparseMatrixCSC{T,V}, sources, grounds, finitegrounds) where {T,V}

    asolve = deepcopy(a)
    if finitegrounds[1] != -9999
        # asolve = a + spdiagm(finitegrounds, 0, size(a, 1), size(a, 1))
        asolve = a + spdiagm(0 => finitegrounds)
    end

    infgrounds = findall(x -> x == Inf, grounds)
    deleteat!(sources, infgrounds)
    dst_del = V[]
    append!(dst_del, infgrounds)
    r = collect(1:size(a, 1))
    deleteat!(r, dst_del)
    asolve = asolve[r, r]

    if cfg["use_gpu"] in TRUELIST
        t1 = @elapsed asolve, sources = cpu_to_gpu(asolve, sources)
        csinfo("Time taken to copy data to GPU = $t1 seconds", cfg["suppress_messages"] in TRUELIST)
    end

    volt = multiple_solve(solver, asolve, sources, cfg["suppress_messages"] in TRUELIST)

    # Replace the inf with 0
    voltages = zeros(eltype(a), length(volt) + length(infgrounds))
    k = 1
    for i = 1:size(voltages, 1)
        if i in infgrounds
            voltages[i] = 0
        else
            #voltages[i] = volt[1][k]
            voltages[i] = volt[k]
            k += 1
        end
    end
    voltages
end

function multiple_solve(s::AMGSolver, matrix::CUSPARSE.CuSparseMatrixCSC{T,V}, sources::CuVector{T}, suppress_info::Bool)::Vector{T} where {T,V}
    #t1 = @elapsed M = BlockJacobiPreconditioner(matrix, 2)
    #t1 = @elapsed M = kp_ilu0(matrix)
    #t1 = @elapsed M = kp_ic0(matrix)
    
    t1 = @elapsed M = CUSPARSE.CuSparseMatrixCSC(jacobi_preconditioner(SparseMatrixCSC(matrix)))
    csinfo("Time taken to construct preconditioner = $t1 seconds", suppress_info)
    t1 = @elapsed volt = solve_linear_system(matrix, sources, M)
    # @assert norm(matrix*volt .- sources) < (eltype(sources) == Float64 ? TOL_DOUBLE : TOL_SINGLE)
	# @assert (norm(matrix*volt .- sources) / norm(sources)) < 1e-4
    csinfo("Time taken to solve linear system = $t1 seconds", suppress_info)
    #volt_cpu = Vector{T}(volt_gpu)
    #volt_cpu
    volt
end

function multiple_solve(s::AMGSolver, matrix::SparseMatrixCSC{T,V}, sources::Vector{T}, suppress_info::Bool)::Vector{T} where {T,V}
    t1 = @elapsed M = aspreconditioner(smoothed_aggregation(matrix))
    csinfo("Time taken to construct preconditioner = $t1 seconds", suppress_info)
    t1 = @elapsed volt = solve_linear_system(matrix, sources, M)
    # @assert norm(matrix*volt .- sources) < (eltype(sources) == Float64 ? TOL_DOUBLE : TOL_SINGLE)
	# @assert (norm(matrix*volt .- sources) / norm(sources)) < 1e-4
    csinfo("Time taken to solve linear system = $t1 seconds", suppress_info)
    volt
end

function multiple_solve(s::CholmodSolver, matrix::SparseMatrixCSC{T,V}, sources::Vector{T}, suppress_info::Bool)::Vector{T} where {T,V}
    factor = construct_cholesky_factor(matrix, s, suppress_info)
    t1 = @elapsed volt = solve_linear_system(factor, matrix, sources)
    # @assert norm(matrix*volt .- sources) < (eltype(sources) == Float64 ? TOL_DOUBLE : TOL_SINGLE)
	# @assert (norm(matrix*volt .- sources) / norm(sources)) < 1e-4
    csinfo("Time taken to solve linear system = $t1 seconds", suppress_info)
    volt
end

function multiple_solve(s::MKLPardisoSolver, matrix::SparseMatrixCSC{T,V}, sources::Vector{T}, suppress_info::Bool)::Vector{T} where {T,V}
    factor = construct_cholesky_factor(matrix, s, suppress_info)
    t1 = @elapsed volt = solve_linear_system(factor, matrix, sources)
    # @assert norm(matrix*volt .- sources) < (eltype(sources) == Float64 ? TOL_DOUBLE : TOL_SINGLE)
	@assert (norm(matrix*volt .- sources) / norm(sources)) < 1e-4
    csinfo("Time taken to solve linear system = $t1 seconds", suppress_info)
    volt
end

struct FullGraph{T,V}
    matrix::SparseMatrixCSC{T,V}
    cc::Vector{V}
    local_nodemap::Matrix{V}
    hbmeta::RasterMeta
    cellmap::Matrix{T}
end
FullGraph(G::SparseMatrixCSC{T,V}, cellmap) where {T,V} = FullGraph(G, collect(V, 1:size(G,1)),
                            Matrix{V}(undef,0,0), RasterMeta(), cellmap)
