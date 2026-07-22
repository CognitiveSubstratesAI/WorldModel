# test_pln_delegation.jl — the WorldModel→lib PLN remediation, proven by bisimulation.
#
# PLNCore delegates PLN deduction to the CANONICAL Core/lib/pln (faithful MeTTa, evaluated through Core's
# interpreter). This test proves (1) lib/pln produces the canonical doc value through WorldModel, and
# (2) it BISIMULATES WorldModel's faithful Julia formula (PLN.truth_deduction) across a corpus — agreeing
# both where the formula computes AND where the consistency preconditions trip the (stv 1 0) fallback.
# Agreement is the gate that makes swapping PLN.jl → PLNCore safe (and lib/pln adds the other 10 formulas
# + the PLN.Derive chainer + the factor graph the Julia stand-in never had).

using Test
using Random
using WorldModel

const PLN = WorldModel.PLN
const PLNCore = WorldModel.PLNCore
mk(s, c) = (s = s, c = c)

@testset "PLN delegation — WorldModel runs canonical lib/pln (bisimulation vs the Julia formula)" begin
    # (1) canonical doc example must come back through Core
    lib = PLNCore.truth_deduction(mk(0.8, 0.9), mk(0.7, 0.85), mk(0.6, 0.8), mk(0.7, 0.9), mk(0.6, 0.85))
    @test lib !== nothing
    @test isapprox(lib.s, 0.6; atol = 1e-3)
    @test isapprox(lib.c, 0.3213; atol = 1e-3)

    # (2) bisimulation sweep — faithful Julia formula ≡ lib/pln across random STVs (compute AND fallback)
    rng = MersenneTwister(20260622)
    rstv() = mk(round(rand(rng); digits = 3), round(0.5 + 0.49 * rand(rng); digits = 3))
    agree = 0
    for _ in 1:80
        P, Q, R, PQ, QR = rstv(), rstv(), rstv(), rstv(), rstv()
        jl = PLN.truth_deduction(P, Q, R, PQ, QR)
        lb = PLNCore.truth_deduction(P, Q, R, PQ, QR)
        @test lb !== nothing
        @test isapprox(jl.s, lb.s; atol = 2e-3)
        @test isapprox(jl.c, lb.c; atol = 2e-3)
        (isapprox(jl.s, lb.s; atol = 2e-3) && isapprox(jl.c, lb.c; atol = 2e-3)) && (agree += 1)
    end
    @test agree == 80
    @info "PLN delegation bisimulation: $agree/80 cases agree (Julia formula ≡ canonical lib/pln)"
end

@testset "PLN canonical multi-hop action-selection on the LIVE path (mid_step!)" begin
    reg = SpaceRegistry(manifest(; store = mktempdir()))
    seed_world_model!(reg)
    # a 2-hop chain to the goal `axe`:  build ⇒ make_axe ⇒ axe  (node STVs chosen so the deduction
    # consistency preconditions pass → the transitive candidate scores > 0)
    for (n, s, c) in (("build", 0.9, 0.9), ("make_axe", 0.8, 0.9), ("axe", 0.7, 0.9))
        assert_belief!(reg, n, s, c, 0.0)
    end
    assert_implication!(reg, "build", "make_axe", 0.85, 0.9, 0.0)
    assert_implication!(reg, "make_axe", "axe", 0.8, 0.9, 0.0)

    pln1 = [a[1] for a in WorldModel.PLN.select_action(reg, "axe")]      # shallow 1-hop scan
    core = [a[1] for a in WorldModel.PLNCore.select_action(reg, "axe")]  # canonical 1-hop + 2-hop

    @test "make_axe" in pln1                       # both find the direct action
    @test !("build" in pln1)                       # the 1-hop scan MISSES the transitive action
    @test "make_axe" in core && "build" in core    # canonical inference finds the deeper action too

    # the live goal loop now selects via the canonical multi-hop selector
    loop = CognitiveLoop(reg)
    obs = Observation("f", "vision", "u", "(entity u x)", :e, Dict(:i => (:x, :u)))
    rr = mid_step!(loop, obs; goal = "axe")
    @test rr.action !== nothing && rr.action[1] in core
    @info "PLN live-path: canonical multi-hop finds transitive `build` the 1-hop scan misses; mid_step! uses it"
end

