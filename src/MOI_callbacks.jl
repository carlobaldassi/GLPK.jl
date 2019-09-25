# ==============================================================================
#    Generic Callbacks in GLPK
# ==============================================================================

"""
    CallbackFunction()

Set a generic GLPK callback function.
"""
struct CallbackFunction <: MOI.AbstractOptimizerAttribute end

function MOI.set(model::Optimizer, ::CallbackFunction, f::Function)
    model.has_generic_callback = true
    set_callback(model, (cb_data) -> begin
        model.callback_state = CB_GENERIC
        callback_function(cb_data)
        model.callback_state = CB_NONE
    end)
    return
end

# ==============================================================================
#    MOI callbacks
# ==============================================================================

function default_moi_callback(model::Optimizer)
    return (cb_data) -> begin
        reason = GLPK.ios_reason(cb_data.tree)
        if reason == GLPK.IROWGEN && model.lazy_callback !== nothing
            model.callback_state = CB_LAZY
            model.lazy_callback(cb_data)
        elseif reason == GLPK.ICUTGEN && model.user_cut_callback !== nothing
            model.callback_state = CB_USER_CUT
            model.user_cut_callback(cb_data)
        elseif reason == GLPK.IHEUR && model.heuristic_callback !== nothing
            model.callback_state = CB_HEURISTIC
            model.heuristic_callback(cb_data)
        end
        return
    end
end

function MOI.get(
    model::Optimizer,
    attr::MOI.CallbackVariablePrimal{CallbackData},
    x::MOI.VariableIndex
)
    subproblem = GLPK.ios_get_prob(attr.callback_data.tree)
    return GLPK.get_col_prim(subproblem, _info(model, x).column)
end

# ==============================================================================
#    MOI.LazyConstraint
# ==============================================================================

function MOI.set(model::Optimizer, ::MOI.LazyConstraintCallback, cb::Function)
    model.lazy_callback = cb
    return
end

function MOI.submit(
    model::Optimizer,
    cb::MOI.LazyConstraint{CallbackData},
    f::MOI.ScalarAffineFunction{Float64},
    s::Union{MOI.LessThan{Float64}, MOI.GreaterThan{Float64}, MOI.EqualTo{Float64}}
)
    if model.callback_state != CB_LAZY && model.callback_state != CB_GENERIC
        error("`MOI.LazyConstraint` can only be called from LazyConstraintCallback.")
    elseif !iszero(f.constant)
        throw(MOI.ScalarFunctionConstantNotZero{Float64, typeof(f), typeof(s)}(f.constant))
    end
    key = CleverDicts.add_item(model.affine_constraint_info, ConstraintInfo(s))
    model.affine_constraint_info[key].row = length(model.affine_constraint_info)
    indices, coefficients = _indices_and_coefficients(model, f)
    sense, rhs = _sense_and_rhs(s)
    inner = GLPK.ios_get_prob(cb.callback_data.tree)
    _add_affine_constraint(inner, indices, coefficients, sense, rhs)
    return MOI.ConstraintIndex{typeof(f), typeof(s)}(key.value)
end

# ==============================================================================
#    MOI.UserCutCallback
# ==============================================================================

function MOI.set(model::Optimizer, ::MOI.UserCutCallback, cb::Function)
    model.user_cut_callback = cb
    return
end

function MOI.submit(
    model::Optimizer,
    cb::MOI.UserCut{CallbackData},
    f::MOI.ScalarAffineFunction{Float64},
    s::Union{MOI.LessThan{Float64}, MOI.GreaterThan{Float64}}
)
    if model.callback_state != CB_USER_CUT && model.callback_state != CB_GENERIC
        error("`MOI.UserCut` can only be called from UserCutCallback.")
    end
    indices, coefficients = _indices_and_coefficients(model, f)
    sense, rhs = _sense_and_rhs(s)
    bound_type = sense == Cchar('G') ? GLPK.LO : GLPK.UP
    GLPK.ios_add_row(
        cb.callback_data.tree,
        "",
        101,
        indices,
        coefficients,
        bound_type,
        rhs
    )
    return
end

#

# ==============================================================================
#    MOI.HeuristicCallback
# ==============================================================================

function MOI.set(model::Optimizer, ::MOI.HeuristicCallback, cb::Function)
    model.heuristic_callback = cb
    return
end

function MOI.submit(
    model::Optimizer,
    cb::MOI.HeuristicSolution{CallbackData},
    variables::Vector{MOI.VariableIndex},
    values::MOI.Vector{Float64}
)
    if model.callback_state != CB_HEURISTIC && model.callback_state != CB_GENERIC
        error("`MOI.HeuristicSolution` can only be called from HeuristicCallback.")
    end
    solution = fill(NaN, MOI.get(model, MOI.NumberOfVariables()))
    for (var, value) in zip(variables, values)
        solution[_info(model, var).column] = value
    end
    ret = ios_heur_sol(cb.callback_data.tree, solution)
    return ret == 0 ? MOI.HEURISTIC_SOLUTION_ACCEPTED : MOI.HEURISTIC_SOLUTION_REJECTED
end
