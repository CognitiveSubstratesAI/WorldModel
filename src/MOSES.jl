# MOSES.jl — evolutionary program synthesis over Sprog (§4 goal loop, Appendix A.12).
#
# Sprog hosts candidate programs/macros discovered by MOSES: search → simulate → evaluate → promote (→Sopt
# via SubRep). This ports the evolve-score-select CORE — a population of candidate programs (sequences of
# primitives) optimized under a fitness function, with elitism and mutation — and stores the best in Sprog.
#
# HONEST DEPTH LIMIT (not faked): MOSES's signature is NOT a plain GA — it is estimation-of-distribution
# search over a structured representation with reduce-to-elegance simplification (the deeper MeTTa system
# in Core/lib/MOSES). This module is the evolutionary search core that drives Sprog; the representation
# building + reduce-to-elegance are a documented gap. A per-Space PROCESS that writes programs into Sprog.

module MOSES

using ..Registry: SpaceRegistry, add!, query_head
using Random: AbstractRNG, default_rng
using MorkSupercompiler: geo_cover   # GeoEvo two-ends coupling kernel (subgoal coverage)

export synthesize!, geo_synthesize!, programs

_to_atom(prog::Vector{String}) = "(program (" * join(prog, " ") * "))"

# one structural mutation of a program: replace / insert / delete a primitive
function _mutate(prog::Vector{String}, prims, rng::AbstractRNG)
    p = copy(prog)
    op = rand(rng, 1:3)
    if op == 1 && !isempty(p)
        p[rand(rng, 1:length(p))] = rand(rng, prims)
    elseif op == 2
        insert!(p, rand(rng, 1:(length(p) + 1)), rand(rng, prims))
    elseif !isempty(p) && length(p) > 1
        deleteat!(p, rand(rng, 1:length(p)))
    end
    return p
end

"""
    synthesize!(reg, fitness, primitives; pop=12, gens=8, maxlen=4, into=:Sprog, rng) -> (best, fitness)

MOSES-style evolutionary program synthesis (§A.12): evolve a population of candidate programs (sequences of
`primitives`) under `fitness::Vector{String}->Real`, keeping the elite each generation and mutating to
refill, then store the best as `(program (…))` in Sprog. Returns the best program and its fitness.
"""
function synthesize!(reg::SpaceRegistry, fitness,
    primitives::AbstractVector{<:AbstractString};
    pop::Int=12, gens::Int=8, maxlen::Int=4, into::Symbol=:Sprog,
    rng::AbstractRNG=default_rng())
    prims = String.(primitives)
    population = [String[rand(rng, prims) for _ in 1:rand(rng, 1:maxlen)] for _ in 1:pop]
    best = population[1]
    bestf = fitness(best)
    for _ in 1:gens
        scored = sort([(p, float(fitness(p))) for p in population]; by=x -> -x[2])
        if scored[1][2] > bestf
            best, bestf = scored[1][1], scored[1][2]
        end
        elite = [p for (p, _f) in scored[1:max(2, pop ÷ 4)]]
        population = copy(elite)
        while length(population) < pop
            push!(population, _mutate(rand(rng, elite), prims, rng))
        end
    end
    add!(reg, into, _to_atom(best))
    return (best, bestf)
end

"""
    geo_synthesize!(reg, fitness, weakness, primitives; gamma=0.3, mu=0.0, subgoals=[], kwargs...)
        -> (best, Score, F, W, align)

GEO-EVO program synthesis. The §3.1/§3.10 weakness regularizer PLUS the §3.4/§3.5 **two-ends-of-the-path
coupling**: programs are pulled toward the nearest BACKWARD subgoal motif (a set of primitive names a
subgoal needs) via the GeoEvo `geo_cover` kernel. The control-law score is

    Score(p) = F(p) − γ·W(p) + μ·align(p),   align(p) = maxₖ Cover(ops(p), motifₖ)

so forward synthesis (population) and backward subgoals co-adapt — the population evolves toward covering a
subgoal while staying weakness-regularized. With the default (`μ=0`, no `subgoals`) this reduces EXACTLY to
the F_eff slice `F − γW`. `subgoals` is a list of `Set`/collection of primitive-name strings. Returns the
best program and `(Score, F, W, align)`.

NOTE: this closes the two-ends loop at the WorldModel program level because `synthesize!`'s mutation samples
from the primitive set (so selection under `align` can reach subgoal ops). The DAGStore `geo_step!` engine
(MorkSupercompiler) has a separate forward-variation closure gap (random head mutation) — tracked as (a).
Still deferred (Geo-Evo.pdf): Sinkhorn deme↔subgoal pairing over many demes, corridor/bandit orchestration,
the Schrödinger-bridge action functional.
"""
function geo_synthesize!(reg::SpaceRegistry, fitness, weakness,
    primitives::AbstractVector{<:AbstractString}; gamma::Real=0.3, mu::Real=0.0,
    subgoals::AbstractVector=Any[], kwargs...)
    motifs = [Set(Symbol(x) for x in sg) for sg in subgoals]
    align(p) = isempty(motifs) ? 0.0 : maximum(geo_cover(Set(Symbol.(p)), m) for m in motifs)
    score(p) = float(fitness(p)) - gamma * float(weakness(p)) + mu * align(p)
    best, _ = synthesize!(reg, score, primitives; kwargs...)
    return (best, score(best), float(fitness(best)), float(weakness(best)), align(best))
end

"The synthesized program atoms currently in Sprog."
programs(reg::SpaceRegistry; into::Symbol=:Sprog) = query_head(reg, into, "program")

end # module MOSES
