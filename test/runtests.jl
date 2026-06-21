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

    @testset "run_ambient! — one full ambient cycle (§4)" begin
        b = MockBackend(
            Dict(
                raw"(edge $x $y)" => 3,
                raw"(edge $y $z)" => 3,
                raw"(edge $x $y) (edge $y $z)" => 2   # the 2-hop join body (blend support)
            )
        )
        loop = CognitiveLoop(; backend=b)
        r = run_ambient!(loop; candidates=[raw"(edge $x $y)", raw"(edge $y $z)"], minsup=2)
        @test sort(r.focus) == sort([raw"(edge $x $y)", raw"(edge $y $z)"])      # ECAN: both attended
        @test sort(r.frequent) == sort([raw"(edge $x $y)", raw"(edge $y $z)"])   # mining: both support 3
        @test r.blends == [raw"(, (edge $x $y) (edge $y $z))"]                   # blend on shared $y
        @test length(r.beliefs) == 2                                            # factor-PLN
        @test loop.attention[raw"(edge $x $y)"] > 0    # feedback: believed atom keeps STI next cycle
    end

    @testset "goal loop — affordance-based planning (§4 goal-directed)" begin
        loop = CognitiveLoop(; backend=MockBackend())
        affordances = [raw"(, (chop $o) (yields $o $r))", raw"(, (mine $o) (yields $o $r))"]
        beliefs = Dict(
            raw"(, (chop $o) (yields $o $r))" => 0.75,
            raw"(, (mine $o) (yields $o $r))" => 0.6
        )
        # goal: achieve a "yields" outcome → propose the actions, certified by belief, best first
        opts = goal_step!(
            loop, raw"(yields $o wood)"; affordances=affordances, beliefs=beliefs
        )
        @test opts == [(raw"(chop $o)", 0.75), (raw"(mine $o)", 0.6)]   # both yield; chop more certified
        @test loop.tick == 1
        @test goal_step!(loop, raw"(flies $o)"; affordances=affordances) ==
            Tuple{String, Float64}[]  # no match
    end

    @testset "goal loop — multi-hop backward chaining (plan_goal!, §4 explainable chains)" begin
        loop = CognitiveLoop(; backend=MockBackend())
        R1 = raw"(, (yields $o wood) (craft $o plank) (yields $o plank))"   # plank ⟸ wood + craft
        R2 = raw"(, (chop $o) (yields $o wood))"                            # wood  ⟸ chop
        rules = [R1, R2]
        beliefs = Dict(R1 => 0.9, R2 => 0.8)
        plan = plan_goal!(loop, raw"(yields $o plank)"; affordances=rules, beliefs=beliefs)
        @test plan.steps == [raw"(chop $o)", raw"(craft $o plank)"]   # chop (→wood) then craft (→plank)
        @test plan.confidence ≈ 0.72                                  # 0.9 × 0.8 along the chain
        @test loop.tick == 1
        @test plan_goal!(loop, raw"(flies $o)"; affordances=rules) === nothing   # unreachable → nothing
        # a goal already true in the substrate → no actions needed (base case)
        loop2 = CognitiveLoop(; backend=MockBackend(Dict(raw"(yields $o wood)" => 5)))
        p2 = plan_goal!(loop2, raw"(yields $o wood)"; affordances=rules)
        @test p2.steps == String[]
        @test p2.confidence == 1.0
    end

    @testset "ambient steps require a backend" begin
        @test_throws ErrorException ambient_step!(CognitiveLoop())
    end
end
