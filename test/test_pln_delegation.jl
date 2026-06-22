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
