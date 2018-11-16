using Parameters
using LinearAlgebra
using PyPlot
using Printf
using Statistics
using Profile
using LowRankApprox
using TimerOutputs

if !@isdefined Cluster
    @with_kw mutable struct Cluster
        X::Array{Float64}
        P::Array{Int64}
        left::Cluster
        right::Cluster
        m::Int64 = 0
        n::Int64 = 0
        N::Int64 = 0
        isleaf::Bool = false
        s::Int64
        e::Int64 # start and end index after permutation
    end
end

if !@isdefined Hmat
    @with_kw mutable struct Hmat
        A::Array{Float64} = Array{Float64}([])
        B::Array{Float64} = Array{Float64}([])
        C::Array{Float64} = Array{Float64}([])
        P::Array{Int64} = Array{Int64}([])
        is_rkmatrix::Bool = false
        is_fullmatrix::Bool = false
        is_hmat::Bool = false
        m::Int = 0
        n::Int = 0
        children::Array{Hmat} = Array{Hmat}([])
        s::Cluster
        t::Cluster
    end
end

const tos = TimerOutput()

function Base.:size(H::Hmat)
    return (H.m, H.n)
end

# utilities
function consistency(H, L=@__LINE__)
    try
        if H.m==0 || H.n==0
            @assert false
        end
        if H.is_rkmatrix
            @assert size(H.A,1)==H.m
            @assert size(H.B,1)==H.n
        elseif H.is_fullmatrix
            if !(size(H.C,1)==H.m && size(H.C,2)==H.n)
                error("$(size(H.C))!=[$(H.m), $(H.n)]")
            end
        elseif H.is_hmat
            n1 = div(H.n, 2)
            m1 = div(H.m, 2)
            size(H.children[1,1].m)==m1
            size(H.children[1,1].n)==m1
            size(H.children[1,2].m)==m1
            size(H.children[1,2].n)==H.n-n1
            size(H.children[2,1].m)==H.m-m1
            size(H.children[2,1].n)==n1
            size(H.children[2,2].m)==H.m-m1
            size(H.children[2,2].n)==H.n-n1
            for i = 1:2
                for j = 1:2
                    consistency(H.children[i,j])
                end
            end
        end
    catch
        println("Assertion: $L")
        println(H)
        @assert false
    end
end

function info(H::Hmat)
    dmat::Int64 = 0
    rkmat::Int64 = 0
    level::Int64 = 0
    compress_ratio::Float64 = 0
    function helper(H::Hmat, l::Int)
        # global dmat
        # global rkmat
        # global level
        if H.is_fullmatrix
            dmat += 1
            level = max(l, level)
            compress_ratio += H.m*H.n
        elseif H.is_rkmatrix
            rkmat += 1
            level = max(l, level)
            compress_ratio += size(H.A,1)*size(H.A,2) + size(H.B,1)*size(H.B, 2)
        else
            for i = 1:2
                for j = 1:2
                    helper(H.children[i,j], l+1)
                end
            end
        end
    end
    helper(H, 1)
    return dmat, rkmat, level, compress_ratio/H.m/H.n
end

function fmat(A::Array{Float64})
    H = Hmat(m = size(A,1), n = size(A,2))
    H.is_fullmatrix = true
    H.C = copy(A)
    return H
end

function rkmat(A, B)
    H = Hmat(m = size(A,1), n = size(B,1))
    H.is_rkmatrix = true
    H.A = A
    H.B = B
    return H
end

function rank_truncate(S, eps=1e-6)
    if length(S)==0
        return 0
    end
    k = findlast(S/S[1] .> eps)
    if isa(k, Nothing)
        return 0
    else
        return k
    end
end

