using WorldModel
using Test

# A MOCK backend — proves WorldModel runs STANDALONE against any AbstractBackend, with no substrate
# package installed. Real backends (MeTTaCore in-process, MorkServer/MettaJam client) plug in the same way.
struct MockBackend <: AbstractBackend end
WorldModel.wm_eval(::MockBackend, program::AbstractString) = "evaluated: $program"
WorldModel.wm_query(::MockBackend, pattern::AbstractString) = String[pattern]

@testset "WorldModel (standalone scaffold)" begin
    @test WorldModel.WORLDMODEL_VERSION == v"0.1.0"

    @testset "pluggable backend — no substrate dependency" begin
        b = MockBackend()
        @test wm_eval(b, "(+ 1 2)") == "evaluated: (+ 1 2)"
        @test wm_query(b, raw"(edge $x $y)") == [raw"(edge $x $y)"]
        loop = CognitiveLoop(; backend=b)
        @test loop.backend === b
        @test loop.tick == 0
    end

    @testset "loop stubs are honestly unwired" begin
        @test_throws ErrorException goal_step!(CognitiveLoop())
        @test_throws ErrorException ambient_step!(CognitiveLoop())
    end
end
