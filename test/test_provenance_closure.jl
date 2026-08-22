# v5 §5.4 EVIDENCE VALIDATION — a derived claim cannot SILENTLY survive the retraction of its evidence.
#
# Hyperon Deep-Dive Whitepaper v5 (2026) §5.4 makes evidence anchoring CONDITIONAL. It says plainly
# that anchoring "reduces the risk of untraceable symbolic drift" and is explicitly NOT claimed to
# prevent forgetting, hallucination, or semantic error. It then names six validation procedures that
# are the operational content of the idea. This file implements two of them:
#
#   (3) "provenance-closure checks"
#   (6) "tests that a derived claim cannot silently survive the retraction of its supporting evidence"
#
# 🔴 WHY THIS IS A TEST AND NOT AN AUDIT ROW. Before this file, `store_evidence!` / `ground!` /
# `evidence_of` / `fetch_evidence` existed and were tested — the STORAGE half. Nothing detected a
# `(EvidenceOf key cid)` pointing at a shard that is gone, and nothing could REMOVE a shard to find
# out. So the traceability those 128-bit CIDs exist to provide was ASSERTED, never exercised. v5
# names "corrupted or unavailable blobs" as one of its eight failure modes; this is that mode.
#
# ⚠️ THE LOAD-BEARING ASSERTION IS THE ONE AFTER THE RETRACTION. A test that only checks the intact
# chain proves the happy path and nothing else — the same shape as a margin gate whose negative
# control never collapses. The property has content only if the detector FIRES when the evidence is
# withdrawn. [[feedback_oracle_must_observe_the_defect_class]]

using WorldModel, Test

@testset "v5 §5.4(3,6) — provenance closure survives nothing it should not" begin
    reg = SpaceRegistry(manifest(; store=mktempdir()))
    seed_world_model!(reg)

    # ── an intact chain: evidence -> claim -> back to evidence ────────────────────────────────────
    cid = store_evidence!(reg, "saw-a-tree-at-dusk"; modality="vision")
    ground!(reg, "t1", "(entity t1 tree)", cid)

    @test evidence_of(reg, "t1") == [cid]              # the claim points at its evidence
    @test !isempty(fetch_evidence(reg, cid))           # …and the evidence is really there
    @test isempty(provenance_closure(reg))             # v5(3): nothing dangling

    # ── a SECOND claim on separate evidence, to prove the detector is specific ───────────────────
    cid2 = store_evidence!(reg, "heard-a-bird"; modality="audio")
    ground!(reg, "b1", "(entity b1 bird)", cid2)
    @test isempty(provenance_closure(reg))

    # ── RETRACT the first shard ──────────────────────────────────────────────────────────────────
    n = retract_evidence!(reg, cid)
    @test n >= 1                                       # something was actually removed…
    @test isempty(fetch_evidence(reg, cid))            # …and the shard is genuinely gone

    # 🔴 THE PROPERTY. The claim `t1` still exists in Sent — that is correct and expected; v5 does
    # not ask for cascading deletion. What it forbids is the claim standing SILENTLY. The closure
    # check is what makes it audible.
    dangling = provenance_closure(reg)
    @test !isempty(dangling)                           # ⇐ the assertion this file exists for
    @test ("t1", cid) in dangling

    # SPECIFICITY, both directions: the untouched claim must NOT be reported, or the detector is
    # just "something changed" and would fire on any retraction anywhere.
    @test !any(p -> p[1] == "b1", dangling)
    @test length(dangling) == 1

    # …and the claim itself is still present. Asserted so nobody "fixes" this into a cascade delete:
    # evidence is immutable and claims are indices into it, so removing the index is a DIFFERENT
    # decision from detecting that it dangles.
    @test any(a -> occursin("(entity t1 tree)", a), atoms(reg, :Sent))

    # ── re-anchoring closes the hole ─────────────────────────────────────────────────────────────
    # Re-perception (R2): the same payload yields the SAME content id, so restoring the shard must
    # heal the closure with no change to the claim. This also pins that `content_id` is genuinely
    # content-addressed rather than positional.
    cid_again = store_evidence!(reg, "saw-a-tree-at-dusk"; modality="vision")
    @test cid_again == cid                             # content-addressed, not a fresh id
    @test isempty(provenance_closure(reg))             # the hole is closed
end
