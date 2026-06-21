using WorldModel
using Test
using Random: MersenneTwister

@testset "WorldModel infra spine — real MORK/PathMap substrate" begin
    store = mktempdir()                              # ephemeral store for the test
    m = manifest(; store=store)
    reg = SpaceRegistry(m)

    @testset "dynamic schema seeding (14 Spaces, data-driven)" begin
        seed_world_model!(reg)
        @test length(list_spaces(reg)) == 14
        @test space_kind(reg, :Sent) == SYMBOLIC
        @test space_kind(reg, :Sdyn) == DENSE
        @test space_kind(reg, :Shmh) == HMH
    end

    @testset "scoped add / count — per-Space isolation (separate tries)" begin
        add!(reg, :Sent, "(entity alice) (entity bob)")
        add!(reg, :Srule, "(implies p q)")
        @test count_atoms(reg, :Sent) == 2
        @test count_atoms(reg, :Srule) == 1            # Srule unaffected by Sent
        @test "(entity alice)" in atoms(reg, :Sent)
    end

    @testset ".act persistence round-trip (survives a fresh registry)" begin
        path = persist!(reg, :Sent)
        @test isfile(path)
        reg2 = SpaceRegistry(manifest(; store=store))   # cold: nothing in memory
        create_space!(reg2, :Sent)                         # restores from the .act on disk
        @test count_atoms(reg2, :Sent) == 2
        @test "(entity bob)" in atoms(reg2, :Sent)
    end

    @testset "runtime create / delete (no code change, no hardcoding)" begin
        create_space!(reg, :Scustom)
        add!(reg, :Scustom, "(foo 42)")
        @test has_space(reg, :Scustom) && count_atoms(reg, :Scustom) == 1
        @test delete_space!(reg, :Scustom)
        @test !has_space(reg, :Scustom)
    end

    @testset "dense/HMH Spaces error honestly (registered ≠ backed; no mock)" begin
        @test_throws ErrorException add!(reg, :Sdyn, "(x)")
        @test_throws ErrorException count_atoms(reg, :Shmh)
    end

    @testset "braid: Γ grounding + evidence anchoring + R2 re-perception (§4.3–4.4)" begin
        # obs → evidence shard in Sevid (content-addressed)
        cid = store_evidence!(reg, "frame_0042_block_at_L7"; modality="vision")
        @test !isempty(fetch_evidence(reg, cid))                    # shard retrievable from Sevid
        # Γ: ground an unknown block as an entity in Sent + a spatial hypothesis in Smap, both anchored
        ground!(reg, "u1", "(entity u1 unknown-block)", cid)
        ground!(reg, "u1", "(AtLocation u1 L7)", cid; into=:Smap)
        @test "(entity u1 unknown-block)" in atoms(reg, :Sent)
        # R2: trace the symbol back to its evidence, then re-fetch the raw shard
        @test cid in evidence_of(reg, "u1")
        @test cid in evidence_of(reg, "u1"; into=:Smap)
        shard = fetch_evidence(reg, cid)
        @test any(occursin("frame_0042_block_at_L7", s) for s in shard)
    end

    @testset "beliefs: truth values + staleness decay (R10; §4.7, §6.1.3)" begin
        # competing low-confidence affordance hypotheses for an unknown block (§6.1.2), observed at t=0
        assert_belief!(reg, "Conductor_u1", 0.6, 0.4, 0.0)
        assert_belief!(reg, "Trigger_u1", 0.5, 0.3, 0.0)
        @test ("Conductor_u1", 0.6, 0.4, 0.0) in beliefs(reg)
        @test decayed_confidence(0.4, 0.0, 10.0; lambda=0.1) ≈ 0.4 * exp(-1.0)
        # fresh just after assertion — nothing stale; much later — both decay below threshold (re-validate)
        @test isempty(stale_beliefs(reg, 1.0; threshold=0.2, lambda=0.1))
        st = stale_beliefs(reg, 25.0; threshold=0.2, lambda=0.1)
        @test "Conductor_u1" in st && "Trigger_u1" in st
    end

    @testset "Shmh: HMH episodic memory bound — 𝓔_hmh / recall / 𝓓_hmh (§4.4, §6.1.2)" begin
        # two affordance trials encoded as role-filler episodes into Shmh (real FactorVSA hypervectors)
        encode_hmh!(reg, :trial1,
            Dict(
                :item => (:block, :u1),
                :func => (:role, :conductor),
                :ctx => (:adj, :redstone)
            );
            pointers=["Sent:u1"])
        encode_hmh!(reg, :trial2,
            Dict(
                :item => (:block, :u2), :func => (:role, :insulator), :ctx => (:adj, :stone)
            ))
        # structured recall: a query matching trial1's structure ranks trial1 first, strictly above trial2
        hits = retrieve_hmh(reg,
            Dict(
                :item => (:block, :u1),
                :func => (:role, :conductor),
                :ctx => (:adj, :redstone)
            ); topk=2)
        @test hits[1][1] == :trial1
        @test hits[1][2] > hits[2][2]
        # 𝓓_hmh: dense hypervector of the right dimension; back-pointers preserved
        @test length(densify_hmh(reg, :trial1)) == 1024
        @test "Sent:u1" in record_pointers(hmh_index(reg, :Shmh), :trial1)
        # count_atoms still rejects Shmh (it's HMH-backed, not a MORK trie)
        @test_throws ErrorException count_atoms(reg, :Shmh)
    end

    @testset "dense/green braid: Λ lift + kernel μR + Sdyn FabricPC predictor (§4.5)" begin
        # Λ: retrieve the top Shmh record for a conductor-like query, densify, store as a Sctx context vector
        v = lift!(reg, :ctx1,
            Dict(
                :item => (:block, :u1),
                :func => (:role, :conductor),
                :ctx => (:adj, :redstone)
            ))
        @test length(v) == 1024
        @test has_vec(dense_store(reg, :Sctx), :ctx1)
        # a second context vector, then a kernel-mean μR summary in Skernel
        lift!(
            reg,
            :ctx2,
            Dict(
                :item => (:block, :u2), :func => (:role, :insulator), :ctx => (:adj, :stone)
            )
        )
        s = kernel_summary!(reg, [:ctx1, :ctx2], :mu)
        @test length(s) == 1024 && has_vec(dense_store(reg, :Skernel), :mu)
        # MORKTensorNetworks kernel service directly: μR weights are a distribution; MMD(self)≈0
        ds = dense_store(reg, :Sctx)
        mu, w = kernel_mu([get_vec(ds, :ctx1), get_vec(ds, :ctx2)])
        @test length(mu) == 1024 && isapprox(sum(w), 1.0; atol=1e-6)
        @test isapprox(mmd([get_vec(ds, :ctx1)], [get_vec(ds, :ctx1)]), 0.0; atol=1e-6)
        # Sdyn: bind a real FabricPC predictor and condition it on the context vector (Sctx → Sdyn)
        attach_dynamics!(reg, 1024, 32, 8; rng=MersenneTwister(1))
        @test has_predictor(dense_store(reg, :Sdyn))
        y = predict_dynamics(reg, v; rng=MersenneTwister(2))
        @test length(y) == 8 && all(isfinite, y)
        # DENSE Spaces still reject MORK atom ops
        @test_throws ErrorException add!(reg, :Sdyn, "(x)")
    end

    @testset "two-loop × three-rate cognitive cycle over the braid (§3.1, §3.4, §6.1.4)" begin
        reg2 = SpaceRegistry(manifest(; store=mktempdir()))
        seed_world_model!(reg2)
        loop = CognitiveLoop(reg2)

        # MID (goal cycle): Γ-ground entity + 𝓔ₕₘₕ episode + Λ context vector
        obs = Observation("frame_99_block", "vision", "u9", "(entity u9 unknown-block)",
            :trialA,
            Dict(:item => (:block, :u9), :func => (:role, :conductor)))
        m = mid_step!(loop, obs)
        @test "(entity u9 unknown-block)" in atoms(reg2, :Sent)     # Γ grounded
        @test !isempty(fetch_evidence(reg2, m.cid))                 # evidence anchored
        @test length(m.context_vector) == 1024 && loop.context == :ctx

        # FAST (reflex): no predictor yet → nothing; attach Sdyn predictor → real prediction, no Atomspace query
        @test fast_step!(loop) === nothing
        attach_dynamics!(reg2, 1024, 16, 4; rng=MersenneTwister(3))
        @test length(fast_step!(loop; rng=MersenneTwister(4))) == 4

        # SLOW (ambient): stale-belief re-validation (R10) + HMH consolidation (schema formation)
        assert_belief!(reg2, "Conductor_u9", 0.6, 0.3, 0.0)
        s = slow_step!(loop; t=30.0, threshold=0.2, lambda=0.1)
        @test "Conductor_u9" in s.stale && s.consolidated == :template

        # one full multi-rate cycle advances the tick and runs all three rates
        t0 = loop.tick
        r = run_cycle!(loop; observation=obs, t=1.0, fast=2, rng=MersenneTwister(5))
        @test r.tick > t0 && r.slow.consolidated == :template
    end

    @testset "PLN inference over Srule — deduction + action-selection (§4.7, §6.1.4)" begin
        # PLN deduction matches the Core lib/pln reference example (book §1.4 p.15) → (0.6, 0.3213)
        d = truth_deduction((s=0.8, c=0.9), (s=0.7, c=0.85), (s=0.6, c=0.8),
            (s=0.7, c=0.9), (s=0.6, c=0.85))
        @test isapprox(d.s, 0.6; atol=1e-3) && isapprox(d.c, 0.3213; atol=1e-3)
        # inconsistent conditional probability → ignorance fallback (1,0)
        @test truth_deduction((s=0.8, c=0.9), (s=0.7, c=0.85), (s=0.6, c=0.8),
            (s=0.95, c=0.9), (s=0.6, c=0.85)) == (s=1.0, c=0.0)

        reg3 = SpaceRegistry(manifest(; store=mktempdir()))
        seed_world_model!(reg3)
        # deduction over the real Srule space: nodes + links → derive A⇒C via B
        assert_belief!(reg3, "A", 0.8, 0.9, 0.0)
        assert_belief!(reg3, "B", 0.7, 0.85, 0.0)
        assert_belief!(reg3, "C", 0.6, 0.8, 0.0)
        assert_implication!(reg3, "A", "B", 0.7, 0.9, 0.0)
        assert_implication!(reg3, "B", "C", 0.6, 0.85, 0.0)
        ac = deduce(reg3, "A", "B", "C")
        @test isapprox(ac.s, 0.6; atol=1e-3) && isapprox(ac.c, 0.3213; atol=1e-3)

        # action-selection: rules concluding the goal, ranked by expected payoff s·c
        assert_implication!(reg3, "chop", "wood", 0.9, 0.8, 0.0)
        assert_implication!(reg3, "mine", "wood", 0.5, 0.6, 0.0)
        acts = select_action(reg3, "wood")
        @test acts[1][1] == "chop" && acts[2][1] == "mine"      # chop 0.72 > mine 0.30

        # the goal loop uses it: mid_step! with a goal returns the PLN-selected action
        loop3 = CognitiveLoop(reg3)
        obs3 = Observation(
            "f", "vision", "u", "(entity u block)", :e, Dict(:item => (:block, :u))
        )
        rr = mid_step!(loop3, obs3; goal="wood")
        @test rr.action !== nothing && rr.action[1] == "chop"
    end

    @testset "SubRep option admission over Sopt — CDS gate + certificate + reuse (§A.10)" begin
        reg4 = SpaceRegistry(manifest(; store=mktempdir()))
        seed_world_model!(reg4)
        @test cds_margin(0.5, [0.25, 0.25]) ≈ 0.75
        @test admit_option!(reg4, "skillA", 0.5, [0.25, 0.25]) == true   # helps both motives
        @test admit_option!(reg4, "skillB", 0.0, [0.3, -0.5]) == false   # margin -0.5 < 0 → reject
        @test "skillA" in admitted_options(reg4) && !("skillB" in admitted_options(reg4))
        @test admit_option!(reg4, "skillC", 0.0, [0.3, -0.05]; eps=-0.1) == true  # budgeted
        # zero-shot reuse: re-score under a motive-1 weighting straight from the certificates
        reused = reuse_options(reg4, [1.0, 0.0])
        @test reused[1][1] == "skillA"      # 0.5+0.25 = 0.75 beats skillC's 0.0+0.3
    end

    @testset "WILLIAM pattern mining over a Space into Smine (§A.13)" begin
        reg5 = SpaceRegistry(manifest(; store=mktempdir()))
        seed_world_model!(reg5)
        add!(reg5, :Sent,
            "(chop tree wood) (chop tree wood) (chop rock stone) (mine rock stone) (mine rock stone)"
        )
        pats = mine!(reg5; from=:Sent, k=5)
        @test !isempty(pats)                                   # WILLIAM found frequent patterns
        @test any(occursin("chop", p) for (p, w) in pats)      # the recurring (chop …) structure
        @test !isempty(mined_patterns(reg5))                   # stored in Smine
    end

    @testset "MetaMo motive governor over Smotive — appraise/damp/decide (§A.9)" begin
        reg6 = SpaceRegistry(manifest(; store=mktempdir()))
        seed_world_model!(reg6)
        set_motive!(reg6, "explore", 0.3)
        set_motive!(reg6, "survive", 0.5)
        @test dominant_motive(reg6)[1] == "survive"            # 0.5 > 0.3
        # govern: a strong explore stimulus, HOMEOSTATICALLY DAMPED to ±max_drift, raises it past survive
        dom = govern!(reg6, Dict("explore" => 0.9); max_drift=0.3)   # 0.3 + clamp(0.9,±0.3) = 0.6
        @test dom[1] == "explore" && isapprox(dom[2], 0.6; atol=1e-9)
        # safe projection: urgency stays in [0,1] under a huge stimulus
        govern!(reg6, Dict("explore" => 5.0); max_drift=10.0)
        @test motives(reg6)["explore"] <= 1.0
    end

    @testset "MOSES evolutionary program synthesis over Sprog (§A.12)" begin
        reg7 = SpaceRegistry(manifest(; store=mktempdir()))
        seed_world_model!(reg7)
        # fitness rewards matching the target sequence; MOSES evolves toward it
        target = ["chop", "craft"]
        fit(p) =
            -abs(length(p) - length(target)) +
            sum(i <= length(p) && p[i] == target[i] for i in 1:length(target))
        best, f = synthesize!(reg7, fit, ["chop", "craft", "mine", "place"];
            pop=24, gens=30, rng=MersenneTwister(7))
        @test best == target && f == length(target)            # found the optimum
        @test !isempty(programs(reg7))                         # stored in Sprog
    end
end
