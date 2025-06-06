#include "macros.h"

module local_spin

      use constants, only: dp, n_int, lenof_sign, write_state_t, inum_runs
      use bit_rep_data, only: IlutBits
      use LoggingData, only: tMCOutput
      use Parallel_neci, only: MPIAllreduce, iProcIndex, MPISumAll, root
      use SystemData, only: nel, nSpatOrbs
      use CalcData, only: tReadPops, StepsSft
      use double_occ_mod, only: sum_norm_psi_squared
      use FciMCData, only: iter, PreviousCycles, norm_psi, totwalkers, &
                           all_norm_psi_squared
      use util_mod, only: get_free_unit, near_zero, stats_out, stop_all, &
        neci_flush
      use guga_bitrepops, only: CSF_Info_t

      implicit none

      private

      public :: inst_local_spin, all_local_spin, &
                measure_local_spin, write_local_spin_stats, &
                rezero_local_spin_stats, init_local_spin_measure, &
                finalize_local_spin_measurement

      real(dp), allocatable :: inst_local_spin(:), all_local_spin(:)

contains

    subroutine measure_local_spin(real_sgn, csf_i)
        real(dp), intent(in) :: real_sgn(lenof_sign)
        type(CSF_Info_t), intent(in) :: csf_i
        real(dp) :: coeff, loc_spin(nSpatOrbs)
#if defined PROG_NUMRUNS_ || defined DOUBLERUN_
#ifdef CMPLX_
        character(*), parameter :: this_routine = "measure_local_spin"
        ! i do not want to deal with complex runs for now..
        call stop_all(this_routine, &
                      "complex double occupancy measurement not yet implemented!")
        unused_var(real_sgn)
#else
        coeff = real_sgn(1) * real_sgn(2)
#endif
#else
        coeff = abs(real_sgn(1))**2
#endif

        ! the current b vector should be fine to get the total spin
        loc_spin = csf_i%B_real / 2.0_dp * (csf_i%B_real / 2.0_dp + 1.0_dp)

        inst_local_spin = inst_local_spin + coeff * loc_spin

    end subroutine measure_local_spin

    subroutine finalize_local_spin_measurement()
        if (allocated(inst_local_spin)) deallocate(inst_local_spin)
        if (allocated(all_local_spin)) deallocate(all_local_spin)
    end subroutine finalize_local_spin_measurement

    subroutine rezero_local_spin_stats()
        inst_local_spin = 0.0_dp
    end subroutine rezero_local_spin_stats

    subroutine init_local_spin_measure
        if (allocated(inst_local_spin)) deallocate(inst_local_spin)
        if (allocated(all_local_spin)) deallocate(all_local_spin)
        allocate(inst_local_spin(nSpatOrbs), source = 0.0_dp)
        allocate(all_local_spin(nSpatOrbs), source = 0.0_dp)
    end subroutine init_local_spin_measure

    subroutine write_local_spin_stats(initial)
        logical, intent(in), optional :: initial

        type(write_state_t), save :: state
        logical, save :: inited = .false.
        integer :: i

        if (present(initial)) then
            state%init = initial
        else
            state%init = .false.
        end if

        if (iProcIndex == root .and. .not. inited) then
            state%funit = get_free_unit()
            call init_local_spin_output(state%funit)
            inited = .true.
        end if

        if (iProcIndex == root) then
            if (state%init .or. state%prepend) then
                write(state%funit, '("#")', advance='no')
                state%prepend = state%init

            elseif (.not. state%prepend) then
                write(state%funit, '(" ")', advance = 'no')
            end if

            state%cols = 0
            state%cols_mc = 0
            state%mc_out = tMCOutput

            call stats_out(state, .false., iter + PreviousCycles, 'Iter.')
            do i = 1, nSpatOrbs
                call stats_out(state, .false., all_local_spin(i) / &
                    (real(StepsSft,dp) * sum(all_norm_psi_squared) / real(inum_runs, dp)), 'Local Spin')
            end do


            write(state%funit, *)
            call neci_flush(state%funit)
        end if

    end subroutine write_local_spin_stats

    subroutine init_local_spin_output(funit)
        ! i need a routine to initialize the additional output, which I
        ! think should go into a seperate file for now!
        integer, intent(in) :: funit
        character(*), parameter :: this_routine = "init_local_spin_output"
        character(30) :: filename
        character(43) :: filename2
        character(12) :: num
        logical :: exists
        integer :: i, ierr

        filename = "local_spin_stats"

        if (tReadPops) then
            open(funit, file=filename, status='unknown', position='append')

        else

            inquire (file=filename, exist=exists)

            ! rename the existing file an create a new one
            if (exists) then

                i = 1
                do while (exists)
                    write(num, '(i12)') i
                    filename2 = trim(adjustl(filename))//"."// &
                                trim(adjustl(num))

                    inquire (file=filename2, exist=exists)
                    if (i > 10000) call stop_all(this_routine, &
                                                 "error finding free local_spin_stats")

                    i = i + 1
                end do

                ! i am not sure where this routine is defined:
                call rename(filename, filename2)
            end if

            open(funit, file=filename, status='unknown', iostat=ierr)

        end if

    end subroutine init_local_spin_output

end module local_spin