@testset "PLN absence semantics — the Julia layer must not contradict lib/pln" begin
    # THE COVERAGE GAP THAT LET A REAL BUG THROUGH. The bisimulation sweep above always feeds CONCRETE
    # STVs (`rstv()`), and the 2-hop testset HAND-ASSERTS node beliefs so the preconditions pass — so
    # nothing ever exercised ABSENCE. Both testsets stayed green while the production path was dead:
    # lib/pln declares `(= (STV $stv) (empty))` (pln_core_logic.metta:208) ⇒ an undeclared node yields NO
    # RESULT, but the Julia `node_stv` fabricated `(0.0, 0.0)`. `_consistent` requires `as > 0`, so that
    # fabricated zero always failed the precondition, took the `(stv 1 0)` fallback, and every transitive
    # candidate scored `1.0 * 0.0 = 0.0` — inserted, tied, and meaningless. Nothing in production asserts
    # node STVs, so the *feature* was inert while the *tests* proved the mechanism.
    reg = SpaceRegistry(manifest(; store = mktempdir())); seed_world_model!(reg)

    # (a) the Julia layer reports absence AS absence — never a fabricated zero truth value
    @test WorldModel.node_stv(reg, "never-asserted") === nothing
    @test WorldModel.impl_stv(reg, "no-a", "no-b") === nothing

    # (b) …and lib/pln agrees: an undeclared node STV evaluates to NO result, not a zero STV.
    #     This is the bisimulation the sweep above was missing.
    #
    #     ASSERT ON THE RAW EVALUATION, not on `_eval_stv`. `_eval_stv` returns `nothing` for TWO
    #     different reasons — `isempty(res)` (the library really produced no result) and a regex miss on
    #     the `(stv s c)` shape (the term came back UNREDUCED). Those are opposite facts, and the
    #     collapsed form could not tell them apart: commenting out `(= (STV $stv) (empty))` in
    #     pln_core_logic.metta makes the head reduce to ITSELF, which is a regex miss, which is
    #     `nothing`, which passed. The assertion billed as "the bisimulation the sweep was missing"
    #     therefore observed lib/pln not at all. Caught by a reflective audit, not by the suite.
    _sp = PLNCore._space()
    # PLNCore's OWN `metta_run`/`parse_program` (and its cached lib/pln space) — the identical entry
    # `_eval_stv` uses one line further down, so this observes the production path, not a lookalike.
    _run(e) = PLNCore.metta_run(PLNCore.parse_program(e)[1][2], _sp)
    @test isempty(_run("(STV never-declared-node)"))          # the library genuinely yields NOTHING
    #     POSITIVE CONTROL: the marshaller's non-`nothing` branch must be reachable on the same path,
    #     otherwise "always nothing" would satisfy the check above for the wrong reason.
    @test PLNCore._eval_stv("(Truth_w2c 3)") === nothing      # a Number is not an (stv s c) — shape-checked
    @test PLNCore._eval_stv(
        "(Truth_Deduction (stv 0.8 0.9) (stv 0.7 0.85) (stv 0.6 0.8) (stv 0.7 0.9) (stv 0.6 0.85))"
    ) !== nothing                                             # …and a real formula result DOES marshal
    @test PLNCore._eval_stv("(STV never-declared-node)") === nothing   # the original claim, now backed

    # (c) PRODUCTION SHAPE: a 2-hop chain with NO node STVs (exactly what assert_implication! leaves —
    #     it writes only `a=>b` keys). The transitive candidate must VANISH, not appear at a flat 0.0.
    reg2 = SpaceRegistry(manifest(; store = mktempdir())); seed_world_model!(reg2)
    assert_implication!(reg2, "A", "B", 0.9, 0.9, 0.0)
    assert_implication!(reg2, "B", "goal", 0.9, 0.9, 0.0)
    sc = WorldModel.PLNCore.select_action(reg2, "goal")
    ids = [a[1] for a in sc]
    @test "B" in ids                                  # the 1-hop candidate still ranks
    @test !("A" in ids)                               # the transitive one is SKIPPED (was: inserted at 0.0)
    @test all(v -> v > 0.0, [a[2] for a in sc])       # no candidate may carry a meaningless zero score

    # (d) give the nodes base rates and the SAME chain now yields real discrimination — proving the skip
    #     removed noise rather than capability. (Hand-checked: s = 0.81 + 0.1·(0.7−0.54)/0.4 = 0.85,
    #     c = 0.9⁴ = 0.6561, s·c ≈ 0.5577.)
    for (n, s) in (("A", 0.5), ("B", 0.6), ("goal", 0.7)); assert_belief!(reg2, n, s, 0.9, 0.0); end
    sc2 = WorldModel.PLNCore.select_action(reg2, "goal")
    @test "A" in [a[1] for a in sc2]                  # transitive candidate is back…
    @test all(v -> v > 0.0, [a[2] for a in sc2])      # …and every score is meaningful
    @info "PLN absence: undeclared node ⇒ nothing (Julia) ≡ no result (lib/pln); 2-hop skips vs scores $(round(maximum([a[2] for a in sc2]); digits=4))"
end
