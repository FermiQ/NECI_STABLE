#include "macros.h"
#:set primitive_types = {'real': {'sp', 'dp'}, 'complex': {'sp', 'dp'}}
#:set ZEROS = {'real': {'sp': '0._sp', 'dp': '0._dp'}, 'complex': {'sp': '(0._sp, 0._sp)', 'dp': '(0._dp, 0._dp)'}}

module basic_float_math
    use constants, only : sp, dp, EPS
    implicit none

    private
    public :: isclose, operator(.isclose.), near_zero, conjgt, get_nan, is_nan

    interface operator(.isclose.)
    #:for type, kinds in primitive_types.items()
    #:for kind in kinds
        module procedure isclose_for_operator_${type}$_${kind}$
    #:endfor
    #:endfor
    end interface

    interface isclose
    #:for type, kinds in primitive_types.items()
    #:for kind in kinds
        module procedure isclose_${type}$_${kind}$
    #:endfor
    #:endfor
    end interface

    interface near_zero
    #:for type, kinds in primitive_types.items()
    #:for kind in kinds
        module procedure near_zero_${type}$_${kind}$
    #:endfor
    #:endfor
    end interface

    interface conjgt
    #:for type, kinds in primitive_types.items()
    #:for kind in kinds
        module procedure conjgt_${type}$_${kind}$
    #:endfor
    #:endfor
    end interface

contains
    #:for type, kinds in primitive_types.items()
    #:for kind in kinds

        !> @brief
        !> Compare floating point numbers for equality
        !>
        !> @details
        !> The comparison is symmetric and decorrelates atol and rtol.
        !> A good discussion can be found here
        !> https://github.com/numpy/numpy/issues/10161
        !>
        !> @param[in] a
        !> @param[in] b
        !> @param[in] atol The absolute tolerance. Defaults to 0.
        !> @param[in] rtol The relative tolerance. Defaults to 1e-9.
        elemental function isclose_${type}$_${kind}$(a, b, atol, rtol) result(res)
            ${type}$(${kind}$), intent(in) :: a, b
            real(dp), intent(in), optional :: atol, rtol
            logical :: res

            real(dp) :: atol_, rtol_

            def_default(rtol_, rtol, 1e-9_dp)
            def_default(atol_, atol, 0._dp)

            res = abs(a - b) <= max(atol_, rtol_ * min(abs(a), abs(b)))
        end function

        !> Operator functions may only have two arguments.
        elemental function isclose_for_operator_${type}$_${kind}$(a, b) result(res)
            ${type}$(${kind}$), intent(in) :: a, b
            logical :: res

            res = isclose(a, b, atol=EPS)
        end function

        elemental function near_zero_${type}$_${kind}$(x, epsilon) result(res)
            ${type}$(${kind}$), intent(in) :: x
            real(dp), intent(in), optional :: epsilon
            logical :: res

            real(dp) :: epsilon_

            def_default(epsilon_, epsilon, EPS)

            res = isclose(x, ${ZEROS[type][kind]}$, atol=epsilon_, rtol=0._dp)
        end function
    #:endfor
    #:endfor

    #:for kind in primitive_types['real']
        elemental function conjgt_real_${kind}$(x) result(res)
            real(${kind}$), intent(in) :: x
            real(${kind}$) :: res
            res = x
        end function
    #:endfor

    #:for kind in primitive_types['complex']
        elemental function conjgt_complex_${kind}$(x) result(res)
            complex(${kind}$), intent(in) :: x
            complex(${kind}$) :: res
            res = conjg(x)
        end function
    #:endfor

    real(dp) pure function get_nan()
        ! If all of the compilers supported ieee_arithmetic
        ! --> could use ieee_value(1.0_dp, ieee_quiet_nan)
        real(dp) :: a, b
        a = 1
        b = 1
        get_nan = log(a - 2 * b)
    end function

    elemental logical function is_nan(r)
        ! If all of the compilers supported ieee_arithmetic
        ! --> could use ieee_is_nan (r)
        real(dp), intent(in) :: r

#ifdef GFORTRAN_
        is_nan = isnan(r)
#else
        is_nan = r /= r
#endif
    end function

end module
