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

@testset "SubRep ambient option certification on the LIVE path (slow_step!)" begin
    reg = SpaceRegistry(manifest(; store = mktempdir()))
    seed_world_model!(reg)
    # the ambient loop's source: proposed option-candidates with their backed-up improvement (Δr, Δn)
    SubRepCore.propose_option!(reg, "dominating", 0.5, [0.25, 0.25])   # margin +0.75  → CDS admits
    SubRepCore.propose_option!(reg, "complementary", 0.1, [-0.15])     # margin -0.05  → CDS rejects, PDS admits
    SubRepCore.propose_option!(reg, "bad", 0.0, [-0.5])               # margin -0.5   → both reject

    loop = CognitiveLoop(reg)
    s = slow_step!(loop; t = 1.0, eps_pds = 0.1)                       # the ambient cycle runs canonical SubRep
    @test "dominating" in s.admitted.cds          # CDS admits the dominating option
    @test "complementary" in s.admitted.pds       # PDS admits the complementary one CDS rejects (NEW capability)
    @test "bad" in s.admitted.rejected            # both reject the dominated option
    @test "dominating" in admitted_options(reg)   # stored in the REAL Sopt space
    @test "complementary" in admitted_options(reg)
    @test !("bad" in admitted_options(reg))

    # idempotent — a second ambient pass admits nothing new
    s2 = slow_step!(loop; t = 2.0)
    @test isempty(s2.admitted.cds) && isempty(s2.admitted.pds)
    @info "SubRep ambient: CDS admitted `dominating`, PDS admitted `complementary` (CDS rejects), live on slow_step!"
end
