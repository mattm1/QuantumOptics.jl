using Base.Test
using QuantumOptics

@testset "stochastic_schroedinger" begin

b_spin = SpinBasis(1//2)
sz = sigmaz(b_spin)
sm = sigmam(b_spin)
sp = sigmap(b_spin)
zero_op = 0*sz
γ = 0.1
noise_op = 0.5γ*sz

H = γ*(sp + sm)
Hs = [noise_op]

ψ0 = spindown(b_spin)
ρ0 = dm(ψ0)

dt = 1/30.0
T = [0:0.1:1;]
T_short = [0:dt:dt;]

# Test equivalence of stochastic schroedinger phase noise and master dephasing
Ntraj = 100
ρ_avg = [0*ρ0 for i=1:length(T)]
for i=1:Ntraj
    t, ψt = stochastic.schroedinger(T, ψ0, H, Hs; dt=1e-3)
    ρ_avg += dm.(ψt)./Ntraj
end
tout, ρt = timeevolution.master(T, ρ0, H, [sz]; rates=[0.25γ^2])

for i=1:length(tout)
    @test tracedistance(ρ_avg[i], ρt[i]) < dt
end

# Function definitions for schroedinger_dynamic
function fdeterm(t, psi)
    H
end
function fstoch_1(t, psi)
    [zero_op]
end
function fstoch_2(t, psi)
    [zero_op, zero_op, zero_op]
end
function fstoch_3(t, psi)
    noise_op, noise_op
end

# Non-dynamic Schrödinger
tout, ψt4 = stochastic.schroedinger(T, ψ0, H, [zero_op, zero_op]; dt=dt)
tout, ψt3 = stochastic.schroedinger(T, ψ0, H, zero_op; dt=dt)
# Dynamic Schrödinger
tout, ψt1 = stochastic.schroedinger_dynamic(T, ψ0, fdeterm, fstoch_1; dt=dt)
tout, ψt2 = stochastic.schroedinger_dynamic(T, ψ0, fdeterm, fstoch_2; dt=dt, noise_processes=3)

# Test equivalence to Schrödinger equation with zero noise
# Test sharp equality for same algorithms
@test ψt1 == ψt3
@test ψt2 == ψt4

tout, ψt_determ = timeevolution.schroedinger_dynamic(T, ψ0, fdeterm)
# Test approximate equality for different algorithms
for i=1:length(tout)
    @test norm(ψt1[i] - ψt2[i]) < dt
    @test norm(ψt1[i] - ψt_determ[i]) < dt
end

# Test remaining function calls for short times to test whether they work in principle
tout, ψt = stochastic.schroedinger(T_short, ψ0, H, noise_op; dt=dt)
tout, ψt = stochastic.schroedinger_dynamic(T_short, ψ0, fdeterm, fstoch_3; dt=dt)

end # testset
