module cumulantexpansion

using ..bases
using ..states
using ..operators
using ..operators_lazy
using ..ode_dopri

import Base: *, full
import ..operators


type ProductDensityOperator <: Operator
    basis_l::CompositeBasis
    basis_r::CompositeBasis
    operators::Vector{DenseOperator}
    function ProductDensityOperator(operators::DenseOperator...)
        basis_l = tensor([op.basis_l for op in operators]...)
        basis_r = tensor([op.basis_r for op in operators]...)
        new(basis_l, basis_r, collect(operators))
    end
end

ProductDensityOperator() = error("ProductDensityOperator needs at least one operator.")
ProductDensityOperator(states::Ket...) = ProductDensityOperator(DenseOperator[tensor(state, dagger(state)) for state in states]...)

*(a::ProductDensityOperator, b::ProductDensityOperator) = (check_multiplicable(a.basis_r, b.basis_l); ProductDensityOperator(a.basis_l, b.basis_r, DenseOperator[a_i*b_i for (a_i, b_i) in zip(a.operators, b.operators)]))
function *(a::LazyTensor, b::ProductDensityOperator)
    check_multiplicable(a.basis_r, b.basis_l);
    operators = DenseOperator[]
    for (alpha, b_alpha) in enumerate(b.operators)
        if alpha in keys(a.operators)
            push!(operators, a.operators[alpha]*b_alpha)
        else
            push!(operators, deepcopy(b_alpha))
        end
    end
    if a.factor != 1.
        operators[0] *= a.factor
    end
    ProductDensityOperator(operators...)
end
function *(a::ProductDensityOperator, b::LazyTensor)
    check_multiplicable(a.basis_r, b.basis_l);
    operators = DenseOperator[]
    for (alpha, a_alpha) in enumerate(a.operators)
        if alpha in keys(b.operators)
            push!(operators, a_alpha*b.operators[alpha])
        else
            push!(operators, deepcopy(a_alpha))
        end
    end
    if b.factor != 1.
        operators[0] *= b.factor
    end
    ProductDensityOperator(operators...)
end

dims(bl::CompositeBasis, br::CompositeBasis) = [length(bl_i)*length(br_i) for (bl_i, br_i) in zip(bl.bases, br.bases)]
dims(x::ProductDensityOperator) = dims(x.basis_l, x.basis_r)

operators.expect(op::Operator, rho::ProductDensityOperator) = trace(op*rho)
operators.expect(op::LazySum, rho::ProductDensityOperator) = sum([expect(x, rho) for (f, x) in zip(op.factors, op.operators)])
# function operators.expect(op::LazyTensor, rho::ProductDensityOperator)
#     result = op.factor
#     for (alpha, rho_alpha) in enumerate(rho.operators)
#         if alpha in keys(op)
#             result *= expect(op.operators[alpha], rho_alpha)
#         else
#             result *= trace(rho_alpha)
#         end
#     end
#     result
# end

# operators.expect(op::LazySum, rho::ProductDensity) = sum([expect(f*x, rho) for (f, x) in zip(op.factors, op.operators)])


traces(x::ProductDensityOperator) = [trace(op) for op in x.operators]
operators.trace(x::ProductDensityOperator) = prod(traces(x))

function Base.full(x::ProductDensityOperator)
    tensor(x.operators...)
end

function fill!(x::ProductDensityOperator, alpha::Number)
    for op in x.operators
        Base.fill!(op.data, complex(alpha))
    end
end

# Ignores the factor in the LazyTensor
function operators.gemm!(alpha, a::LazyTensor, b::ProductDensityOperator, beta, result::ProductDensityOperator)
    @assert abs(beta)==0.
    for (k, a_k) in a.operators
        operators.gemm!(complex(1.), a_k, b.operators[k], complex(0.), result.operators[k])
    end
end

