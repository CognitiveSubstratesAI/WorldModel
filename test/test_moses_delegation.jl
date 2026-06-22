# test_moses_delegation.jl — the WorldModel→lib MOSES slice (the 4th and last).
#
# WorldModel's MOSES.jl is a plain GA over token-lists with an opaque caller fitness (~4.6% of lib/MOSES).
# This is NOT a bisimulation (no shared representation) — it proves the REAL lib/MOSES (typed trees + knobs
# + reduce-to-elegance + metapopulation) runs via Core and exposes capability the GA toy never had:
# truth-table BEHAVIORAL scoring + the metapopulation search loop. The full OR-induction search is ~69s
# (out-of-band, as the lib's own test keeps it); the fast ops are exercised here.

using Test
using Random
using WorldModel

const MOSES = WorldModel.MOSES
const MOSESCore = WorldModel.MOSESCore

@testset "MOSES delegation — canonical lib/MOSES (truth-table scoring + metapopulation search)" begin
    OR = "(((False False) False) ((False True) True) ((True False) True) ((True True) True))"

    # (1) REAL truth-table behavioral scoring: the leaf program `a` scores -1 on OR (1 mismatch row).
    #     WorldModel's GA has no program/table semantics — only an opaque caller fitness over token-lists.
    @test MOSESCore.score_on_table("(mkTree (mkNode a) ())", "(a b)", OR) == -1.0

    # (2) the metapopulation search loop (runMoses base case) selects the best exemplar of the pool
    @test MOSESCore.run_moses("0 0 5 (a b) $OR 3 6 ((mkXmplr A 0) (mkXmplr B -2))") == "(mkXmplr A 0)"

    # WorldModel's MOSES.jl has NONE of the canonical machinery (token-list GA only)
    @test isdefined(MOSES, :synthesize!)                  # the GA toy it does have
    @test !isdefined(MOSES, :score_on_table)              # no truth-table behavioral scoring
    @test !isdefined(MOSES, :run_moses)                   # no metapopulation search
    @info "MOSES delegation: lib/MOSES scores leaf `a`=-1 on OR + runs the metapopulation loop (full ~69s OR-induction out-of-band)"
end

@testset "MOSES/GEO-EVO synthesis on the LIVE ambient path (slow_step!) — the unified mode toggle" begin
    reg = SpaceRegistry(manifest(; store = mktempdir()))
    seed_world_model!(reg)
    prims = ["a", "b", "c", "d"]
    fitness(p) = ("a" in p) ? 1.0 : 0.0     # reward using primitive `a`
    weakness(p) = length(p) * 0.1           # penalize length
    loop = CognitiveLoop(reg)

    # MOSES mode — no backward subgoals: Score = F − γW, align ≡ 0 (forward-only)
    sM = slow_step!(loop; t = 1.0,
        synthesis = (fitness = fitness, weakness = weakness, primitives = prims, rng = MersenneTwister(1)))
    @test sM.synthesized !== nothing
    @test sM.synthesized[5] == 0.0          # align == 0 ⇒ MOSES (no two-ends coupling)

    # GEO-EVO mode — backward subgoal motif {c,d} + μ>0: the two-ends coupling pulls toward covering it
    sG = slow_step!(loop; t = 2.0,
        synthesis = (fitness = fitness, weakness = weakness, primitives = prims,
            mu = 3.0, subgoals = [["c", "d"]], rng = MersenneTwister(2)))
    @test sG.synthesized !== nothing
    @test sG.synthesized[5] > 0.0           # align > 0 ⇒ GEO-EVO two-ends engaged (program covers the subgoal)
    @test !isempty(programs(reg))           # synthesized program stored in the REAL Sprog
    @info "Synthesis live on slow_step!: MOSES align=0; GEO-EVO align=$(round(sG.synthesized[5]; digits=3)) (subgoal-coupled)"
end

@testset "GEO-EVO on the CANONICAL geometric engine (geo_step!) — live on slow_step!" begin
    reg = SpaceRegistry(manifest(; store = mktempdir()))
    seed_world_model!(reg)
    prims = ["a", "b", "c", "d"]
    fitness(p) = length(intersect(Set(p), Set(["c", "d"]))) / 2.0   # reward covering the backward subgoal {c,d}
    loop = CognitiveLoop(reg)

    # engine=:geometric ⇒ MorkSupercompiler geo_step! (DAGStore demes + EDA + backward motif field), per spec
    sG = slow_step!(loop; t = 1.0,
        synthesis = (fitness = fitness, weakness = (p) -> 0.0, primitives = prims,
            engine = :geometric, subgoals = [["c", "d"]], goal = :G, rng = MersenneTwister(7)))
    @test sG.synthesized !== nothing
    best, align = sG.synthesized
    @test align > 0.0                       # the geodesic two-ends coupling drove the demes toward {c,d}
    @test !isempty(programs(reg))           # program stored in the REAL Sprog via geo_step!
    @info "GEO-EVO geometric (geo_step!) live on slow_step!: align=$(round(align; digits=3)), best=$best"
end
