# MeTTaCore backend for WorldModel — a concrete AbstractBackend over the MeTTaCore / MORK substrate.
#
# WorldModel is standalone (no hard deps), so this adapter lives in examples/ rather than as a package
# dependency. Use it from an environment where BOTH WorldModel and MeTTaCore are available:
#
#   pkg> dev /path/to/Core          # MeTTaCore
#   pkg> dev /path/to/WorldModel
#   julia> using WorldModel, MeTTaCore
#   julia> include(joinpath(pkgdir(WorldModel), "examples", "mettacore_backend.jl"))
#   julia> loop = CognitiveLoop(; backend = MeTTaCoreBackend())
#
# The same shape works for a MorkServer / MettaJam socket client (wm_eval / wm_query over the wire) — the
# point of AbstractBackend is that WorldModel never depends on any particular substrate.

using WorldModel
import MeTTaCore

"""
    MeTTaCoreBackend(; space = MeTTaCore.new_core_space())

An [`AbstractBackend`](@ref WorldModel.AbstractBackend) backed by an in-process MeTTaCore space.
`wm_eval` runs a program through the dual-track entry (`mc_run`); `wm_query` counts matches via the
native trie query.
"""
struct MeTTaCoreBackend{S} <: WorldModel.AbstractBackend
    space::S
end
MeTTaCoreBackend(; space=MeTTaCore.new_core_space()) = MeTTaCoreBackend(space)

# Evaluate / run any program (data · rewrites · GSLT theories · def/match/emit · MM2) on the space.
WorldModel.wm_eval(b::MeTTaCoreBackend, program::AbstractString) =
    MeTTaCore.mc_run(b.space, "", program).results

# Query: number of atoms matching `pattern` (read-only native trie query; dollar-var pattern).
WorldModel.wm_query(b::MeTTaCoreBackend, pattern::AbstractString) =
    MeTTaCore.pattern_support_native(b.space, pattern)
