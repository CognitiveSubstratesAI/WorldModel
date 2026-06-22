# test_moses_delegation.jl — the WorldModel→lib MOSES slice (the 4th and last).
#
# WorldModel's MOSES.jl is a plain GA over token-lists with an opaque caller fitness (~4.6% of lib/MOSES).
# This is NOT a bisimulation (no shared representation) — it proves the REAL lib/MOSES (typed trees + knobs
# + reduce-to-elegance + metapopulation) runs via Core and exposes capability the GA toy never had:
# truth-table BEHAVIORAL scoring + the metapopulation search loop. The full OR-induction search is ~69s
# (out-of-band, as the lib's own test keeps it); the fast ops are exercised here.

using Test
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
