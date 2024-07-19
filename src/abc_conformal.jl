"""
	MC_predict(model, X::AbstractArray{T}; n_samples=1000, kwargs...)
For each X it returns `n_samples` monte carlo simulations where the randomness comes from the (Concrete)Dropout layers.
"""
function MC_predict(model_state, X::AbstractArray, n_samples=1000; dev = gpu_device(), dim_out = model_state.model[end].layers[1].out_dims)
    st = model_state.states
    ps = model_state.parameters
    model = model_state.model

    dim_N = ndims(X)
    mean_arr = similar(X, dim_out, size(X, dim_N))
    std_dev_arr = similar(X, dim_out, size(X, dim_N))

    X = X |> dev
    X_in = similar(X, size(X)[1:end-1]..., n_samples) |> dev
    

    for (i, x) in enumerate(eachslice(X, dims=dim_N, drop = false))
        X_in .= x 
    
        predictions, st = model(X_in, ps, st)
        θs_MC, logvars = predictions |> cpu_device()

        θ_hat = mean(θs_MC, dims=2) # predictive_mean 

        θ2_hat = mean(θs_MC .^ 2, dims=2) # θ2_hat = mean(θs_MC' * θs_MC, dims=2)
        var_mean = mean(exp.(logvars), dims=2) # aleatoric_uncertainty 
        total_var = θ2_hat - θ_hat .^ 2 + var_mean
        std_dev = sqrt.(total_var)

        mean_arr[:, i] .= θ_hat
        std_dev_arr[:, i] .= std_dev
    end

    return mean_arr, std_dev_arr
end

"""
	MC2df(predictive_mean, overall_uncertainty, true_θ)
Return a DataFrame with the following column `["θ", "θ_hat", "σ_tot"]`
"""
MC2df(predictive_mean, overall_uncertainty, true_θ) = [DataFrame(hcat(true_θ[i,:], predictive_mean[i,:], overall_uncertainty[i,:]), ["θ", "θ_hat", "σ_tot"]) for i in axes(true_θ, 1)]

# Conformal functions

"""
	q_hat_conformal(x_true, x_hat, α, σ = 1)
Estimate the conformal quantile of level α. To compute the score σ can be specified as a vecor or number. σ is a proxy for our confidence on the estimation.
"""
function q_hat_conformal(x_true, x_hat, α, σ=1)
    n = length(x_true)
    q_level = ceil((n + 1) * (1 - α)) / n
    score = abs.(x_true - x_hat) ./ σ
    return sort(score)[ceil(Int, n * q_level)]
end


"""
	conformilize!(df_test, df_cal, α)
Given two DataFrame one of test `df_test` and one of calibration `df_cal`, it estimate (and add in place) the conformal quantile low/hight for each observation.
"""
function conformilize!(df_test, df_cal, α)
    q̂ = q_hat_conformal(df_cal.:θ, df_cal.:θ_hat, α, df_cal.:σ_tot)
    @transform!(df_test,
        :q_low = :θ_hat - q̂ * :σ_tot,
        :q_high = :θ_hat + q̂ * :σ_tot
    )
end

function conformilize(df_test, df_cal, α)
    df = copy(df_test)
    conformilize!(df, df_cal, α)
    return df
end

function conformilize(MC_test::NTuple{2}, MC_cal::NTuple{2}, θ_test, θ_cal, α_conformal)
    df_cal = MC2df(MC_cal..., θ_cal);
    df_cd_test_conformal = MC2df(MC_test..., θ_test)

    conformilize!.(df_cd_test_conformal, df_cal, α_conformal)

    return df_cd_test_conformal
end