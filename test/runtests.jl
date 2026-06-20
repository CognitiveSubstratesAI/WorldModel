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

    @testset "ambient loop — minimal mining slice (§4 / §7.3 support)" begin
        b = MockBackend(Dict(raw"(edge $x $y)" => 3, raw"(rare $x)" => 1))
        loop = CognitiveLoop(; backend=b)
        freq = ambient_step!(loop; candidates=[raw"(edge $x $y)", raw"(rare $x)"], minsup=2)
        @test freq == [raw"(edge $x $y)"]                # support 3 ≥ 2 kept; rare (1) dropped
        @test loop.tick == 1
        @test ambient_step!(loop; candidates=String[]) == String[]   # no candidates → empty
        @test loop.tick == 2
    end

    @testset "unwired without a backend / goal loop is a stub" begin
        @test_throws ErrorException goal_step!(CognitiveLoop())
        @test_throws ErrorException ambient_step!(CognitiveLoop())   # no backend
    end
end
