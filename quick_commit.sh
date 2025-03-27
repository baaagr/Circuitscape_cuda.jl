#!/bin/bash

python3 update_version.py 
git add src/core.jl src/raster/advanced.jl src/Circuitscape_cuda.jl Project.toml 
git commit
