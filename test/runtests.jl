using WorldModel
using Test

# A MOCK backend — proves WorldModel runs STANDALONE against any AbstractBackend, with no substrate
# package installed. `wm_query` returns a configurable support count (§7.3 support / match-count).
struct MockBackend <: AbstractBackend
    supports::Dict{String, Int}
end
MockBackend() = MockBackend(Dict{String, Int}())
WorldModel.wm_eval(::MockBackend, program::AbstractString) = "evaluated: $program"
WorldModel.wm_query(b::MockBackend, pattern::AbstractString) = get(b.supports, pattern, 0)

@testset "WorldModel (standalone scaffold)" begin
    @test WorldModel.WORLDMODEL_VERSION == v"0.1.0"

    @testset "pluggable backend — no substrate dependency" begin
        b = MockBackend(Dict(raw"(edge $x $y)" => 3))
        @test wm_eval(b, "(+ 1 2)") == "evaluated: (+ 1 2)"
        @test wm_query(b, raw"(edge $x $y)") == 3        # support count
        @test wm_query(b, raw"(missing $x)") == 0
        loop = CognitiveLoop(; backend=b)
        @test loop.backend === b
        @test loop.tick == 0
    end

    @testset "ECAN — attention diffusion (§4 / §5.5 STI conservation)" begin
        loop = CognitiveLoop(; backend=MockBackend())
        # boost two atoms, rent 0 → STI = normalized boost (edge 3/4, rare 1/4); focus = both (> 0)
        focus = attention_step!(
            loop; boost=Dict(raw"(edge $x $y)" => 3.0, raw"(rare $x)" => 1.0), rent=0.0
        )
        @test focus == sort([raw"(edge $x $y)", raw"(rare $x)"])
        @test loop.attention[raw"(edge $x $y)"] ≈ 0.75
        @test loop.attention[raw"(rare $x)"] ≈ 0.25
        @test sum(values(loop.attention)) ≈ 1.0          # §5.5 conservation: STI sums to unity
        @test loop.tick == 1
        # focus_threshold drops the low-STI atom (rare 0.25)
        @test attention_step!(loop; rent=0.0, focus_threshold=0.5) == [raw"(edge $x $y)"]
    end

    @testset "ambient loop — minimal mining slice (§4 / §7.3 support)" begin
        b = MockBackend(Dict(raw"(edge $x $y)" => 3, raw"(rare $x)" => 1))
        loop = CognitiveLoop(; backend=b)
        freq = ambient_step!(loop; candidates=[raw"(edge $x $y)", raw"(rare $x)"], minsup=2)
        @test freq == [raw"(edge $x $y)"]                # support 3 ≥ 2 kept; rare (1) dropped
        @test loop.tick == 1
        @test ambient_step!(loop; candidates=String[]) == String[]   # no candidates → empty
        @test loop.tick == 2
    end

    @testset "concept blending — minimal pushout slice (§4 / category-theoretic)" begin
        # (edge $x $y) & (edge $y $z) share $y (the generic space) → blend; the join body has support 2
        b = MockBackend(Dict(raw"(edge $x $y) (edge $y $z)" => 2))
        loop = CognitiveLoop(; backend=b)
        @test blend_step!(loop, [raw"(edge $x $y)", raw"(edge $y $z)"]; minsup=2) ==
            [raw"(, (edge $x $y) (edge $y $z))"]
        @test loop.tick == 1
        # (edge $x $y) & (color $z) share NO variable → no blend (empty generic space)
        @test blend_step!(loop, [raw"(edge $x $y)", raw"(color $z)"]) == String[]
    end

    @testset "factor-PLN — belief tightening (§4 / §1b evidence→TV)" begin
        b = MockBackend(Dict(raw"(edge $x $y)" => 9, raw"(rare $x)" => 1))
        loop = CognitiveLoop(; backend=b)
        beliefs = pln_step!(loop, [raw"(edge $x $y)", raw"(rare $x)"]; k=1)
        @test beliefs[1] == (raw"(edge $x $y)", 9, 0.9)   # confidence 9/(9+1) rises with evidence
        @test beliefs[2] == (raw"(rare $x)", 1, 0.5)       # 1/(1+1)
        @test loop.tick == 1
    end

    @testset "unwired without a backend / goal loop is a stub" begin
        @test_throws ErrorException goal_step!(CognitiveLoop())
        @test_throws ErrorException ambient_step!(CognitiveLoop())   # no backend
    end
end