function compress(C, eps=1e-6, N = nothing)
    if sum(abs.(C))≈0
        A = zeros(size(C,1),1)
        B = zeros(size(C,2),1)
        return A, B
    end

    if size(C,1)==size(C,2)
        U,S,V = psvd(C) 
    else
        U,S,V = svd(C)
    end

    if N==nothing
        N = length(S)
    end
    k = rank_truncate(S,eps)
    if k>N
        k = length(S)
    end
    A = U[:,1:k]
    B = (diagm(0=>S[1:k])*V'[1:k,:])'
    return A, B
end

function svdtrunc(A1, B1, A2, B2)
    if prod(size(A1))==0 || prod(size(A2))==0 || prod(size(B1))==0 || prod(size(B2))==0
        return A1, B1
    end
    # println(size(B1), size(B2))
    @assert size(A1, 1)==size(A2, 1)
    @assert size(B1, 1)==size(B2, 1)
    
    FA = qr([A1 A2])
    FB = qr([B1 B2])
    U,S,V = svd(FA.R*FB.R')
    k = rank_truncate(S, 1e-6)
    A = FA.Q * U[:,1:k] * diagm(0=>S[1:k])
    B = FB.Q * V[:,1:k]
    return A, B
end


function rkmat_add!(a, b, scalar, method=1)
    @assert a.m==b.m 
    @assert a.n==b.n
    if method==1
        a.A, a.B = svdtrunc(a.A, a.B, scalar*b.A, b.B)
    else
        error("Method not defined!")
    end
end

function hmat_full_add!(a::Hmat, b::AbstractArray{Float64}, scalar, eps=1e-6)
    if a.is_fullmatrix
        a.C += b*scalar
    elseif a.is_rkmatrix
        C = a.A*a.B'+scalar*b
        a.A, a.B = compress(C, eps)
    elseif a.is_hmat
        m = a.children[1,1].m
        n = a.children[1,1].n
        @views begin
            hmat_full_add!(a.children[1,1], b[1:m,1:n],scalar, eps)
            hmat_full_add!(a.children[1,2], b[1:m,n+1:end],scalar, eps)
            hmat_full_add!(a.children[2,1], b[m+1:end,1:n],scalar, eps)
            hmat_full_add!(a.children[2,2], b[m+1:end,n+1:end],scalar, eps)
        end
    else
        error("Should not be here")
    end
end
# Perform a = a + b
function hmat_add!( a, b, scalar = 1.0, eps=1e-6)
    @assert a.m==b.m
    @assert a.n==b.n
    if b.is_fullmatrix
        hmat_full_add!(a, b.C, scalar, eps)
    elseif a.is_fullmatrix && b.is_rkmatrix
        if prod(size(b.A))==0 
            return
        end
        a.C += scalar * b.A * b.B'
    elseif a.is_fullmatrix && b.is_hmat
        c = copy(b)
        to_fmat!(c)
        a.C += c.C
    elseif a.is_rkmatrix && b.is_rkmatrix
        rkmat_add!(a, b, scalar, 1)
    elseif a.is_rkmatrix && b.is_hmat
        to_fmat!(a)
        hmat_add!(a, b, scalar)
    elseif a.is_hmat && b.is_rkmatrix
        # hmat_full_add!(a, b.A*b.B', scalar) # costly step
        
        m = a.children[1,1].m
        n = a.children[1,1].n
        # @assert a.children[2,1].m+a.children[1,1].m==a.m
        # @assert a.children[1,2].n+a.children[1,1].n==a.n
        @views begin
            C11 = rkmat(b.A[1:m,:], b.B[1:n,:])
            C21 = rkmat(b.A[m+1:end,:], b.B[1:n,:])
            C12 = rkmat(b.A[1:m,:], b.B[n+1:end,:])
            C22 = rkmat(b.A[m+1:end,:], b.B[n+1:end,:])
        end
        # println(m)
        # println(size(b))
        # println(size(b.A))
        # println("***",size(C11))
        # println("***",size(a.children[1,1]))
        hmat_add!(a.children[1,1], C11, scalar, eps)
        hmat_add!(a.children[2,1], C21, scalar, eps)
        hmat_add!(a.children[1,2], C12, scalar, eps)
        hmat_add!(a.children[2,2], C22, scalar, eps)
    elseif a.is_hmat && b.is_hmat
        for i = 1:2
            for j = 1:2
                println(i,j,size(a.children[i,j]), size(b.children[i,j]))
            end
        end
        for i = 1:2
            for j = 1:2
                hmat_add!(a.children[i,j], b.children[i,j], scalar, eps)
            end
        end
    end
end

function Base.:+(a::Hmat, b::Hmat)
    @assert a.m==b.m && a.n==b.n
    c = copy(a)
    hmat_add!( c, b, 1.0)
    return c
end

function full_mat_mul(a::Array{Float64, 2}, b::Hmat)
    H = Hmat(m=size(a,1), n = b.n)
    
    if b.is_hmat
        # C = to_fmat(b)
        # H.is_fullmatrix = true
        # H.C = a*C
        # return H

        m, n = b.children[1,1].m, b.children[1,1].n
        p, q = b.m - m, b.n - n
        H.is_hmat = true
        # m0 = div(size(a,1),2)

        # m0 = calc_m(size(a,1), 64)
        m0 = min(m, size(a,1))

        H.children = Array{Hmat}([Hmat(m=m0, n=n) Hmat(m=m0, n=q)
                                    Hmat(m=size(a,1)-m0, n=n) Hmat(m=size(a,1)-m0, n=q)])
        a11 = a[1:m0, 1:m]
        a21 = a[m0+1:end, 1:m]
        a12 = a[1:m0, m+1:end]
        a22 = a[m0+1:end, m+1:end]
        b11 = b.children[1,1]
        b12 = b.children[1,2]
        b21 = b.children[2,1]
        b22 = b.children[2,2]
        H.children[1,1] = full_mat_mul(a11, b11) + full_mat_mul(a12, b21)
        H.children[1,2] = full_mat_mul(a11, b12) + full_mat_mul(a12, b22)
        H.children[2,1] = full_mat_mul(a21, b11) + full_mat_mul(a22, b21)
        H.children[2,2] = full_mat_mul(a21, b12) + full_mat_mul(a22, b22)
    elseif b.is_fullmatrix
        H.is_fullmatrix = true
        H.C = a * b.C
    else
        H.is_rkmatrix = true
        H.A = a * b.A
        H.B = b.B
    end
    return H
end

function mat_full_mul(a::Hmat, b::Array{Float64, 2})
    H = Hmat(m=a.m, n = size(b,2))
    
    if a.is_hmat
        # C = to_fmat(a)
        # H.is_fullmatrix = true
        # H.C = C*b
        # return H
        m, n = a.children[1,1].m, a.children[1,1].n
        p, q = a.m - m, a.n - n
        H.is_hmat = true
        # m0 = div(size(b,2),2)

        # m0 = calc_m(size(b,2), 64)
        m0 = min(n, size(b,2))

        H.children = Array{Hmat}([Hmat(m=m,n=m0) Hmat(m=m,n=size(b,2)-m0)
                                    Hmat(m=p,n=m0) Hmat(m=p,n=size(b,2)-m0)])
        b11 = b[1:n, 1:m0]
        b12 = b[1:n, m0+1:end]
        b21 = b[n+1:n+q, 1:m0]
        b22 = b[n+1:n+q, m0+1:end]
        a11 = a.children[1,1]
        a12 = a.children[1,2]
        a21 = a.children[2,1]
        a22 = a.children[2,2]
        H.children[1,1] = mat_full_mul(a11, b11) + mat_full_mul(a12, b21) 
        H.children[1,2] = mat_full_mul(a11, b12) + mat_full_mul(a12, b22)
        H.children[2,1] = mat_full_mul(a21, b11) + mat_full_mul(a22, b21)
        H.children[2,2] = mat_full_mul(a21, b12) + mat_full_mul(a22, b22)
    elseif a.is_fullmatrix
        H.is_fullmatrix = true
        H.C = a.C * b
    else
        H.is_rkmatrix = true
        H.A = a.A
        H.B = b' * a.B
    end
    return H
end

function Base.:*(a::Hmat, b::Hmat)
    @assert a.n==b.m
    H = Hmat(m=a.m, n = b.n)
    if a.is_fullmatrix
        H = full_mat_mul(a.C, b)
    elseif b.is_fullmatrix
        H = mat_full_mul(a, b.C)
    elseif a.is_rkmatrix && b.is_rkmatrix
        H.is_rkmatrix = true
        H.A = a.A
        H.B = b.B * (b.A' * a.B)
    elseif a.is_rkmatrix && b.is_hmat
        H.is_rkmatrix = true
        c = copy(b)
        to_fmat!(c)
        H.A = a.A
        H.B =  c.C' * a.B
    
    elseif a.is_hmat && b.is_rkmatrix
        H.is_rkmatrix = true
        c = copy(a)
        to_fmat!(c)
        H.A = c*b.A
        H.B = b.B
    elseif a.is_hmat && b.is_hmat
        H.is_hmat = true
        m = a.children[1,1].m
        n = b.children[1,1].n
        m1 = a.m - m
        n1 = b.n - n
        H.children = Array{Hmat}([Hmat(m=m,n=n) Hmat(m=m,n=n1)
                                 Hmat(m=m1,n=n) Hmat(m=m1,n=n1)])
        for i = 1:2
            for j = 1:2
                # println("***", size(a.children[i,1]), size(b.children[1,j]), size(a.children[i,2]), size(b.children[2,j]))
                # println("+++", size(a.children[i,1]*b.children[1,j]))
                # println("+++", size(a.children[i,2]*b.children[2,j]))
                # println("---", size(a.children[i,1]*b.children[1,j] + a.children[i,2]*b.children[2,j]))
                H.children[i,j] = a.children[i,1]*b.children[1,j] + a.children[i,2]*b.children[2,j]
            end
        end
    end
    return H
end

function Base.:*(a::Hmat, v::AbstractArray{Float64})
    r = zeros(a.m, size(v,2))
    for i = 1:size(v,2)
        @views hmat_matvec!(r[:,i], a, v[:,i], 1.0)
    end
    return r
end

# r = r + s*a*v
function hmat_matvec!(r::AbstractArray{Float64}, a::Hmat, v::AbstractArray{Float64}, s::Float64)
    if a.is_fullmatrix
        BLAS.gemm!('N','N',s,a.C,v,1.0,r)
    elseif a.is_rkmatrix
        BLAS.gemm!('N','N',s,a.A, a.B'*v,1.0,r)
    else
        m, n = a.children[1,1].m, a.children[1,1].n
        @views begin
            hmat_matvec!(r[1:m], a.children[1,1], v[1:n], s)
            hmat_matvec!(r[1:m], a.children[1,2], v[n+1:end], s)
            hmat_matvec!(r[m+1:end], a.children[2,1], v[1:n], s)
            hmat_matvec!(r[m+1:end], a.children[2,2], v[n+1:end], s)
        end
    end
end

# copy the hmatrix A to H in place.
function hmat_copy!(H::Hmat, A::Hmat)
    H.m = A.m
    H.n = A.n
    if A.is_fullmatrix
        H.C = copy(A.C)
        H.P = copy(A.P)
        H.is_fullmatrix = true
    elseif A.is_rkmatrix
        H.A = copy(A.A)
        H.B = copy(A.B)
        H.is_rkmatrix = true
    else
        H.is_hmat = true
        H.children = Array{Hmat}([Hmat() Hmat()
                                  Hmat() Hmat()])
        for i = 1:2
            for j = 1:2
                hmat_copy!(H.children[i,j], A.children[i,j])
            end
        end
    end
end

function Base.:copy(H::Hmat)
    G = Hmat()
    hmat_copy!(G, H)
    return G
end

# convert matrix A to full matrix
function to_fmat!(A::Hmat)
    if A.is_fullmatrix
        return
    elseif A.is_rkmatrix
        A.C = A.A*A.B'
    elseif A.is_hmat
        for i = 1:2
            for j = 1:2
                to_fmat!(A.children[i,j])
            end
        end
        A.C = [A.children[1,1].C A.children[1,2].C
                A.children[2,1].C  A.children[2,2].C]
        if length(A.children[1,1].P)>0
            A.P = [A.children[1,1].P;
                    A.children[2,2].P .+ A.children[1,1].m]
        end
    end
    A.is_fullmatrix = true
    A.is_rkmatrix = false
    A.is_hmat = false
end

function to_fmat(A::Hmat)
    B = copy( A)
    to_fmat!(B)
    return B.C
end

function to_fmat2!(A::Hmat)
    if length(A.C)>0
        return
    end
    if A.is_fullmatrix
        return
    elseif A.is_rkmatrix
        A.C = A.A*A.B'
    elseif A.is_hmat
        for i = 1:2
            for j = 1:2
                to_fmat2!(A.children[i,j])
            end
        end
        A.C = [A.children[1,1].C A.children[1,2].C
                A.children[2,1].C  A.children[2,2].C]
        if length(A.children[1,1].P)>0
            A.P = [A.children[1,1].P;
                    A.children[2,2].P .+ A.children[1,1].m]
        end
    end
end


function getl(A, unitdiag)
    if unitdiag
        return LowerTriangular(A)+LowerTriangular(-diagm(0=>diag(A)) + UniformScaling(1.0))
    else
        return LowerTriangular(A)
    end
end

function getu(A, unitdiag)
    if unitdiag
        return UpperTriangular(A)+UpperTriangular(-diagm(0=>diag(A)) + UniformScaling(1.0))
    else
        return UpperTriangular(A)
    end
end

function transpose!(a::Hmat)
    a.m, a.n = a.n, a.m
    if a.is_rkmatrix
        a.A, a.B = a.B, a.A
    elseif a.is_fullmatrix
        a.C = a.C'
    else
        for i = 1:2
            for j = 1:2
                transpose!(a.children[i,j])
            end
        end
        a.children[1,2], a.children[2,1] = a.children[2,1], a.children[1,2]
    end
end


# Solve AX = B and store the result into B
function hmat_trisolve!(a::Hmat, b::Hmat, islower, unitdiag)
    if a.is_rkmatrix
        error("A should not be a low-rank matrix")
    end

    if unitdiag
        cc = 'U'
    else
        cc = 'N'
    end

    if islower
        if a.is_fullmatrix && b.is_fullmatrix
            LAPACK.trtrs!('L', 'N', cc, a.C, b.C)
            # error("Never used")
        elseif a.is_fullmatrix && b.is_rkmatrix
            if size(b.A,1)==0
                return
            end
            LAPACK.trtrs!('L', 'N', cc, a.C, b.A)
            # println("**333")
        elseif a.is_fullmatrix && b.is_hmat
            error("This is never used")
        elseif a.is_hmat && b.is_hmat
            a11, a12, a21, a22 = a.children[1,1], a.children[1,2],a.children[2,1],a.children[2,2]
            b11, b12, b21, b22 = b.children[1,1], b.children[1,2],b.children[2,1],b.children[2,2]
            hmat_trisolve!(a11, b11, islower, unitdiag)
            hmat_trisolve!(a11, b12, islower, unitdiag)
            hmat_add!(b21, a21*b11, -1.0)
            hmat_add!(b22, a21*b12, -1.0)
            hmat_trisolve!(a22, b21, islower, unitdiag)
            hmat_trisolve!(a22, b22, islower, unitdiag)
        elseif a.is_hmat && b.is_fullmatrix
            H = copy(a)
            to_fmat!(H)
            hmat_trisolve!(H, b, islower, unitdiag)
            # error("Never used")
        elseif a.is_hmat && b.is_rkmatrix
            H = copy(a)
            to_fmat!(H)
            LAPACK.trtrs!('L', 'N', cc, H.C, b.A)
        end
    else
        transpose!(a)
        transpose!(b)
        hmat_trisolve!(a, b, true, unitdiag)
        transpose!(a)
        transpose!(b)
    end
end

function permute_hmat!(H::Hmat, P::AbstractArray{Int64})
    if H.is_fullmatrix
        H.C = H.C[P,:]
    elseif H.is_rkmatrix
        H.A = H.A[P,:]
    else
        m = H.children[1,1].m
        P1 = P[1:m]
        P2 = P[m+1:end] .- m
        @assert maximum(P2)==H.m - m
        # println(P2)
        permute_hmat!(H.children[1,1], P1)
        permute_hmat!(H.children[1,2], P1)
        permute_hmat!(H.children[2,1], P2)
        permute_hmat!(H.children[2,2], P2)
    end
end

function LinearAlgebra.:lu!(H::Hmat)
    if H.is_rkmatrix
        error("H should not be a low-rank matrix")
    end

    if H.is_fullmatrix
        # printmat((H.C))
        F = lu!(H.C, Val{true}())
        H.P = F.p
    else
        # C = to_fmat(H)
        # lu!(C, Val{true}())

        lu!(H.children[1,1])

        # D = to_fmat(H.children[1,1])
        # println("*** $(maximum(abs.(C-D)))")

        permute_hmat!(H.children[1,2], H.children[1,1].P)
        hmat_trisolve!(H.children[1,1], H.children[1,2], true, true)      # islower, unitdiag, permutation
        hmat_trisolve!(H.children[1,1], H.children[2,1], false, false)   # islower, unitdiag, permutation

        hh = H.children[2,1]*H.children[1,2]
        hmat_add!(H.children[2,2], hh, -1.0) # costly

        
        lu!(H.children[2,2])

        permute_hmat!(H.children[2,1], H.children[2,2].P)
        H.P = [H.children[1,1].P; H.children[2,2].P .+ H.children[1,1].m]

        # D = to_fmat(H)
        # println("*** $(maximum(abs.(C-D)))")

        # G0 = to_fmat(H)
        
        # # println(H.P)
        # check_err(H, G)

        # if H.m==16
        # H1 = to_fmat(H)
        # G1,PP = mm2(G, H.children[1,1].m)
        # # printmat(G)
        # # printmat(G1)
        # # printmat(H1)
        # printmat(G1-H1)
        # # printmat(G0)
        
        # # printmat(G1)
        
        # # error("Stop")
        # end
    end
end

# a is factorized hmatrix
function hmat_solve!(a::Hmat, y::AbstractArray{Float64}, lower=true)
    if a.is_rkmatrix
        error("a cannot be a low-rank matrix")
    end
    if lower
        if a.is_fullmatrix
            # permute!(y, a.P)
            LAPACK.trtrs!('L', 'N', 'U', a.C, y)
        elseif a.is_hmat
            @views begin
                hmat_solve!(a.children[1,1], y[1:a.children[1,1].m], true)
                hmat_matvec!(y[a.children[1,1].m+1:end], a.children[2,1], y[1:a.children[1,1].m], -1.0)
                hmat_solve!(a.children[2,2], y[a.children[1,1].m+1:end], true)
            end
        end
    else
        if a.is_fullmatrix
            LAPACK.trtrs!('U', 'N', 'N', a.C, y)
        elseif a.is_hmat
            @views begin
                hmat_solve!(a.children[2,2], y[a.children[1,1].m+1:end], false)
                hmat_matvec!(y[1:a.children[1,1].m], a.children[1,2], y[a.children[1,1].m+1:end], -1.0)
                hmat_solve!(a.children[1,1], y[1:a.children[1,1].m], false)
            end
        end
    end
end

# a is factorized hmatrix
# these implementations makes H a preconditioner
function LinearAlgebra.:ldiv!(x::AbstractArray{Float64}, a::Hmat, y::AbstractArray{Float64})
    x = deepcopy(y)
    permute!(x, a.P)
    hmat_solve!(a, y, true)
    hmat_solve!(a, y, false)
end

function LinearAlgebra.:ldiv!(a::Hmat, y::AbstractArray{Float64})
    permute!(y, a.P)
    hmat_solve!(a, y, true)
    hmat_solve!(a, y, false)
end

function Base.:\(a::Hmat, y::AbstractArray{Float64})
    w = deepcopy(y)
    ldiv!(a, w)
    return w
end

function color_level(H)
    function helper!(H, level)
        if H.is_fullmatrix
            H.C = ones(size(H.C))* (rand()*0.5)
        elseif H.is_rkmatrix
            H.A = -ones(H.m, 1)
            H.B = ones(H.n, 1) * (level + rand()*0.5)
        else
            for i = 1:2
                for j = 1:2
                    helper!(H.children[i,j], level+1)
                end
            end
        end
    end
    helper!(H, 0)
    to_fmat!(H)
    return H.C
end

function plot_hmat(H)
    C = color_level(H)
    matshow(C)
end

function PyPlot.:matshow(H::Hmat)
    P = copy(H)
    C = color_level(P)
    matshow(C)
end

function printmat(H)
    println("=============== size = $(size(H,1))x$(size(H,2)) ===================")
    for i = 1:size(H,1)
        for j = 1:size(H,2)
            @printf("%+0.4f ", H[i,j])
        end
        @printf("\n")
    end
    println("=====================================================================")
end

function check_if_equal(H::Hmat, C::Array{Float64})
    G = (H)
    to_fmat!(G)
    println("Error = $(norm(C-G.C,2)/norm(C,2))")
end

function verify_matrix_error(H::Hmat, C::Array{Float64})
    G = to_fmat(H)
    err = norm(G-C)/norm(C)
    println("Matrix Error = $err")
end

function verify_matvec_error(H::Hmat, C::Array{Float64})
    y = rand(size(C,1))
    b1 = H*y
    b2 = C*y
    err = norm(b2-b1)/norm(b2)
    println("Matvec Error = $err")
end

function verify_lu_error(HH::Hmat)
    H = copy(HH)
    C = to_fmat(H)
    lu!(H)
    x = rand(size(C,1))
    b = C*x
    y = H\b
    err = norm(x-y)/norm(x)
    # println("Permuation = $(H.P)")
    println("Solve Error = $err")

    to_fmat!(H)
    G = C[H.P,:] - (LowerTriangular(H.C)-diagm(0=>diag(H.C))+UniformScaling(1.0))*UpperTriangular(H.C)
    println("LU Matrix Error = $(maximum(abs.(G)))")
    
    return G
end

function check_err(HH::Hmat, C::Array{Float64})
    H = copy(HH)
    to_fmat!(H)
    # println(H.P)
    G = C[H.P,:] - (LowerTriangular(H.C)-diagm(0=>diag(H.C))+UniformScaling(1.0))*UpperTriangular(H.C)
    println("Matrix Error = $(maximum(abs.(G)))")
end