function dmaster(rho0::ProductDensityOperator, H::LazySum,
                 J::Vector{LazyTensor}, Jdagger::Vector{LazyTensor}, JdaggerJ::Vector{LazyTensor},
                 drho::ProductDensityOperator, tmp::ProductDensityOperator)
    fill!(drho, 0.)
    for h_k in H.operators
        operators.gemm!(1., h_k, rho0, 0., tmp)
        subtraces = traces(tmp)
        for (alpha, h_k_alpha) in h_k.operators
            factor = h_k.factor
            for gamma in keys(h_k.operators)
                if alpha!=gamma
                    factor *= subtraces[gamma]
                end
            end
            operators.gemm!(factor*complex(0,-1.), h_k_alpha, rho0.operators[alpha], complex(1.), drho.operators[alpha])
            operators.gemm!(factor*complex(0,1.), rho0.operators[alpha], h_k_alpha, complex(1.), drho.operators[alpha])
        end
    end
    for k=1:length(J)
        operators.gemm!(1., JdaggerJ[k], rho0, 0., tmp)
        subtraces = traces(tmp)
        subindices = keys(J[k].operators)
        for alpha in subindices
            factor = JdaggerJ[k].factor
            for gamma in subindices
                if alpha!=gamma
                    factor *= subtraces[gamma]
                end
            end
            operators.gemm!(complex(2*factor), J[k].operators[alpha], rho0.operators[alpha], complex(0.), tmp.operators[alpha])
            operators.gemm!(complex(1.), tmp.operators[alpha], Jdagger[k].operators[alpha], complex(1.), drho.operators[alpha])
            operators.gemm!(complex(-factor), JdaggerJ[k].operators[alpha], rho0.operators[alpha], complex(1.), drho.operators[alpha])
            operators.gemm!(complex(-factor), rho0.operators[alpha], JdaggerJ[k].operators[alpha], complex(1.), drho.operators[alpha])
        end
    end
end

dims(rho::ProductDensityOperator) = [length(op.basis_l)*length(op.basis_r) for op in rho.operators]

function as_vector(rho::ProductDensityOperator, x::Vector{Complex128})
    @assert length(x) == prod(dims(rho))
    i = 0
    for op in rho.operators
        N = length(op.basis_l)*length(op.basis_r)
        x[i+1:i+N] = reshape(op.data, N)
        i += N
    end
    x
end

function as_operator(x::Vector{Complex128}, rho::ProductDensityOperator)
    @assert length(x) == prod(dims(rho))
    i = 0
    for op in rho.operators
        N = length(op.basis_l)*length(op.basis_r)
        reshape(op.data, N)[:] = x[i+1:i+N]
        i += N
    end
    rho
end

function master(tspan, rho0::ProductDensityOperator, H::LazySum, J::Vector{LazyTensor};
                fout::Union{Function,Void}=nothing,
                kwargs...)
    x0 = as_vector(rho0, zeros(Complex128, prod(dims(rho0))))
    f = (x->x)
    if fout==nothing
        tout = Float64[]
        xout = ProductDensityOperator[]
        function fout_(t, rho::ProductDensityOperator)
            push!(tout, t)
            push!(xout, deepcopy(rho))
        end
        f = fout_
    else
        f = fout
    end
    Jdagger = LazyTensor[dagger(j) for j=J]
    JdaggerJ = LazyTensor[dagger(j)*j for j=J]
    rho = deepcopy(rho0)
    drho = deepcopy(rho0)
    tmp = deepcopy(rho0)

    f_(t, x::Vector{Complex128}) = f(t, as_operator(x, tmp))
    function dmaster_(t, x::Vector{Complex128}, dx::Vector{Complex128})
        dmaster(as_operator(x, rho), H, J, Jdagger, JdaggerJ, drho, tmp)
        as_vector(drho, dx)
    end
    ode(dmaster_, float(tspan), x0, f_; kwargs...)
    return fout==nothing ? (tout, xout) : nothing
end

master(tspan, rho0, H::LazyTensor, J; kwargs...) = master(tspan, rho0, LazySum(H), J; kwargs...)

end # module