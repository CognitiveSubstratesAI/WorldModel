# Dense.jl — the dense substrate for the green Spaces (Sctx context, Sdyn dynamics, Skernel summaries).
#
# Green-primary Spaces hold dense vectors (§4.2, App A.7/A.8). Sctx aggregates context vectors from Λ
# (densified-HMH retrieval + symbolic lifting); Skernel holds kernel-mean (μR) set→vector summaries; Sdyn
# hosts a predictive-coding model (FabricPC). This is the ONLY module that touches FabricPC + dense arrays,
# mirroring Substrate.jl (MORK) and HMHStore.jl (HMH).

module Dense

using FabricPC: graph, Linear, Edge, predict, initialize_params, TaskMap, InferenceSGD
using Random: AbstractRNG, default_rng

export DenseStore, dense_fresh, put_vec!, get_vec, vec_keys, has_vec,
    attach_predictor!, predict_dense, has_predictor

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

end # module Dense
