export compute

"""
`compute(path::String)`

Call the `compute` function on the configuration file.

Inputs:
======

* path::String - Path to configuration file

"""
function compute(path::String)
    cfg = parse_config(path)
    update_logging!(cfg)
    write_config(cfg)
    T = cfg["precision"] in SINGLE ? Float32 : Float64
    if T == Float32 && (cfg["solver"] in CHOLMOD || cfg["solver"] in MKLPARDISO)
        cswarn("Cholmod & MKLPardiso solver modes work only in double precision. Switching precision to double.")
        T = Float64
    end
    V = cfg["use_64bit_indexing"] in TRUELIST ? Int64 : Int32
    csinfo("Precision used: $(cfg["precision"])", cfg["suppress_messages"] in TRUELIST)
    use_gpu = cfg["use_gpu"] in TRUELIST
    if use_gpu && (cfg["solver"] in CHOLMOD || cfg["solver"] in MKLPARDISO)
        cswarn("Cholmod & MKLPardiso solver does not work with gpu. Switching off gpu.")
        cfg["use_gpu"] = False
    end
    is_parallel = cfg["parallelize"] in TRUELIST
    if is_parallel
        n = parse(Int, cfg["max_parallel"])
        csinfo("Starting up Circuitscape to use $n processes in parallel", cfg["suppress_messages"] in TRUELIST)
        myaddprocs(n)
    end
    t = @elapsed r = _compute(T, V, cfg)

    csinfo("Time taken to complete job = $t", cfg["suppress_messages"] in TRUELIST)
    is_parallel && rmprocs(workers())
    r
end

function _compute(T, V, cfg)
    is_raster = cfg["data_type"] in RASTER
    scenario = cfg["scenario"]
    if is_raster
        if scenario in PAIRWISE
            raster_pairwise(T, V, cfg)
        elseif scenario in ADVANCED
            raster_advanced(T, V, cfg)
        elseif scenario in ONETOALL
            raster_one_to_all(T, V, cfg)
        else
            raster_one_to_all(T, V, cfg)
        end
    else
        if scenario in PAIRWISE
            network_pairwise(T, V, cfg)
        else
            network_advanced(T, V, cfg)
        end
    end
end

function compute(dict)
    cfg = init_config()
    update!(cfg, dict)
    update_logging!(cfg)
    write_config(cfg)
    T = cfg["precision"] in SINGLE ? Float32 : Float64
    V = cfg["use_64bit_indexing"] in TRUELIST ? Int64 : Int32
    csinfo("Precision used: $(cfg["precision"])", cfg["suppress_messages"] in TRUELIST)
    is_parallel = cfg["parallelize"] in TRUELIST
    if is_parallel
        n = parse(Int, cfg["max_parallel"])
        csinfo("Starting up Circuitscape to use $n processes in parallel", cfg["suppress_messages"] in TRUELIST)
        myaddprocs(n)
    end
    t = @elapsed r = _compute(T, V, cfg)

    csinfo("Time taken to complete job = $t", cfg["suppress_messages"] in TRUELIST)
    is_parallel && rmprocs(workers())

    r
end
