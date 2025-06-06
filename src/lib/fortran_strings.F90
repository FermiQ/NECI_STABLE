#include "macros.h"

module fortran_strings
    use constants, only: int32, int64, sp, dp
    implicit none
    save
    private
    public :: str, to_lower, to_upper, operator(.in.), split, Token_t, &
        count_char, join, to_int, to_int32, to_int64, to_realsp, to_realdp, &
        can_be_real, can_be_int

!>  @brief
!>    Convert to Fortran string
!>
!>  @author Oskar Weser
!>
!>  @details
!>  It is a generic procedure that accepts int32 or int64.
!>
!>  @param[in] An int32 or int64.
    interface str
        module procedure int32_to_str, int64_to_str, realsp_to_str, realdp_to_str, bool_to_str
    end interface

    interface operator(.in.)
        module procedure contains
    end interface

character(*), parameter ::  &
    UPPERCASE_chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ',&
    lowercase_chars = 'abcdefghijklmnopqrstuvwxyz'


    type :: Token_t
        character(len=:), allocatable :: str
    contains
        private
        procedure :: eq_Token_t
        generic, public :: operator(==) => eq_Token_t
        procedure :: neq_Token_t
        generic, public :: operator(/=) => neq_Token_t
        procedure :: add_Token_t
        generic, public :: operator(+) => add_Token_t
    end type

contains

    pure function int32_to_str(i) result(str)
        character(:), allocatable :: str
        integer(int32), intent(in) :: i
        character(range(i) + 2) :: tmp
        write(tmp, '(I0)') I
        str = trim(tmp)
    end function


    pure function int64_to_str(i) result(str)
        character(:), allocatable :: str
        integer(int64), intent(in) :: i
        character(range(i) + 2) :: tmp
        write(tmp, '(I0)') I
        str = trim(tmp)
    end function

    pure function realdp_to_str(x, after_comma) result(res)
        real(dp), intent(in) :: x
        integer, intent(in) :: after_comma
        character(100) :: tmp
        character(:), allocatable :: res
        write(tmp, '(e100.'//str(after_comma)//')') x
        res = trim(adjustl(tmp))
    end function

    pure function realsp_to_str(x, after_comma) result(res)
        real(sp), intent(in) :: x
        integer, intent(in) :: after_comma
        character(:), allocatable :: res
        res = str(real(x, dp), after_comma)
    end function

    pure function bool_to_str(cond) result(res)
        logical, intent(in) :: cond
        character(:), allocatable :: res
        if (cond) then
            res = "true"
        else
            res = "false"
        end if
    end function


    !> Changes a string to upper case
    pure function to_upper(in_str) result(string)
        character(*), intent(in) :: in_str
        character(len_trim(in_str)) :: string
        integer :: ic, i

        do i = 1, len(string)
            ic = index(lowercase_chars, in_str(i:i))
            if (ic > 0) then
                string(i:i) = UPPERCASE_chars(ic:ic)
            else
                string(i:i) = in_str(i:i)
            end if
        end do
    end function to_upper

    !> Changes a string to lower case
    pure function to_lower (in_str) result(string)
        character(*), intent(in) :: in_str
        character(len_trim(in_str)) :: string
        integer :: ic, i

        do i = 1, len(string)
            ic = index(UPPERCASE_chars, in_str(i:i))
            if (ic > 0) then
                string(i:i) = lowercase_chars(ic:ic)
            else
                string(i:i) = in_str(i:i)
            end if
        end do
    end function to_lower

    logical pure function contains(substring, string)
        character(*), intent(in) :: string, substring

        contains = index(string, substring) /= 0
    end function

    !> @brief
    !> Split string by delimiter (defaults to space).
    pure function split(expr, delimiter) result(res)
        character(*), intent(in) :: expr
        character(1), intent(in), optional :: delimiter
        type(Token_t), allocatable :: res(:)
        type(Token_t), allocatable :: tmp(:)
        character(len=1) :: delimiter_

        integer :: n, low, high

        def_default(delimiter_, delimiter, ' ')

        allocate(tmp(len(expr) / 2 + 1))
        low = 1; n = 0
        do while (low <= len(expr))
            do while (expr(low : low) == delimiter_)
                low = low + 1
                if (low > len(expr)) exit
            end do
            if (low > len(expr)) exit

            high = low
            if (high < len(expr)) then
                do while (expr(high + 1 : high + 1) /= delimiter_)
                    high = high + 1
                    if (high == len(expr)) exit
                end do
            end if
            n = n + 1
            tmp(n)%str = expr(low : high)
            low = high + 2
        end do
        res = tmp(: n)
    end function

    !> Join an array of tokens into one string
    pure function join(tokens, delimiter) result(res)
        type(Token_t), intent(in) :: tokens(:)
        character(*), intent(in) :: delimiter
        character(:), allocatable :: res
        integer :: i
        res = ''
        do i = 1, size(tokens) - 1
            res = res // tokens(i)%str // delimiter
        end do
        res = res // tokens(size(tokens))%str
    end function

    !> @brief
    !> Count the occurence of a character in a string.
    pure function count_char(str, char) result(c)
        character(len=*), intent(in) :: str
        character(len=1), intent(in) :: char
        integer :: c
        integer :: i

        c = 0
        do i = 1, len(str)
            if (str(i : i) == char) c = c + 1
        end do
    end function

    integer elemental function to_int(str)
        character(*), intent(in) :: str
        read(unit=str, fmt=*) to_int
    end function

    integer(int32) elemental function to_int32(str)
        character(*), intent(in) :: str
        read(unit=str, fmt=*) to_int32
    end function

    integer(int64) elemental function to_int64(str)
        character(*), intent(in) :: str
        read(unit=str, fmt=*) to_int64
    end function

    real(sp) elemental function to_realsp(str)
        character(*), intent(in) :: str
        read(unit=str, fmt=*) to_realsp
    end function

    real(dp) elemental function to_realdp(str)
        character(*), intent(in) :: str
        read(unit=str, fmt=*) to_realdp
    end function

    logical elemental function can_be_real(str)
        character(*), intent(in) :: str
        integer :: err
        real(dp) :: rtmp
        read(unit=str, iostat=err, fmt=*) rtmp
        can_be_real = err == 0
    end function

    logical elemental function can_be_int(str)
        character(*), intent(in) :: str
        integer :: itmp, err
        read(unit=str, iostat=err, fmt=*) itmp
        ! Some compilers parse 5.2 -> 5
        can_be_int = err == 0 .and. .not. ('.' .in. str)
    end function

    logical elemental function eq_Token_t(this, other)
        class(Token_t), intent(in) :: this, other
        eq_Token_t = this%str == other%str
    end function

    logical elemental function neq_Token_t(this, other)
        class(Token_t), intent(in) :: this, other
        neq_Token_t = this%str /= other%str
    end function

    type(Token_t) elemental function add_Token_t(this, other)
        class(Token_t), intent(in) :: this, other
        add_Token_t%str = this%str // other%str
    end function
end module fortran_strings
