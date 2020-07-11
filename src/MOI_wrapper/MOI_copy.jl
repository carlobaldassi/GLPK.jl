# =======================
#   `copy_to` function
# =======================

_add_bounds(::Vector{Float64}, ub, i, s::MOI.LessThan{Float64}) = ub[i] = s.upper
_add_bounds(lb, ::Vector{Float64}, i, s::MOI.GreaterThan{Float64}) = lb[i] = s.lower
_add_bounds(lb, ub, i, s::MOI.EqualTo{Float64}) = lb[i], ub[i] = s.value, s.value
_add_bounds(lb, ub, i, s::MOI.Interval{Float64}) = lb[i], ub[i] = s.lower, s.upper

_bound_type(::Type{MOI.Interval{Float64}}) = INTERVAL
_bound_type(::Type{MOI.EqualTo{Float64}}) = EQUAL_TO
_bound_type(::Type{S}) where S = NONE

function _extract_bound_data(src, mapping, lb, ub, bound_type, s::Type{S}) where S
    type = _bound_type(s)
    for con_index in MOI.get(
        src, MOI.ListOfConstraintIndices{MOI.SingleVariable, S}()
    )
        f = MOI.get(src, MOI.ConstraintFunction(), con_index)
        s = MOI.get(src, MOI.ConstraintSet(), con_index)
        column = mapping.varmap[f.variable].value
        _add_bounds(lb, ub, column, s)
        bound_type[column] = type
        mapping.conmap[con_index] = MOI.ConstraintIndex{MOI.SingleVariable, S}(column)
    end
end

_add_type(type, i, ::MOI.Integer) = type[i] = INTEGER
_add_type(type, i, ::MOI.ZeroOne) = type[i] = BINARY

function _extract_type_data(src, mapping, var_type, ::Type{S}) where S
    for con_index in MOI.get(
        src, MOI.ListOfConstraintIndices{MOI.SingleVariable, S}()
    )
        f = MOI.get(src, MOI.ConstraintFunction(), con_index)
        column = mapping.varmap[f.variable].value
        _add_type(var_type, column, S())
        mapping.conmap[con_index] = MOI.ConstraintIndex{MOI.SingleVariable, S}(column)
    end
end

function _copy_to_columns(dest, src, mapping)
    x_src = MOI.get(src, MOI.ListOfVariableIndices())
    N = Cint(length(x_src))
    for i = 1:N
        mapping.varmap[x_src[i]] = MOI.VariableIndex(i)
    end

    # passing objective as attribute
    # fobj = MOI.get(src, MOI.ObjectiveFunction{MOI.ScalarAffineFunction{Float64}}())
    # c = fill(0.0, N)
    # for term in fobj.terms
    #     i = mapping.varmap[term.variable_index].value
    #     c[i] += term.coefficient
    # end

    # # pass objective constant
    # glp_set_obj_coef(dest, 0, fobj.constant)
    return N#, c
end

_bounds2(s::MOI.GreaterThan{Float64}) = (s.lower, Inf)
_bounds2(s::MOI.LessThan{Float64}) = (-Inf, s.upper)
_bounds2(s::MOI.EqualTo{Float64}) = (s.value, s.value)
_bounds2(s::MOI.Interval{Float64}) = (s.lower, s.upper)

function add_sizehint!(vec, n)
    len = length(vec)
    return sizehint!(vec, len + n)
end

function _extract_row_data(src, mapping, lb, ub, I, J, V, ::Type{S}) where S
    row = length(I) == 0 ? 1 : I[end] + 1
    list = MOI.get(
        src, MOI.ListOfConstraintIndices{MOI.ScalarAffineFunction{Float64}, S}()
    )
    add_sizehint!(lb, length(list))
    add_sizehint!(ub, length(list))
    n_terms = 0
    fs = Array{MOI.ScalarAffineFunction{Float64}}(undef, length(list))
    for (i,c_index) in enumerate(list)
        f = MOIU.canonical(MOI.get(src, MOI.ConstraintFunction(), c_index))
        fs[i] = f
        l, u = _bounds2(MOI.get(src, MOI.ConstraintSet(), c_index))
        push!(lb, l - f.constant)
        push!(ub, u - f.constant)
        n_terms += length(f.terms)
    end
    add_sizehint!(I, n_terms)
    add_sizehint!(J, n_terms)
    add_sizehint!(V, n_terms)
    for (i,c_index) in enumerate(list)
        f = fs[i]#MOI.get(src, MOI.ConstraintFunction(), c_index)
        for term in f.terms
            push!(I, Cint(row))
            push!(J, Cint(mapping.varmap[term.variable_index].value))
            push!(V, term.coefficient)
        end
        mapping.conmap[c_index] = MOI.ConstraintIndex{
            MOI.ScalarAffineFunction{Float64}, S
        }(length(ub))
        row += 1
    end
    return
end

