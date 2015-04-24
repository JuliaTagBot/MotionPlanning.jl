export FinalTime, LinearQuadratic, LQOptSteering
export LinearQuadraticStateSpace, DoubleIntegrator
export waypoints, statepoints

### Linear Quadratic Steering
include("linearquadraticBVP.jl")
type FinalTime{T<:FloatingPoint} <: ControlInfo
    t::T
end
abstract LinearQuadratic{T<:FloatingPoint} <: QuasiMetric
controltype(d::LinearQuadratic) = FinalTime

## Optimal Steering
type LQOptSteering{T} <: LinearQuadratic{T}
    BVP::LinearQuadratic2BVP
    cmax::T         # for potential pruning
end
function LQOptSteering(A::Matrix, B::Matrix, c::Vector, R::Matrix, cmax = 1.)
    LQOptSteering(LinearQuadratic2BVP(A, B, c, R), cmax)
end

## TODO: Approximate(ly Optimal) Steering
# type LQApproxSteering{T<:FloatingPoint} <: LinearQuadratic
#
# end

### Linear Quadratic State Space
immutable LinearQuadraticStateSpace{T<:FloatingPoint} <: DifferentialStateSpace
    dim::Int
    lo::Vector{T}
    hi::Vector{T}
    dist::LinearQuadratic{T}

    A::Matrix{T}
    B::Matrix{T}
    c::Vector{T}   # drift
    R::Matrix{T}
    C::Matrix{T}   # state -> workspace
end
## Optimal Steering
LinearQuadraticStateSpace(dim::Int, lo::Vector, hi::Vector,
                          A::Matrix, B::Matrix, c::Vector, R::Matrix, C::Matrix) =
    LinearQuadraticStateSpace(dim, lo, hi, LQOptSteering(A, B, c, R), A, B, c, R, C)

vector_to_state{T}(v::AbstractVector{T}, SS::LinearQuadraticStateSpace) = v
sample_space(SS::LinearQuadraticStateSpace) = vector_to_state(SS.lo + rand(SS.dim).*(SS.hi-SS.lo), SS)   # TODO: @devec
function volume(SS::LinearQuadraticStateSpace)
    # warn("TODO: what is volume for a LinearQuadraticStateSpace?")
    prod(SS.hi-SS.lo)
end
function defaultNN(SS::LinearQuadraticStateSpace, init)
    V = typeof(init)[init]
    QuasiMetricNN_BruteForce(V, SS.dist)
end

function pairwise_distances{S<:State,T<:FloatingPoint}(dist::LQOptSteering{T}, V::Vector{S})
    N = length(V)
    VM = hcat(V...)
    DS = Array(T, N, N)
    US = Array(FinalTime, N, N)
    for j = 1 : N
        vj = view(VM,:,j)
        for i = j+1 : N
            d, t = steer(dist.BVP, view(VM,:,i), vj, dist.cmax)
            @inbounds DS[i,j], US[i,j] = d, FinalTime(t)
        end
        @inbounds DS[j,j], US[j,j] = 0, FinalTime(0)
        for i = 1 : j-1
            d, t = steer(dist.BVP, view(VM,:,i), vj, dist.cmax)
            @inbounds DS[i,j], US[i,j] = d, FinalTime(t)
        end
    end
    DS, US
end

waypoints(i, j, NN::QuasiMetricNN, SS::LinearQuadraticStateSpace, res=5) =
    [SS.C * SS.dist.BVP.x(NN[i], NN[j], NN.US[i,j].t, s) for s in linspace(0, NN.US[i,j].t, res)]
statepoints(i, j, NN::QuasiMetricNN, SS::LinearQuadraticStateSpace, res=5) =
    [SS.dist.BVP.x(NN[i], NN[j], NN.US[i,j].t, s) for s in linspace(0, NN.US[i,j].t, res)]
function inbounds(v, SS::LinearQuadraticStateSpace)
    for i in 1:length(v)
        (SS.lo[i] > v[i] || v[i] > SS.hi[i]) && return false
    end
    true
end
is_free_state(v, CC::PointRobot2D, SS::LinearQuadraticStateSpace) = inbounds(v, SS) && is_free_state(SS.C * v, CC)
function is_free_motion(v, w, CC::PointRobot2D, SS::LinearQuadraticStateSpace)   # TODO: inputs V, i, j instead of v, w
    t = steer(SS.dist.BVP, v, w, SS.dist.cmax)[2]   # terrible, hmm
    for s in linspace(0, t, 5)
        y = SS.C * SS.dist.BVP.x(v, w, t, s)
        !inbounds(y, SS) && return false
        vy = Vector2(y)
        s > 0 && !is_free_motion(vx, vy, CC) && return false
        vx = vy
    end
    true
end
# TODO: is_free_path(path, CC::PointRobot2D, SS::LinearQuadraticStateSpace)

function plot_tree(SS::LinearQuadraticStateSpace, NN::QuasiMetricNN, A; kwargs...)
    pts = hcat(NN[find(A)]...)
    scatter(pts[1,:], pts[2,:], zorder=1; kwargs...)
    X = vcat([[hcat(waypoints(A[v], v, NN, SS, 20)...)[1,:]', nothing] for v in find(A)]...)
    Y = vcat([[hcat(waypoints(A[v], v, NN, SS, 20)...)[2,:]', nothing] for v in find(A)]...)
    plt.plot(X, Y, linewidth=.5, linestyle="-", zorder=1; kwargs...)
end

function plot_path(SS::LinearQuadraticStateSpace, NN::QuasiMetricNN, sol; kwargs...)
    wps = hcat([hcat(waypoints(sol[i], sol[i+1], NN, SS, 20)...) for i in 1:length(sol)-1]...)
    length(sol) > 1 && plot_path(wps; kwargs...)
    # plt.quiver([wps[row,1:3:end]' for row in 1:4]..., zorder=5, width=.003, headwidth=8)
end

### Double Integrator State Space

function DoubleIntegrator(d::Int, lo = zeros(d), hi = ones(d); vmax = 1.5, r = 1.)
    A = [zeros(d,d) eye(d); zeros(d,2d)]
    B = [zeros(d,d); eye(d)]
    c = zeros(2d)
    R = r*eye(d)
    C = [eye(d) zeros(d,d)]

    LinearQuadraticStateSpace(2d, [lo, -vmax*ones(d)], [hi, vmax*ones(d)], A, B, c, R, C)
end


# TODO: old code relevant to approx opt implementation
# function pairwise_distances_approx_opt{T}(V::Vector{Vector{T}}, SS::LinearQuadraticStateSpace, t_bound::Float64, res::Int64 = 10)
#     N = length(V)
#     V1 = hcat(V...)
#     t = t_bound/2.
#     V0bar = SS.expAt(t)*V1 .+ SS.cdrift(t)
#     return (t + pairwise(SqMahalanobis(SS.Ginv(t)), V0bar, V1)), fill(t, N, N)
# end