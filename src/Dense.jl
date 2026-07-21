# Dense.jl — the dense substrate for the green Spaces (Sctx context, Sdyn dynamics, Skernel summaries).
#
# Green-primary Spaces hold dense vectors (§4.2, App A.7/A.8). Sctx aggregates context vectors from Λ
# (densified-HMH retrieval + symbolic lifting); Skernel holds kernel-mean (μR) set→vector summaries; Sdyn
# hosts a predictive-coding model (FabricPC). This is the ONLY module that touches FabricPC + dense arrays,
# mirroring Substrate.jl (MORK) and HMHStore.jl (HMH).

module Dense

using FabricPC: graph, Linear, Edge, predict, initialize_params, TaskMap, InferenceSGD,
    train_pcn, AdamW
using Random: AbstractRNG, default_rng

export DenseStore, dense_fresh, put_vec!, get_vec, vec_keys, has_vec,
    attach_predictor!, predict_dense, has_predictor, train_dense!

"A dense Space: named dense vectors + an optional FabricPC predictive-coding model (Sdyn)."
mutable struct DenseStore
    vectors::Dict{Symbol, Vector{Float64}}
    model::Any        # (params, structure) FabricPC predictor, or nothing
end
dense_fresh() = DenseStore(Dict{Symbol, Vector{Float64}}(), nothing)

"Store dense vector `v` under `key`."
put_vec!(ds::DenseStore, key::Symbol, v::AbstractVector{<:Real}) =
    (ds.vectors[key]=Float64.(v); v)
"The dense vector under `key`."
get_vec(ds::DenseStore, key::Symbol) = ds.vectors[key]
"Is `key` present?"
has_vec(ds::DenseStore, key::Symbol) = haskey(ds.vectors, key)
"All stored vector keys."
vec_keys(ds::DenseStore) = sort!(collect(keys(ds.vectors)))

# NOTE: kernel mean embedding μR is NOT here — it is the kernel/MKME service in Kernel.jl, backed by
# MORKTensorNetworks (a sum-product semiring matmul Gram), per the Space→package mapping. Dense.jl only
# stores the resulting summary vectors; it does not compute kernels.

"""
    attach_predictor!(ds, in_dim, hidden, out_dim; rng) -> ds

Bind a FabricPC predictive-coding model to this dense Space (Sdyn): an `x → h → y` PC graph with
initialized params. The STRUCTURE + forward pass are real; the model is UNTRAINED until a dynamics task
fits it via FabricPC `train_pcn` (that is a per-Space process, not infra).
"""
function attach_predictor!(ds::DenseStore, in_dim::Int, hidden::Int, out_dim::Int;
    rng::AbstractRNG=default_rng())
    xn = Linear((in_dim,), "x")
    hn = Linear((hidden,), "h")
    yn = Linear((out_dim,), "y")
    structure = graph([xn, hn, yn], [Edge(xn, hn), Edge(hn, yn)],
        TaskMap(; x=xn, y=yn), InferenceSGD(; eta_infer=0.1, infer_steps=30))
    ds.model = (initialize_params(structure, rng), structure)
    return ds
end

"Is a FabricPC predictor attached?"
has_predictor(ds::DenseStore) = ds.model !== nothing

"""
    predict_dense(ds, x; rng) -> Vector{Float64}

Run the bound FabricPC predictor forward on input vector `x` (the Sctx context vector conditioning Sdyn),
returning the predicted output. Errors if no predictor is attached.
"""
function predict_dense(
    ds::DenseStore, x::AbstractVector{<:Real}; rng::AbstractRNG=default_rng()
)
    ds.model === nothing && error("no FabricPC predictor attached to this dense Space")
    params, structure = ds.model
    X = reshape(Float64.(x), 1, length(x))            # batch of 1 (rows = batch, cols = features)
    return vec(predict(params, structure, Dict("x" => X), rng; output_task="y"))
end

"""
    train_dense!(ds, X, Y; hidden=64, lr=0.01, epochs=100, adam=false, rng) -> (ds, energy_history)

Fit this dense Space's FabricPC predictor to the `(X → Y)` batch (rows = batch, cols = features) via
`train_pcn` (local predictive-coding learning — NO backprop), then WRITE the trained params back into
`ds.model` so `predict_dense`/`predict_dynamics` use the LEARNED model. If no predictor is bound yet an
`x → h → y` graph sized to the data (`in=size(X,2)`, `hidden`, `out=size(Y,2)`) is attached first.
`opt` is a plain-SGD `Real` lr (`adam=false`) or an `AdamW` (`adam=true`). Returns the store and the
`[epoch][batch]` energy history. This is the ONLY place FabricPC training is invoked (ADR-061 Sdyn gap).
"""
function train_dense!(ds::DenseStore, X::AbstractMatrix{<:Real}, Y::AbstractMatrix{<:Real};
    hidden::Int=64, lr::Real=0.01, epochs::Real=100, adam::Bool=false,
    rng::AbstractRNG=default_rng())
    size(X, 1) == size(Y, 1) || error(
        "train_dense!: X and Y must have equal batch rows, got $(size(X,1)) vs $(size(Y,1))")
    ds.model === nothing && attach_predictor!(ds, size(X, 2), hidden, size(Y, 2); rng=rng)
    params, structure = ds.model
    loader = [Dict("x" => Matrix{Float32}(X), "y" => Matrix{Float32}(Y))]
    opt = adam ? AdamW(params; lr=lr) : Float32(lr)
    params, energies, _ = train_pcn(params, structure, loader, opt;
        num_epochs=epochs, rng=rng, verbose=false)
    ds.model = (params, structure)                     # write trained weights back (train_pcn is functional)
    return ds, energies
end

end # module Dense
