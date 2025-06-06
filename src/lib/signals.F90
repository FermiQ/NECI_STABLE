#include "macros.h"
module neci_signals

    ! Here we manage the NECI signal handlers.
    !
    ! The actual legwork is done in C/C++ as the relevant constants are only
    ! accessible in signal.h.

    use, intrinsic :: iso_c_binding, only: c_int
    use constants, only: stdout
    use util_mod, only: stop_all, neci_flush
    implicit none
    private

    integer, volatile :: sigint_count

    interface
        subroutine init_signals_helper() bind(c)
        end subroutine

        subroutine clear_signals() bind(c)
        end subroutine
    end interface

    public :: init_signals, clear_signals

contains

    subroutine init_signals()

        ! Set the signal handlers, and set the call count to zero

        sigint_count = 0
        call init_signals_helper()

    end subroutine

    subroutine neci_sigint(signo) bind(c, name='neci_sigint')

        use soft_exit, only: tSoftExitFound

        ! Parameter unused. Required by POSIX
        integer(c_int), intent(in), value :: signo
        character(*), parameter :: t_r = 'neci_sigint'

        unused_var(signo)

        ! Flush existing output in the stdout buffer
        ! --> Try and avoid issues if we happen to Ctrl-C during a write.
        call neci_flush(stdout)
        write(stdout,*)
        write(stdout,*) '----------------------------------------'
        write(stdout,*) 'NECI SIGINT (Ctrl-C) handler'
        write(stdout,*)
        sigint_count = sigint_count + 1

        if (sigint_count == 1) then
            write(stdout,*) 'Calculation will cleanly exit at the next update cycle.'
            write(stdout,*) 'To kill the application immediately, resend signal again &
                       & (Ctrl-C)'
            write(stdout,*) '----------------------------------------'
            write(stdout,*)

            ! Trigger soft exit
            tSoftExitFound = .true.
        else
            write(stdout,*) 'Killing calculation'
            write(stdout,*) '----------------------------------------'
            write(stdout,*)
            call neci_flush(stdout)
            call stop_all(t_r, "User requested")
        end if

    end subroutine

end module
