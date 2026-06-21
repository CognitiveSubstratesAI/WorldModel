# Kernel.jl — the kernel / MKME cross-cutting service for Skernel (§4.5, App C, A.15).
#
# Kernel feature maps φ(·) and mean embeddings μR summarize SETS of vectors (retrieved HMH items, Sctx
# context vectors) into a single dense vector, with relevance weights for gating + re-ranking, and provide
# distribution-to-distance (MMD). Per Appendix A.15 this is a CROSS-CUTTING SERVICE (not a store): the
# Skernel Space stores the resulting summaries, but the computation lives here. This is the ONLY module
# that touches MORKTensorNetworks (the project's kernel / semiring / tensor-network substrate).

module Kernel

using MORKTensorNetworks: SumProductSemiring, semiring_matmul

export gram, kernel_mu, mmd

# Gram (kernel) matrix of row-vectors `X` (n×d): G = X·Xᵀ via the sum-product semiring matmul (MORKTN).
gram(X::AbstractMatrix) = semiring_matmul(SumProductSemiring(), X, permutedims(X))

# stack a set of vectors into an n×d row matrix
_rows(vectors) = reduce(vcat, (permutedims(Float64.(v)) for v in vectors))

_softmax(v) = (e=exp.(v .- maximum(v)); e ./ sum(e))

"""
    kernel_mu(vectors) -> (mu, weights)

Kernel mean embedding μR (MKME, §4.5 / App C): a kernel-centrality-weighted set→vector summary. Builds the
Gram matrix (MORKTensorNetworks sum-product semiring matmul), weights each vector by its mean kernel
similarity to the set (softmax → relevance weights for gating / re-ranking), and returns the weighted
summary `mu = Σ wᵢ xᵢ` together with the weights `w`. Reduces to the plain mean when all vectors are
equidistant — but kernel-central vectors dominate, which an arithmetic mean cannot express.
"""
function kernel_mu(vectors::AbstractVector{<:AbstractVector{<:Real}})
    isempty(vectors) && error("kernel_mu: empty set")
    X = _rows(vectors)                                  # n×d
    G = gram(X)                                         # n×n kernel matrix (MORKTN semiring matmul)
    relevance = vec(sum(G; dims=2)) ./ size(G, 2)     # mean kernel similarity of each vector to the set
    w = _softmax(relevance)
    mu = vec(permutedims(w) * X)                        # Σ wᵢ xᵢ
    return (mu, w)
end

"""
    mmd(A, B) -> Float64

Maximum-mean-discrepancy distance between two sets (distribution-to-distance, App A.15):
`√( ⟨K_AA⟩ − 2⟨K_AB⟩ + ⟨K_BB⟩ )`, with all Gram blocks computed via the MORKTensorNetworks semiring matmul.
"""
function mmd(
    A::AbstractVector{<:AbstractVector{<:Real}}, B::AbstractVector{<:AbstractVector{<:Real}}
)
    XA = _rows(A)
    XB = _rows(B)
    kaa = sum(gram(XA)) / (size(XA, 1)^2)
    kbb = sum(gram(XB)) / (size(XB, 1)^2)
    kab =
        sum(semiring_matmul(SumProductSemiring(), XA, permutedims(XB))) /
        (size(XA, 1) * size(XB, 1))
    return sqrt(max(0.0, kaa - 2kab + kbb))
end

end # module Kernel
