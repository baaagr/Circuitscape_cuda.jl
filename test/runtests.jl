using Circuitscape_cuda
using Test
import Circuitscape_cuda: compute_single, compute_cholmod, compute_parallel,
                     compute_cg_amg, compute_gpu, runtests
using Logging
Logging.disable_logging(Logging.Info)

# Unit tests for internals
@testset "Unit tests" begin
    include("internal.jl")
end

#for f in (compute, compute_cholmod, compute_parallel)
#for f in (compute,)
for f in (compute_gpu, compute_cg_amg)
    runtests(f)
end
