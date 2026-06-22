# test_subrep_delegation.jl — the WorldModel→lib SubRep remediation, proven.
#
# SubRepCore delegates to the canonical Core/lib/subrep. This proves (1) WorldModel's CDS simplex gate
# BISIMULATES the real lib/subrep/cds.metta across a corpus, and (2) PDS (pds-eps-admit) — absent from
# WorldModel's SubRep.jl entirely — admits a complementary option that CDS rejects: the real capability
# the Julia stand-in (1 of ~9 mechanisms) never had.

using Test
using Random
using WorldModel

const SubRep = WorldModel.SubRep
const SubRepCore = WorldModel.SubRepCore

@testset "SubRep delegation — WorldModel runs canonical lib/subrep (CDS bisimulation + NEW PDS)" begin
    # (1) bisimulation: WorldModel's CDS simplex gate ≡ lib/subrep, over random (Δr, Δn, ε)
    rng = MersenneTwister(20260622)
    agree = 0
    for _ in 1:80
        dr = round(2 * rand(rng) - 1; digits = 3)
        dn = [round(2 * rand(rng) - 1; digits = 3) for _ in 1:rand(rng, 1:4)]
        eps = round(0.3 * rand(rng); digits = 3)
        jm = SubRep.cds_margin(dr, dn)
        lm = SubRepCore.cds_margin(dr, dn)
        @test lm !== nothing
        @test isapprox(jm, lm; atol = 1e-6)
        @test SubRep.cds_admit(dr, dn, eps) == SubRepCore.cds_admit(dr, dn, eps)
        (isapprox(jm, lm; atol = 1e-6) &&
         SubRep.cds_admit(dr, dn, eps) == SubRepCore.cds_admit(dr, dn, eps)) && (agree += 1)
    end
    @test agree == 80

    # (2) NEW capability — PDS admits a complementary option CDS rejects (margin = -0.05 ∈ [-ε, 0))
    dr, dn, eps = 0.1, [-0.15], 0.1
    @test SubRepCore.cds_admit(dr, dn, 0.0) == false   # CDS rejects (margin < 0)
    @test SubRepCore.pds_admit(dr, dn, eps) == true    # PDS admits — the option CDS rejects
    @test !isdefined(SubRep, :pds_admit)               # WorldModel's SubRep.jl has NO PDS at all
    @info "SubRep delegation: $agree/80 CDS bisimulation agree; PDS admits the option CDS rejects (new capability)"
end
