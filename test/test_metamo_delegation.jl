# test_metamo_delegation.jl — the WorldModel→lib MetaMo slice.
#
# WorldModel's MetaMo.jl is a scalar clamp + argmax (shape-only). Its flat motive dict does NOT map onto
# lib/metamo's 8 semantically-fixed OpenPsi goals, so this is NOT a bisimulation — it proves the REAL
# OpenPsi mechanisms run via Core and adds capability WorldModel never had: (1) the genuine safe-region
# projection (floors gInd to θ_safe where the [0,1] clamp can't), and (2) the OpenPsi appraisal Ψ.

using Test
using WorldModel

const MetaMo = WorldModel.MetaMo
const MetaMoCore = WorldModel.MetaMoCore

@testset "MetaMo delegation — canonical lib/metamo (safe-region projection + OpenPsi appraisal Ψ)" begin
    safe_g = [0.5, 0.75, 0.2, 0.2, 0.2, 0.2, 0.2, 0.2]
    safe_m = fill(0.5, 6)
    unsafe_g = [0.1, 0.75, 0.5, 0.5, 0.5, 0.5, 0.5, 0.5]   # gInd 0.1 < θ_safe 0.3 ⇒ unsafe
    unsafe_m = fill(0.5, 6)

    # (1) boundary pressure: 0 inside R, 1 over the boundary
    @test MetaMoCore.boundary_pressure(safe_g, safe_m) == 0.0
    @test MetaMoCore.boundary_pressure(unsafe_g, unsafe_m) == 1.0

    # (2) NEW capability — real safe-region projection restores safety where a [0,1] clamp cannot
    @test MetaMoCore.in_safe_region(unsafe_g, unsafe_m) == false
    g2, m2 = MetaMoCore.project_to_safe(unsafe_g, unsafe_m)
    @test MetaMoCore.in_safe_region(g2, m2) == true        # projection RESTORES safety
    @test isapprox(g2[1], 0.3; atol = 1e-6)                # gInd floored to θ_safe
    naive = clamp(unsafe_g[1], 0.0, 1.0)                   # WorldModel's analog: per-component [0,1] clamp
    @test naive == 0.1 && naive < 0.3                      # the clamp leaves it UNSAFE — the capability gap

    # (3) NEW capability — full OpenPsi appraisal Ψ: 4-channel stimulus → 6 modulators
    appr = MetaMoCore.appraise(safe_g, safe_m, [0.2, 0.8, 0.1, 0.2])
    @test length(appr) == 6
    @test all(0.0 .<= appr .<= 1.0)
    @test appr != safe_m                                   # the appraisal moved the modulators

    # WorldModel's MetaMo.jl has NONE of these (scalar clamp + argmax only)
    @test !isdefined(MetaMo, :project_to_safe)
    @test !isdefined(MetaMo, :appraise)
    @test !isdefined(MetaMo, :boundary_pressure)
    @info "MetaMo delegation: projection floors gInd 0.1→0.3 (clamp can't); OpenPsi Ψ → $(length(appr)) modulators"
end
