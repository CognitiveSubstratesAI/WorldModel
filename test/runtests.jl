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

    @testset "R10 re-validation closes the ambient loop (slow_step! consumes `stale`)" begin
        # Until now `stale` was DETECTION-ONLY: slow_step! computed it and returned it, and the only
        # reference to `.stale` in the whole codebase was that return — so §7's "factor-graph PLN
        # tightens beliefs" never tightened anything. A decayed belief stayed decayed forever.
        r2 = SpaceRegistry(manifest(; store = mktempdir())); seed_world_model!(r2)
        # `supported` is anchored by two evidence shards; `orphan` is believed but nothing supports it.
        c1 = store_evidence!(r2, "saw-a-tree"; modality = "vision")
        ground!(r2, "supported", "(entity supported tree)", c1)
        c2 = store_evidence!(r2, "saw-it-again"; modality = "vision")
        ground!(r2, "supported", "(entity supported tree)", c2)
        assert_belief!(r2, "supported", 0.8, 0.9, 0.0)
        assert_belief!(r2, "orphan", 0.8, 0.9, 0.0)

        t = 40.0                                        # far enough out that BOTH decay below threshold
        before = stale_beliefs(r2, t; threshold = 0.3, lambda = 0.1)
        @test "supported" in before && "orphan" in before

        res = slow_step!(CognitiveLoop(r2); t = t, threshold = 0.3, lambda = 0.1)
        @test "supported" in res.revalidated            # evidence survives ⇒ refreshed…
        @test !("orphan" in res.revalidated)            # …no evidence ⇒ left to decay, NOT propped up

        # confidence came from the EVIDENCE COUNT through our canonical map (k=1): 2 shards ⇒ 2/(2+1)
        cs = Dict(k => c for (k, _s, c, _t) in beliefs(r2))
        @test isapprox(cs["supported"], 2 / 3; atol = 1e-9)
        @test isapprox(cs["orphan"], 0.9; atol = 1e-9)  # untouched
        # strength is PRESERVED — revalidation refreshes confidence, it does not invent belief
        ss = Dict(k => s for (k, s, _c, _t) in beliefs(r2))
        @test isapprox(ss["supported"], 0.8; atol = 1e-9)

        # and the loop actually CLOSES: the refreshed key is no longer stale at the same `t`
        after = stale_beliefs(r2, t; threshold = 0.3, lambda = 0.1)
        @test !("supported" in after)
        @test "orphan" in after
        @test length(after) < length(before)            # `stale` SHRINKS (was: unchanged forever)
    end

    @testset "node base rates make 2-hop PLN fire END-TO-END (production write path)" begin
        # The 2-hop transitive branch needs node STVs for its endpoints, and NOTHING in production ever
        # wrote one — so it contributed exactly 0.0 to every candidate. This drives the REAL path:
        # ground!(entity …) as mid_step! does → slow_step! computes extensional base rates → deduction
        # has premises. Deliberately NOT hand-asserting node beliefs: doing that is what let the earlier
        # 2-hop test pass over a dead mechanism.
        r3 = SpaceRegistry(manifest(; store = mktempdir())); seed_world_model!(r3)
        for (i, ty) in enumerate(["tree", "tree", "tree", "shade", "shade", "comfort", "rock"])
            cid = store_evidence!(r3, "obs$i"; modality = "vision")
            ground!(r3, "e$i", "(entity e$i $ty)", cid)
        end
        # tree ⇒ shade ⇒ comfort  (all three are PERCEIVED concepts, so all three get base rates).
        # Strengths must be CONSISTENT with those base rates: P(shade|tree) ≤ P(shade)/P(tree) = 2/3,
        # and P(comfort|shade) ≤ P(comfort)/P(shade) = 1/2. (The inconsistent case is asserted below —
        # being able to tell the difference is exactly what having base rates buys.)
        assert_implication!(r3, "tree", "shade", 0.6, 0.9, 0.0)
        assert_implication!(r3, "shade", "comfort", 0.45, 0.9, 0.0)

        @test node_stv(r3, "tree") === nothing          # before: no node STV exists at all
        pre = WorldModel.PLNCore.select_action(r3, "comfort")
        @test !any(a -> a[1] == "tree", pre)            # ⇒ the 2-hop candidate is (correctly) skipped

        res = slow_step!(CognitiveLoop(r3); t = 1.0)
        @test "tree" in res.base_rates && "shade" in res.base_rates

        br = node_stv(r3, "tree")
        @test br !== nothing
        @test isapprox(br.s, 3 / 7; atol = 1e-9)        # 3 trees out of a 7-entity universe
        @test isapprox(br.c, 3 / 4; atol = 1e-9)        # canonical Truth_w2c(3) = 3/(3+1), k = 1

        post = WorldModel.PLNCore.select_action(r3, "comfort")
        tree = findfirst(a -> a[1] == "tree", post)
        @test tree !== nothing                          # the 2-hop candidate now EXISTS…
        @test post[tree][2] > 0.0                       # …and carries a real, non-zero score
        @test any(a -> a[1] == "shade", post)           # 1-hop candidate still present

        # …and the consistency guard is now MEANINGFUL. Same graph, same base rates, but an IMPOSSIBLE
        # link strength (P(shade|tree)=0.9 > P(shade)/P(tree)=2/3) is rejected by `_consistent`, takes the
        # (s=1,c=0) fallback and contributes 0.0. Before base rates existed EVERY deduction failed the
        # guard trivially (as=0), so it discriminated nothing; now it separates possible from impossible.
        r4 = SpaceRegistry(manifest(; store = mktempdir())); seed_world_model!(r4)
        for (i, ty) in enumerate(["tree", "tree", "tree", "shade", "shade", "comfort", "rock"])
            cid = store_evidence!(r4, "obs$i"; modality = "vision")
            ground!(r4, "e$i", "(entity e$i $ty)", cid)
        end
        assert_implication!(r4, "tree", "shade", 0.9, 0.9, 0.0)     # impossible given the base rates
        assert_implication!(r4, "shade", "comfort", 0.45, 0.9, 0.0)
        slow_step!(CognitiveLoop(r4); t = 1.0)
        bad = WorldModel.PLNCore.select_action(r4, "comfort")
        ti = findfirst(a -> a[1] == "tree", bad)
        @test ti !== nothing && bad[ti][2] == 0.0       # inconsistent ⇒ contributes nothing
    end

    @testset "mid_step! records what the agent DID (Senv) ⇒ action/goal symbols get priors" begin
        # Senv is the schema's "environment interface — observations / actions" and was declared but
        # NEVER written: the chosen action lived only in a host-side Julia Dict, outside the substrate.
        # So action/goal symbols had no extension anywhere and could never get a base rate — meaning
        # 2-hop reasoning over the AGENT'S OWN action graph was structurally impossible, independent of
        # the perceptual base rates. This drives mid_step! for real and checks both.
        r5 = SpaceRegistry(manifest(; store = mktempdir())); seed_world_model!(r5)
        assert_implication!(r5, "chop", "wood", 0.5, 0.9, 0.0)      # chop ⇒ wood ⇒ shelter
        assert_implication!(r5, "wood", "shelter", 0.5, 0.9, 0.0)
        lp = CognitiveLoop(r5)
        for i in 1:4
            obs = Observation("frame$i", "vision", "x$i", "(entity x$i log)", Symbol("ep", i),
                Dict(:item => (:thing, :log)))
            mid_step!(lp, obs; goal = "shelter")
        end
        env = atoms(r5, :Senv)
        @test any(a -> startswith(a, "(goal "), env)                # goals pursued are recorded…
        @test any(a -> startswith(a, "(action "), env)              # …and so is the action chosen
        @test any(a -> occursin("wood", a), env)                    # `wood` is the 1-hop pick for shelter

        @test node_stv(r5, "wood") === nothing                      # no prior for an ACTION symbol yet
        res = slow_step!(lp; t = 1.0)
        @test "wood" in res.base_rates                              # now derived from Senv's action universe
        bw = node_stv(r5, "wood")
        @test bw !== nothing && bw.s > 0.0 && bw.c > 0.0
        # `shelter` was pursued every tick ⇒ it is the whole goal universe ⇒ base rate 1.0
        bs = node_stv(r5, "shelter")
        @test bs !== nothing && isapprox(bs.s, 1.0; atol = 1e-9)
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

    @testset "GEO-EVO synthesis over Sprog — weakness-regularized effective fitness (§3.1/§3.10)" begin
        reg8 = SpaceRegistry(manifest(; store=mktempdir()))
        seed_world_model!(reg8)
        # base fitness = adequacy (contains the key action); weakness = length (complexity/fragility).
        # F_eff = F − γW makes the geodesic prefer the WEAKEST-adequate (shortest robust) program.
        base(p) = ("open" in p) ? 1.0 : 0.0
        weak(p) = length(p)
        best, feff, F, W = geo_synthesize!(reg8, base, weak, ["open", "noop", "close"];
            gamma=0.3, pop=24, gens=30, rng=MersenneTwister(11))
        @test "open" in best && F == 1.0                       # adequate
        @test W <= 2                                           # geodesic Occam prior → short/robust
        @test !isempty(programs(reg8))
    end

    @testset "GEO-EVO two-ends — synthesis CONVERGES onto the backward subgoal motif (§3.4)" begin
        reg8b = SpaceRegistry(manifest(; store=mktempdir())); seed_world_model!(reg8b)
        prims = ["a", "b", "c", "d", "e"]
        base(p) = 0.0          # neutral base fitness — only the two-ends pull + Occam drive selection
        weak(p) = length(p)    # weakness = program length
        sg = [Set(["a", "b"])] # one backward subgoal motif (a SUBSET of the primitives)
        # WITHOUT the coupling (μ=0) ≡ the F_eff slice — no pull toward the subgoal
        _, _, _, _, al0 = geo_synthesize!(reg8b, base, weak, prims;
            gamma=0.1, mu=0.0, subgoals=sg, pop=30, gens=40, rng=MersenneTwister(5))
        # WITH the coupling (μ=1): forward synthesis is pulled toward the backward subgoal motif
        bestA, _, _, _, alA = geo_synthesize!(reg8b, base, weak, prims;
            gamma=0.1, mu=1.0, subgoals=sg, pop=30, gens=40, rng=MersenneTwister(5))
        @test alA > al0                          # the two-ends term increased subgoal coverage
        @test alA ≈ 1.0                          # CONVERGED: best covers the whole subgoal motif {a,b}
        @test ("a" in bestA) && ("b" in bestA)   # both subgoal ops are present in the best program
    end

    @testset "TransWeave transfer over Sxfer — BD-residual order-effect certificate (App D, R9)" begin
        reg9 = SpaceRegistry(manifest(; store=mktempdir()))
        seed_world_model!(reg9)
        # a source belief + a target domain that AGREES → small BD residual → safe transfer
        assert_belief!(reg9, "wetGrass_src", 0.8, 0.9, 0.0)
        assert_belief!(reg9, "wetGrass_tgt", 0.75, 0.85, 0.0)
        add_correspondence!(reg9, "rainworld", "wetGrass_src", "wetGrass_tgt")
        @test isapprox(bd_residual(reg9, "rainworld", "wetGrass_src"), 0.05; atol=1e-9)
        @test admit_transfer!(reg9, "rainworld", "wetGrass_src"; eps=0.1) == true
        @test !isempty(transfers(reg9))
        # a brittle transfer (target disagrees strongly) is REJECTED, not silently applied
        assert_belief!(reg9, "snow_tgt", 0.2, 0.8, 0.0)
        add_correspondence!(reg9, "badmap", "wetGrass_src", "snow_tgt")
        @test bd_residual(reg9, "badmap", "wetGrass_src") > 0.5
        @test admit_transfer!(reg9, "badmap", "wetGrass_src"; eps=0.1) == false
    end
end

# WorldModel→lib remediation: WorldModel runs canonical Core/lib algorithms, bisimulation-gated.
include("test_pln_delegation.jl")
include("test_subrep_delegation.jl")
include("test_metamo_delegation.jl")
include("test_moses_delegation.jl")