function test_data(src, dest)
    for (F, S) in MOI.get(src, MOI.ListOfConstraints())
        if !MOI.supports_constraint(dest, F, S)
            throw(MOI.UnsupportedConstraint{F, S}("GLPK.Optimizer does not support constraints of type $F-in-$S."))
        end
    end
    fobj_type = MOI.get(src, MOI.ObjectiveFunctionType())
    if !MOI.supports(dest, MOI.ObjectiveFunction{fobj_type}())
        throw(MOI.UnsupportedAttribute(MOI.ObjectiveFunction(fobj_type)))
    end
end

function _add_all_variables(model::Optimizer, N, lower, upper, bound_type,
    var_type)
    glp_add_cols(model, N)
    for i in 1:N
        bound = get_moi_bound_type(lower[i], upper[i], bound_type)
        # We started from empty model.variable_info, hence we assume ordering
        index = CleverDicts.add_item(
            model.variable_info, VariableInfo(MOI.VariableIndex(i), i, bound, var_type[i])
        )
        glp_bound_type = get_glp_bound_type(lower[i], upper[i])
        glp_set_col_bnds(model, i, glp_bound_type, lower[i], upper[i])
        if var_type[i] == BINARY
            model.num_binaries += 1
        end
        if var_type[i] == INTEGER
            model.num_integers += 1
        end
    end
    return nothing# indices
end

function _add_all_constraints(dest::Optimizer, rl, ru, I, J, V)

    n_constraints = length(rl)

    glp_add_rows(dest, n_constraints)
    # @show I, J, V
    glp_load_matrix(dest, length(I), offset(I), offset(J), offset(V))
    for i in 1:n_constraints
        # assume ordered indexing
        if rl[i] == ru[i]
            glp_set_row_bnds(dest, i, GLP_FX, rl[i], ru[i])
            CleverDicts.add_item(dest.affine_constraint_info,
                ConstraintInfo(i, MOI.EqualTo{Float64}(rl[i])))
        elseif ru[i] == Inf
            glp_set_row_bnds(dest, i, GLP_LO, rl[i], GLP_DBL_MAX)
            CleverDicts.add_item(dest.affine_constraint_info,
                ConstraintInfo(i, MOI.GreaterThan{Float64}(rl[i])))
        else
            glp_set_row_bnds(dest, i, GLP_UP, -GLP_DBL_MAX, ru[i])
            CleverDicts.add_item(dest.affine_constraint_info,
                ConstraintInfo(i, MOI.LessThan{Float64}(ru[i])))
        end
    end
    return
end

function MOI.copy_to(
# function _copy_to(
    dest::Optimizer,
    src::MOI.ModelLike;
    copy_names::Bool = false
)
    @assert MOI.is_empty(dest)
    test_data(src, dest)

    mapping = MOI.Utilities.IndexMap()
    N = _copy_to_columns(dest, src, mapping) # not getting obj
    cl, cu = fill(-Inf, N), fill(Inf, N)
    bound_type = fill(NONE, N)
    var_type = fill(CONTINUOUS, N)

    _extract_bound_data(src, mapping, cl, cu, bound_type, MOI.GreaterThan{Float64})
    _extract_bound_data(src, mapping, cl, cu, bound_type, MOI.LessThan{Float64})
    _extract_bound_data(src, mapping, cl, cu, bound_type, MOI.EqualTo{Float64})
    _extract_bound_data(src, mapping, cl, cu, bound_type, MOI.Interval{Float64})

    _extract_type_data(src, mapping, var_type, MOI.Integer)
    _extract_type_data(src, mapping, var_type, MOI.ZeroOne)

    _add_all_variables(dest, N, cl, cu, bound_type, var_type)

    rl, ru, I, J, V = Float64[], Float64[], Cint[], Cint[], Float64[]

    # add canonical
    _extract_row_data(src, mapping, rl, ru, I, J, V, MOI.GreaterThan{Float64})
    _extract_row_data(src, mapping, rl, ru, I, J, V, MOI.LessThan{Float64})
    _extract_row_data(src, mapping, rl, ru, I, J, V, MOI.EqualTo{Float64})
    # range constraints not supported
    # _extract_row_data(src, mapping, rl, ru, I, J, V, MOI.Interval{Float64})

    _add_all_constraints(dest, rl, ru, I, J, V)

    # model attribute
    # sense = MOI.get(src, MOI.ObjectiveSense())
    # MOI.set(dest, MOI.ObjectiveSense(), sense)

    # Copy model attributes
    # obj function and sense are passet here
    MOIU.pass_attributes(dest, src, copy_names, mapping)

    variables = MOI.get(src, MOI.ListOfVariableIndices())
    MOIU.pass_attributes(dest, src, copy_names, mapping, variables)

    pass_constraint_attributes(dest, src, copy_names, mapping)
    return mapping
end

function pass_constraint_attributes(dest, src, copy_names, mapping)
    ctr_types = MOI.get(src, MOI.ListOfConstraints())
    for (F,S) in ctr_types
        pass_constraint_attributes(dest, src, copy_names, mapping, F, S)
    end
    return
end
function pass_constraint_attributes(dest, src, copy_names, mapping,
    ::Type{F}, ::Type{S}) where {F,S}
    indices = MOI.get(dest, MOI.ListOfConstraintIndices{F, S}())
    MOIU.pass_attributes(dest, src, copy_names, mapping, indices)
    return
end