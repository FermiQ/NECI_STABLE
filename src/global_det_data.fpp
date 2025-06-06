#include "macros.h"
#:include "macros.fpph"

module global_det_data
    use SystemData, only: nel
    use CalcData, only: tContTimeFCIMC, tContTimeFull, tStoredDets, tActivateLAS, &
                        tSeniorInitiators, tAutoAdaptiveShift, tPairedReplicas, &
                        tReplicaEstimates, tMoveGlobalDetData, tScaleBlooms
    use LoggingData, only: tRDMonFly, tExplicitAllRDM, tTransitionRDMs, tAccumPops
    use FciMCData, only: MaxWalkersPart
    use MemoryManager, only: LogMemAlloc, LogMemDeAlloc
    use constants, only: dp, int32, int64, n_int, inum_runs, lenof_sign, eps
    use util_mod, only: stop_all, operator(.div.)
    use constants, only: stdout
    implicit none

    private
    public :: writeFVals, readFVals, write_max_ratio, set_all_max_ratios, &
        writeAPVals, readAPVals, writeFValsAsInt, &
        readFValsAsInt, &
        writeAPValsAsInt, readAPValsAsInt, len_av_sgn_tot, len_iter_occ_tot, &
        get_determinant, set_det_diagH, det_diagH, set_det_offdiagH, &
        det_offdiagH, max_ratio_size, fvals_size, apvals_size, &
        global_determinant_data, global_determinant_data_tmp, &
        set_spawn_rate, set_all_spawn_pops, reset_all_tau_ints, &
        reset_all_shift_ints, store_decoding, &
        reset_all_tot_spawns, reset_all_acc_spawns, &
        get_iter_occ_tot, get_av_sgn_tot, &
        set_av_sgn_tot, get_spawn_pop, get_tau_int, get_shift_int, &
        get_neg_spawns, get_pos_spawns, set_iter_occ_tot, get_pops_sum_full, &
        clean_global_det_data, init_global_det_data, store_spawn, &
        update_acc_spawns, update_tot_spawns, get_tot_spawns, get_acc_spawns, &
        replica_est_len, get_spawn_rate, reset_tau_int, get_all_spawn_pops, &
        reset_shift_int, update_shift_int, update_tau_int, set_spawn_pop, &
        update_pops_sum_all, get_pops_iter, get_max_ratio, update_max_ratio, &
        set_supergroup_idx, get_supergroup_idx
#ifdef USE_HDF_
    public :: set_max_ratio_hdf5Int, write_max_ratio_as_int
#endif

    ! for unit tests
    public :: pos_acc_spawns, pos_tot_spawns, set_max_ratio


    ! This is the tag for allocation/deallocation.
    integer :: glob_tag = 0, glob_det_tag = 0, glob_tmp_tag = 0

    ! This is the data used to find the elements inside the storage array.

    ! The diagonal matrix element is always stored. As it is a real value it
    ! always has a length of 1 (never cplx). Therefore, encode these values
    ! as parameters to assist optimisation.
    integer, parameter :: pos_hel = 1, len_hel = 1

    ! The off-diagonal matrix element <D0|H|D>.
    integer :: pos_hel_off, len_hel_off

    ! The supergroup_idx is always an int64 and should have the same length
    ! as real64
    integer :: pos_sg_idx
    integer, parameter :: len_sg_idx = 1

    !The initial population of a determinant at spawning time.
    integer :: pos_spawn_pop, len_spawn_pop

    !The integral of imaginary time since the spawing of this determinant.
    integer :: pos_tau_int, len_tau_int

    !The integral of shift since the spawning of this determinant.
    integer :: pos_shift_int, len_shift_int

    ! Total spawns and the number of successful ones according the initiator criterion
    integer :: len_tot_spawns, len_acc_spawns
    integer :: pos_tot_spawns, pos_acc_spawns
    ! total size of acc + tot spawns
    integer :: fvals_size

    ! Accumlated sum of population and the last iteration it was increased
    integer :: len_pops_sum, len_pops_iter
    integer :: pos_pops_sum, pos_pops_iter
    !total size of pops sum and iter
    integer :: apvals_size

    ! Average sign and first occupation of iteration.
    integer :: pos_av_sgn, len_av_sgn
    integer :: pos_iter_occ, len_iter_occ

    ! Average sign and first occupation of iteration, for transition RDMs.
    integer :: pos_av_sgn_transition, len_av_sgn_transition
    integer :: pos_iter_occ_transition, len_iter_occ_transition

    ! The total length of average sign and first occupation iteration, for
    ! both the standard and transition RDMs.
    integer :: len_av_sgn_tot, len_iter_occ_tot

    integer :: pos_spawn_rate, len_spawn_rate

    ! global storage of history of determinants: number of pos/neg spawns and
    ! time since a determinant died
    integer :: len_pos_spawns, len_neg_spawns
    integer :: pos_pos_spawns, pos_neg_spawns

    ! lenght of the determinant and its position
    integer :: len_det_orbs
    ! position + length of the maximum Hij/pgen ration per determinant
    integer :: pos_max_ratio, len_max_ratio, max_ratio_size
    ! Legth of arrays storing estimates to be written to the replica_est file
    integer :: replica_est_len

    ! And somewhere to store the actual data.
    real(dp), pointer :: global_determinant_data(:, :) => null()
    integer, pointer :: global_determinants(:, :) => null()
    real(dp), pointer :: global_determinant_data_tmp(:, :) => null()

    ! Routines for setting the properties of both standard and transition
    ! RDMs in a combined manner.
    interface set_av_sgn_tot
        module procedure set_av_sgn_tot_sgl
        module procedure set_av_sgn_tot_all
    end interface

    interface set_iter_occ_tot
        module procedure set_iter_occ_tot_sgl
        module procedure set_iter_occ_tot_all
    end interface

    ! Routines for extracting the properties of both standard and transition RDMs.
    interface get_av_sgn_tot
        module procedure get_av_sgn_tot_sgl
        module procedure get_av_sgn_tot_all
    end interface

    interface get_iter_occ_tot
        module procedure get_iter_occ_tot_sgl
        module procedure get_iter_occ_tot_all
    end interface

contains

    subroutine init_global_det_data(nrdms_standard, nrdms_transition)

        use FciMCData, only: var_e_num, rep_est_overlap
        use FciMCData, only: var_e_num_all, rep_est_overlap_all
        use FciMCData, only: e_squared_num, e_squared_num_all
        use FciMCData, only: en2_pert, en2_pert_all
        use FciMCData, only: en2_new, en2_new_all
        use FciMCData, only: precond_e_num, precond_denom
        use FciMCData, only: precond_e_num_all, precond_denom_all

        ! Initialise the global storage of determinant specific persistent
        ! data
        !
        ! --> This is the data that should not be transmitted with each
        !     particle
        ! --> It is not stored in the bit representation

        integer, intent(in) :: nrdms_standard, nrdms_transition

        integer :: tot_len
        integer :: ierr
        character(*), parameter :: this_routine = 'init_global_det_data'

        ! The position and size of diagonal matrix elements in the array.
        ! This is set as a module wide parameter, rather than as runtime, as
        ! it is constant, and this aids optimisation.
        ! pos_hel = 1
        ! len_hel = 1

#ifdef CMPLX_
        len_hel_off = 1
#else
        len_hel_off = 2
#endif

        len_spawn_pop = lenof_sign

        if (tSeniorInitiators) then
            len_tau_int = inum_runs
            len_shift_int = inum_runs
        else
            len_tau_int = 0
            len_shift_int = 0
        end if

        if (tAutoAdaptiveShift) then
            len_tot_spawns = inum_runs
            len_acc_spawns = inum_runs
        else
            len_tot_spawns = 0
            len_acc_spawns = 0
        end if
        fvals_size = len_tot_spawns + len_acc_spawns

        if (tAccumPops) then
            len_pops_sum = lenof_sign
            len_pops_iter = 1
        else
            len_pops_sum = 0
            len_pops_iter = 0
        end if
        apvals_size = len_pops_sum + len_pops_iter

        ! If we are using calculating RDMs stochastically, need to include the
        ! average sign and the iteration on which it became occupied.
        if (tRDMonFly .and. .not. tExplicitAllRDM) then
            len_av_sgn = 2 * nrdms_standard
            len_iter_occ = 2 * nrdms_standard
            ! The total lengths, including both standard and transition RDMs.
            len_av_sgn_tot = 2 * nrdms_standard
            len_iter_occ_tot = 2 * nrdms_standard
            ! If we are calculating transition RDMs, then we also need to
            ! include sign averages over different sets of blocks,
            ! corresponding to the ground state combined with all other
            ! excited states.
            if (tTransitionRDMs) then
                len_av_sgn_transition = 2 * nrdms_transition
                len_iter_occ_transition = 2 * nrdms_transition
                len_av_sgn_tot = len_av_sgn + len_av_sgn_transition
                len_iter_occ_tot = len_iter_occ + len_iter_occ_transition
            end if
            write (stdout, '(" The average current signs before death will be stored&
                       & for use in the RDMs.")')
        else
            len_av_sgn = 0
            len_iter_occ = 0
        end if

        ! If we are using continuous time, and storing the spawning rates
        len_spawn_rate = 0
        if (tContTimeFCIMC .and. tContTimeFull) then
            len_spawn_rate = 1
        end if

        if (tStoredDets) then
            len_det_orbs = nel
        else
            len_det_orbs = 0
        end if

        if (tActivateLAS) then
            len_pos_spawns = lenof_sign
            len_neg_spawns = lenof_sign
        else
            len_pos_spawns = 0
            len_neg_spawns = 0
        end if

        max_ratio_size = 1
        if (tScaleBlooms) then
            len_max_ratio = max_ratio_size
        else
            len_max_ratio = 0
        end if

        ! Get the starting positions
        pos_hel_off = pos_hel + len_hel
        pos_spawn_pop = pos_hel_off + len_hel_off
        pos_tau_int = pos_spawn_pop + len_spawn_pop
        pos_shift_int = pos_tau_int + len_tau_int
        pos_tot_spawns = pos_shift_int + len_shift_int
        pos_acc_spawns = pos_tot_spawns + len_tot_spawns
        pos_pops_sum = pos_acc_spawns + len_acc_spawns
        pos_pops_iter = pos_pops_sum + len_pops_sum
        pos_av_sgn = pos_pops_iter + len_pops_iter
        pos_av_sgn_transition = pos_av_sgn + len_av_sgn
        pos_iter_occ = pos_av_sgn_transition + len_av_sgn_transition
        pos_iter_occ_transition = pos_iter_occ + len_iter_occ
        pos_spawn_rate = pos_iter_occ_transition + len_iter_occ_transition
        pos_pos_spawns = pos_spawn_rate + len_spawn_rate
        pos_neg_spawns = pos_pos_spawns + len_pos_spawns
        pos_max_ratio = pos_neg_spawns + len_neg_spawns
        pos_sg_idx = pos_max_ratio + len_max_ratio

        tot_len = len_hel + len_hel_off + len_spawn_pop + len_tau_int + &
                  len_shift_int + len_tot_spawns + len_acc_spawns + &
                  len_pops_sum + len_pops_iter + len_av_sgn_tot + &
                  len_iter_occ_tot + len_pos_spawns + len_neg_spawns + &
                  len_max_ratio + len_sg_idx

        if (tPairedReplicas) then
            replica_est_len = lenof_sign.div.2
        else
            replica_est_len = lenof_sign
        end if

        if (tReplicaEstimates) then
            allocate(var_e_num(replica_est_len))
            allocate(rep_est_overlap(replica_est_len))
            allocate(var_e_num_all(replica_est_len))
            allocate(rep_est_overlap_all(replica_est_len))
            allocate(e_squared_num(replica_est_len))
            allocate(e_squared_num_all(replica_est_len))
            allocate(en2_pert(replica_est_len))
            allocate(en2_pert_all(replica_est_len))
            allocate(en2_new(replica_est_len))
            allocate(en2_new_all(replica_est_len))
            allocate(precond_e_num(replica_est_len))
            allocate(precond_denom(replica_est_len))
            allocate(precond_e_num_all(replica_est_len))
            allocate(precond_denom_all(replica_est_len))
        end if

        ! Allocate and log the required memory (globally)
        allocate(global_determinant_data(tot_len, MaxWalkersPart), stat=ierr)
        @:log_alloc(global_determinant_data, glob_tag, ierr)

        if (tMoveGlobalDetData) then
            allocate(global_determinant_data_tmp(tot_len, MaxWalkersPart), stat=ierr)
            @:log_alloc(global_determinant_data_tmp, glob_tmp_tag, ierr)
        end if

        if (tStoredDets) then
            allocate(global_determinants(len_det_orbs, MaxWalkersPart), stat=ierr)
           @:log_alloc(global_determinants, glob_det_tag, ierr)
        end if

        write(stdout, '(a,f14.6,a)') &
            ' Determinant related persistent storage requires: ', &
            (4.0_dp * real(len_det_orbs * MaxWalkersPart, dp) &
             + 8.0_dp * real(tot_len * MaxWalkersPart, dp)) / 1048576_dp, &
            ' Mb / processor'

        ! As an added safety feature
        global_determinant_data = 0.0_dp
        if (tStoredDets) global_determinants = 0
        if (tMoveGlobalDetData) global_determinant_data_tmp = 0.0_dp

    end subroutine

    subroutine clean_global_det_data()

        character(*), parameter :: this_routine = 'clean_global_det_data'

        ! Cleanup the global storage for determinant specific data

        if (associated(global_determinants)) then
            deallocate(global_determinants)
            log_dealloc(glob_det_tag)
            glob_det_tag = 0
            nullify (global_determinants)
        end if

        if (associated(global_determinant_data)) then
            deallocate(global_determinant_data)
            log_dealloc(glob_tag)
            glob_tag = 0
            nullify (global_determinant_data)
        end if

        if (associated(global_determinant_data_tmp)) then
            deallocate(global_determinant_data_tmp)
            log_dealloc(glob_tmp_tag)
            glob_tmp_tag = 0
            nullify (global_determinant_data_tmp)
        end if

    end subroutine

    ! These are accessor functions to currentH --> they are data access/setting
    !
    ! Access the global_determinant_data structure by site index (j).

    subroutine set_det_diagH(j, hel_r)

        ! Diagonal matrix elements are real --> store a real value

        integer, intent(in) :: j
        real(dp), intent(in) :: hel_r

        global_determinant_data(pos_hel, j) = hel_r

    end subroutine

    function det_diagH(j) result(hel_r)

        integer, intent(in) :: j
        real(dp) :: hel_r

        hel_r = global_determinant_data(pos_hel, j)

    end function

    subroutine set_det_offdiagH(j, hel)

        integer, intent(in) :: j
        HElement_t(dp), intent(in) :: hel

#ifdef CMPLX_
        global_determinant_data(pos_hel_off, j) = real(hel,dp)
        global_determinant_data(pos_hel_off+1, j) = aimag(hel)
#else
        global_determinant_data(pos_hel_off, j) = hel
#endif

    end subroutine

    function det_offdiagH(j) result(hel)

        integer, intent(in) :: j
        HElement_t(dp) :: hel

#ifdef CMPLX_
        hel = cmplx( global_determinant_data(pos_hel_off, j), &
                     global_determinant_data(pos_hel_off+1, j), dp)
#else
        hel = global_determinant_data(pos_hel_off, j)
#endif

    end function

    ! Store the supergroup index for a given determinant.
    subroutine set_supergroup_idx(j, sg_idx)

        integer, intent(in) :: j
        integer, intent(in) :: sg_idx

        global_determinant_data(pos_sg_idx, j) = transfer(int(sg_idx, int64), mold=global_determinant_data(pos_sg_idx, j))

    end subroutine

    pure function get_supergroup_idx(j) result(sg_idx)

        integer, intent(in) :: j
        integer :: sg_idx

        integer(int64) :: sg_idx_tmp

        sg_idx_tmp = transfer(global_determinant_data(pos_sg_idx, j), mold=sg_idx_tmp)
        sg_idx = int(sg_idx_tmp)
    end function

    subroutine set_spawn_pop(j, part, t)

        integer, intent(in) :: j, part
        real(dp), intent(in) :: t

        global_determinant_data(pos_spawn_pop + part - 1, j) = t

    end subroutine

    function get_spawn_pop(j, part) result(t)

        integer, intent(in) :: j, part
        real(dp) :: t

        t = global_determinant_data(pos_spawn_pop + part - 1, j)

    end function

    subroutine set_all_spawn_pops(j, t)

        integer, intent(in) :: j
        real(dp), dimension(lenof_sign), intent(in) :: t

        global_determinant_data(pos_spawn_pop:pos_spawn_pop + len_spawn_pop - 1, j) = t(:)

    end subroutine

    function get_all_spawn_pops(j) result(t)

        integer, intent(in) :: j
        real(dp), dimension(lenof_sign) :: t

        t(:) = global_determinant_data(pos_spawn_pop:pos_spawn_pop + len_spawn_pop - 1, j)

    end function

    subroutine reset_all_tau_ints(j)

        integer, intent(in) :: j

        global_determinant_data(pos_tau_int:pos_tau_int + len_tau_int - 1, j) = 0.0_dp

    end subroutine

    subroutine reset_tau_int(j, run)

        integer, intent(in) :: j, run

        global_determinant_data(pos_tau_int + run - 1, j) = 0.0_dp

    end subroutine

    subroutine update_tau_int(j, run, t)

        integer, intent(in) :: j, run
        real(dp), intent(in) :: t

        global_determinant_data(pos_tau_int + run - 1, j) = global_determinant_data(pos_tau_int + run - 1, j) + t

    end subroutine

    function get_tau_int(j, run) result(t)

        integer, intent(in) :: j, run
        real(dp) :: t

        t = global_determinant_data(pos_tau_int + run - 1, j)

    end function

    subroutine reset_all_shift_ints(j)

        integer, intent(in) :: j

        global_determinant_data(pos_shift_int:pos_shift_int + len_shift_int - 1, j) = 0.0_dp

    end subroutine

    subroutine reset_shift_int(j, run)

        integer, intent(in) :: j, run

        global_determinant_data(pos_shift_int + run - 1, j) = 0.0_dp

    end subroutine

    subroutine update_shift_int(j, run, t)

        integer, intent(in) :: j, run
        real(dp), intent(in) :: t

        global_determinant_data(pos_shift_int + run - 1, j) = global_determinant_data(pos_shift_int + run - 1, j) + t

    end subroutine

    function get_shift_int(j, run) result(t)

        integer, intent(in) :: j, run
        real(dp) :: t

        t = global_determinant_data(pos_shift_int + run - 1, j)

    end function

    subroutine reset_all_tot_spawns(j)

        integer, intent(in) :: j

        global_determinant_data(pos_tot_spawns:pos_tot_spawns + len_tot_spawns - 1, j) = 0.0_dp

    end subroutine

    subroutine update_tot_spawns(j, run, t)

        integer, intent(in) :: j, run
        real(dp), intent(in) :: t

        global_determinant_data(pos_tot_spawns + run - 1, j) = global_determinant_data(pos_tot_spawns + run - 1, j) + t

    end subroutine

    pure function get_tot_spawns(j, run) result(t)

        integer, intent(in) :: j, run
        real(dp) :: t

        t = global_determinant_data(pos_tot_spawns + run - 1, j)

    end function

    subroutine readFVals(fvals, ndets, initial)
        implicit none
        real(dp), intent(in) :: fvals(2 * inum_runs, ndets)
        integer, intent(in) :: ndets
        integer, intent(in), optional :: initial
        integer :: start
        integer :: j
        integer :: run

        def_default(start, initial, 1)

        ! set all values of tot/acc spawns using the read-in values from fvals
        ! this is used in popsfile read-in to get the values from the previous calculation
        do j = 1, ndets
            do run = 1, inum_runs
                global_determinant_data(pos_acc_spawns + run - 1, j + start - 1) = &
                    fvals(run, j)
                global_determinant_data(pos_tot_spawns + run - 1, j + start - 1) = &
                    fvals(inum_runs + run, j)
            end do
        end do
    end subroutine readFVals

    subroutine readFValsAsInt(fvals, j)
        implicit none
        integer(n_int), intent(in) :: fvals(:)
        integer, intent(in) :: j
        integer :: run
        real(dp) :: realVal = 0.0_dp

        ! Read the acc. and tot. spawns from a contiguous integer array of size (2*inum_runs)
        ! This is useful for HDF5 subroutines which currently only accept integer arrays

        ! Check the input's size
        if (size(fvals) >= (2 * inum_runs)) then
            do run = 1, inum_runs
                global_determinant_data(pos_acc_spawns + run - 1, j) = transfer(fvals(run), realVal)
                global_determinant_data(pos_tot_spawns + run - 1, j) = transfer(fvals(run + inum_runs), realVal)
            end do
        else
            print *, "WARNING: Dimension mismatch in readFValsAsInt. Ignoring read data"
        end if
    end subroutine readFValsAsInt

    subroutine writeFValsAsInt(fvals, j)
        implicit none
        integer(n_int), intent(inout) :: fvals(:)
        integer, intent(in) :: j
        integer :: k

        ! Write the acc. and tot. spawns in a contiguous integer array of size (2*inum_runs)
        ! This is useful for HDF5 subroutines which currently only accept integer arrays

        if (size(fvals) >= 2 * inum_runs) then
            do k = 1, inum_runs
                fvals(k) = transfer(get_acc_spawns(j, k), fvals(k))
            end do
            do k = 1, inum_runs
                fvals(k + inum_runs) = transfer(get_tot_spawns(j, k), fvals(k))
            end do
        else
            ! the buffer has unsuitable size, print a warning
            print *, "WARNING: Dimension mismatch in writeFValsAsInt. Writing 0"
            fvals = 0
        end if
    end subroutine writeFValsAsInt

    subroutine writeFVals(fvals, ndets, initial)
        implicit none
        real(dp), intent(inout) :: fvals(:, :)
        integer, intent(in) :: ndets
        integer, intent(in), optional :: initial
        integer :: j, k, start

        def_default(start, initial, 1)

        ! write the acc. and tot. spawns per determinant in a contiguous array
        ! fvals(:,j) = (acc, tot) for determinant j (2*inum_runs in size)
        do j = 1, nDets
            do k = 1, inum_runs
                fvals(k, j) = get_acc_spawns(j + start - 1, k)
            end do
            do k = 1, inum_runs
                fvals(k + inum_runs, j) = get_tot_spawns(j + start - 1, k)
            end do
        end do
    end subroutine writeFVals

    !------------------------------------------------------------------------------------------!

    subroutine reset_all_acc_spawns(j)

        integer, intent(in) :: j

        global_determinant_data(pos_acc_spawns:pos_acc_spawns + len_acc_spawns - 1, j) = 0.0_dp

    end subroutine

    subroutine update_acc_spawns(j, run, t)

        integer, intent(in) :: j, run
        real(dp), intent(in) :: t

        global_determinant_data(pos_acc_spawns + run - 1, j) = global_determinant_data(pos_acc_spawns + run - 1, j) + t

    end subroutine

    pure function get_acc_spawns(j, run) result(t)

        integer, intent(in) :: j, run
        real(dp) :: t

        t = global_determinant_data(pos_acc_spawns + run - 1, j)

    end function

    !------------------------------------------------------------------------------------------!

    subroutine update_pops_sum_all(ndets, iter)
        use FciMCData, only: CurrentDets
        use bit_rep_data, only: extract_sign
        integer(int64), intent(in) :: ndets
        integer, intent(in) :: iter
        real(dp) :: CurrentSign(lenof_sign)
        integer :: j

        do j = 1, int(ndets)
            call extract_sign(CurrentDets(:, j), CurrentSign)
            if (IsUnoccDet(CurrentSign)) cycle

            global_determinant_data(pos_pops_sum:pos_pops_sum + len_pops_sum - 1, j) &
                = global_determinant_data(pos_pops_sum:pos_pops_sum + len_pops_sum - 1, j) &
                  + CurrentSign(:)

            global_determinant_data(pos_pops_iter, j) = DBLE(iter)
        end do
    end subroutine

    pure function get_pops_sum(j, part) result(AccSign)

        integer, intent(in) :: j, part
        real(dp) :: AccSign

        AccSign = global_determinant_data(pos_pops_sum + part - 1, j)
    end function

    pure function get_pops_sum_full(j) result(AccSign)

        integer, intent(in) :: j
        real(dp) :: AccSign(lenof_sign)

        AccSign(:) = global_determinant_data(pos_pops_sum:pos_pops_sum + len_pops_sum - 1, j)
    end function

    pure function get_pops_iter(j) result(iter)

        integer, intent(in) :: j
        real(dp) :: iter

        iter = global_determinant_data(pos_pops_iter, j)

    end function

    subroutine writeAPValsAsInt(apvals, j)
        implicit none
        integer(n_int), intent(inout) :: apvals(:)
        integer, intent(in) ::j
        integer :: k

        ! Write the accumlated population values (pops_sum and pop_iter)
        ! in a contiguous integer array of size (lenof_sing+1).
        ! This is useful for HDF5 subroutines which currently only accept integer arrays

        if (size(apvals, dim=1) >= lenof_sign + 1) then
            do k = 1, lenof_sign
                apvals(k) = transfer(get_pops_sum(j, k), apvals(k))
            end do
            apvals(lenof_sign + 1) = transfer(get_pops_iter(j), apvals(k))
        else
            ! the buffer has unsuitable size, print a warning
            print *, "WARNING: Dimension mismatch in writeAPValsAsInt. Writing 0"
            apvals = 0
        end if

    end subroutine writeAPValsAsInt

    subroutine readAPValsAsInt(apvals, j)
        implicit none
        integer(n_int), intent(in) :: apvals(:)
        integer, intent(in) :: j

        integer :: k
        real(dp) :: realVal = 0.0_dp

        ! Read the accumlated population values (pops_sum and pop_iter)
        ! in a contiguous integer array of size (lenof_sing+1).
        ! This is useful for HDF5 subroutines which currently only accept integer arrays

        if (size(apvals, dim=1) >= lenof_sign + 1) then
            do k = 1, lenof_sign
                global_determinant_data(pos_pops_sum + k - 1, j) = transfer(apvals(k), realVal)
            end do
            global_determinant_data(pos_pops_iter, j) = transfer(apvals(lenof_sign + 1), realVal)
        else
            print *, "WARNING: Dimension mismatch in readAPValsAsInt. Ignoring read data"
        end if

    end subroutine readAPValsAsInt

    subroutine readAPVals(apvals, ndets, initial)
        implicit none
        integer, intent(in) :: ndets
        real(dp), intent(in) :: apvals(lenof_sign + 1, ndets)
        integer, intent(in), optional :: initial

        integer :: j, k, start

        ! set all values of pops sum/iter using the read-in values from apvals
        ! this is used in popsfile read-in to get the values from the previous calculation

        def_default(start, initial, 1)

        do j = 1, ndets
            do k = 1, lenof_sign
                global_determinant_data(pos_pops_sum + k - 1, j) = apvals(k, j)
            end do
            global_determinant_data(pos_pops_iter, j) = apvals(lenof_sign + 1, j)
        end do
    end subroutine readAPVals

    subroutine writeAPVals(apvals, ndets, initial)
        implicit none
        real(dp), intent(inout) :: apvals(:, :)
        integer, intent(in) :: ndets
        integer, intent(in), optional :: initial
        integer :: j, k, start

        def_default(start, initial, 1)

        ! write the pops sum/iter per determinant in a contiguous array
        ! apvals(:,j) = (sum, iter) for determinant j (lenof_sign+1 in size)
        do j = 1, nDets
            do k = 1, lenof_sign
                apvals(k, j) = get_pops_sum(j + start - 1, k)
            end do
            apvals(lenof_sign + 1, j) = get_pops_iter(j + start - 1)
        end do
    end subroutine writeAPVals
    !------------------------------------------------------------------------------------------!
    subroutine set_av_sgn_tot_sgl(j, part, av_sgn)

        integer, intent(in) :: j, part
        real(dp), intent(in) :: av_sgn

        global_determinant_data(pos_av_sgn + part - 1, j) = av_sgn

    end subroutine

    subroutine set_av_sgn_tot_all(j, av_sgn)

        integer, intent(in) :: j
        real(dp), intent(in) :: av_sgn(len_av_sgn_tot)

        global_determinant_data(pos_av_sgn:pos_av_sgn + len_av_sgn_tot - 1, j) = &
            av_sgn

    end subroutine

    subroutine set_iter_occ_tot_sgl(j, part, iter_occ)

        ! It is unusual, but all the RDM code uses real(dp) values for the
        ! current iteration. As floats store integers exactly up to a
        ! sensible limit, this is just fine, and simplifies this code.
        !
        ! But it is weird.

        integer, intent(in) :: j, part
        real(dp), intent(in) :: iter_occ

        global_determinant_data(pos_iter_occ + part - 1, j) = iter_occ

    end subroutine

    subroutine set_iter_occ_tot_all(j, iter_occ)

        ! It is unusual, but all the RDM code uses real(dp) values for the
        ! current iteration. As floats store integers exactly up to a
        ! sensible limit, this is just fine, and simplifies this code.
        !
        ! But it is weird.

        integer, intent(in) :: j
        real(dp), intent(in) :: iter_occ(len_iter_occ_tot)

        global_determinant_data(pos_iter_occ: &
                                pos_iter_occ + len_iter_occ_tot - 1, j) = iter_occ

    end subroutine


    ! -----Routines for extracting the properties of both standard and--------
    ! -----transition RDMs together-------------------------------------------

    function get_av_sgn_tot_sgl(j, part) result(av_sgn)

        integer, intent(in) :: j, part
        real(dp) :: av_sgn

        av_sgn = global_determinant_data(pos_av_sgn + part - 1, j)

    end function

    function get_av_sgn_tot_all(j) result(av_sgn)

        integer, intent(in) :: j
        real(dp) :: av_sgn(len_av_sgn_tot)

        av_sgn = global_determinant_data(pos_av_sgn: &
                                         pos_av_sgn + len_av_sgn_tot - 1, j)

    end function

    function get_iter_occ_tot_sgl(j, part) result(iter_occ)

        integer, intent(in) :: j, part
        real(dp) :: iter_occ

        iter_occ = global_determinant_data(pos_iter_occ + part - 1, j)

    end function

    function get_iter_occ_tot_all(j) result(iter_occ)

        integer, intent(in) :: j
        real(dp) :: iter_occ(len_iter_occ_tot)

        iter_occ = global_determinant_data(pos_iter_occ: &
                                           pos_iter_occ + len_iter_occ_tot - 1, j)

    end function

    function get_spawn_rate(j) result(rate)

        integer, intent(in) :: j
        real(dp) :: rate
#ifdef DEBUG_
        character(*), parameter :: this_routine = 'get_spawn_rate'
#endif

        ASSERT(tContTimeFCIMC .and. tContTimeFull)
        rate = global_determinant_data(pos_spawn_rate, j)

    end function

    subroutine set_spawn_rate(j, rate)

        integer, intent(in) :: j
        real(dp), intent(in) :: rate
#ifdef DEBUG_
        character(*), parameter :: this_routine = 'set_spawn_rate'
#endif

        ASSERT(tContTimeFCIMC .and. tContTimeFull)
        global_determinant_data(pos_spawn_rate, j) = rate

    end subroutine

    !------------------------------------------------------------------------------------------!
    ! functions for storing information on the history of spawns onto a determinant
    !------------------------------------------------------------------------------------------!

    subroutine store_spawn(j, spawn_sgn)
        implicit none
        integer, intent(in) :: j
        real(dp), intent(in) :: spawn_sgn(lenof_sign)

        integer :: part

        do part = 1, lenof_sign
            if (spawn_sgn(part) > eps) then
                global_determinant_data(pos_pos_spawns + part - 1, j) = &
                    global_determinant_data(pos_pos_spawns + part - 1, j) + abs(spawn_sgn(part))
            else if (spawn_sgn(part) < -eps) then
                global_determinant_data(pos_neg_spawns + part - 1, j) = &
                    global_determinant_data(pos_neg_spawns + part - 1, j) + abs(spawn_sgn(part))
            end if
        end do
    end subroutine store_spawn

    !------------------------------------------------------------------------------------------!

    pure function get_pos_spawns(j) result(avSpawn)
        implicit none
        integer, intent(in) :: j
        real(dp) :: avSpawn(lenof_sign)

        avSpawn = global_determinant_data(pos_pos_spawns:(pos_pos_spawns + lenof_sign - 1), j)
    end function get_pos_spawns

    !------------------------------------------------------------------------------------------!

    pure function get_neg_spawns(j) result(avSpawn)
        implicit none
        integer, intent(in) :: j
        real(dp) :: avSpawn(lenof_sign)

        avSpawn = global_determinant_data(pos_neg_spawns:(pos_neg_spawns + lenof_sign - 1), j)
    end function get_neg_spawns

    !------------------------------------------------------------------------------------------!

    function get_max_ratio(j) result(maxSpawn)
        ! Get the maximum ratio Hij/pgen for the determinant j so far
        ! Input: j - index of the determinant
        ! Output: maxSpawn - maximum Hij/pgen of spawning attempts from Determinant j so far
        implicit none
        integer, intent(in) :: j
        real(dp) :: maxSpawn

        maxSpawn = global_determinant_data(pos_max_ratio, j)
    end function get_max_ratio

    !------------------------------------------------------------------------------------------!

    subroutine update_max_ratio(spawn, j)
        ! Update the maximum ratio Hij/pgen for the determinant j when spawning spawn walkers
        ! Input: j - index of the determinant
        !        spawn - walkers to spawn in this attempt
        implicit none
        real(dp), intent(in) :: spawn
        integer, intent(in) :: j

        if (abs(spawn) > get_max_ratio(j)) &
            call set_max_ratio(abs(spawn), j)
    end subroutine update_max_ratio

    !------------------------------------------------------------------------------------------!

    subroutine set_max_ratio(val, j)
        ! Set the maximum ratio Hij/pgen for the determinant j to val
        ! Input: j - index of the determinant
        !        val - new maximum Hij/pgen ratio
        implicit none
        real(dp), intent(in) :: val
        integer, intent(in) :: j

        global_determinant_data(pos_max_ratio, j) = val
    end subroutine set_max_ratio

    !------------------------------------------------------------------------------------------!

    subroutine write_max_ratio(ms_vals, ndets, initial)
        ! Write the values of the maximum ratios Hij/pgen for all determinants to ms_vals
        ! Input: ndets - number of determinants
        !        ms_vals - On return, contains the maximum Hij/pgen ratios for all determinants
        !        initial - optionally: the first determinant to consider
        implicit none
        integer, intent(in) :: ndets
        ! use a 2-d array for compatibility - the caller does not need to know that the first
        ! dimension is of size 1
        real(dp), intent(out) :: ms_vals(:, :)
        integer, intent(in), optional :: initial

        integer :: j, start

        def_default(start, initial, 1)

        do j = 1, ndets
            ms_vals(1, j) = global_determinant_data(pos_max_ratio, j + start - 1)
        end do

    end subroutine write_max_ratio

    !------------------------------------------------------------------------------------------!

    subroutine set_all_max_ratios(ms_vals, ndets, initial)
        ! Set the maximum ratios stored to the values in ms_vals
        ! Input: ms_vals - Ratios to be stored. Has to be of size 1 x ndets
        !        ndets - number of values to be read in
        !        initial - index of the first entry to fill (everything before will be unchanged
        implicit none
        real(dp), intent(in) :: ms_vals(:, :)
        integer, intent(in) :: ndets
        integer, intent(in), optional :: initial

        integer :: j, start

        def_default(start, initial, 1)

        do j = 1, ndets
            call set_max_ratio(ms_vals(1, j), j + start - 1)
        end do

    end subroutine set_all_max_ratios

    !------------------------------------------------------------------------------------------!

#ifdef USE_HDF_
    subroutine set_max_ratio_hdf5Int(val, j)
        use hdf5, only: hsize_t
        ! Set the maximum ratio Hij/pgen for the determinant j to val
        ! Input: j - index of the determinant
        !        val - new maximum Hij/pgen ratio, bitwise re-interpreted as hsize_t int
        implicit none
        integer(hsize_t), intent(in) :: val(:)
        integer, intent(in) :: j
        ! dummy to specify the target type
        real(dp) :: real_val
        real_val = 0.0_dp
        if (size(val)>0) &
            global_determinant_data(pos_max_ratio, j) = transfer(val(1), real_val)
    end subroutine set_max_ratio_hdf5Int

    !------------------------------------------------------------------------------------------!

    subroutine write_max_ratio_as_int(ms_vals, pos)
        use hdf5, only: hsize_t
        use bit_rep_data, only: extract_sign
        use DetBitOps, only: FindBitExcitLevel
        ! Write the values of the maximum ratios Hij/pgen for all determinants to ms_vals
        ! Input: pos - position to get the data from
        !        ms_vals - On return, contains the maximum Hij/pgen ratios for all determinants
        implicit none
        integer, intent(in) :: pos
        ! use a 1-d array for compatibility - the caller does not need to know that the
        ! dimension is of size 1
        integer(hsize_t), intent(out) :: ms_vals(:)

        ms_vals(1) = transfer(global_determinant_data(pos_max_ratio, pos), ms_vals(1))

    end subroutine write_max_ratio_as_int

#endif

    !------------------------------------------------------------------------------------------!
    !    Global storage for storing nI for each occupied determinant to save time for
    !    conversion from ilut to nI
    !------------------------------------------------------------------------------------------!

    subroutine store_decoding(j, nI)
        implicit none
        integer, intent(in) :: j, nI(nel)

        if (tStoredDets) then
            global_determinants(:, j) = nI
        end if
    end subroutine store_decoding

    function get_determinant(j) result(nI)
        implicit none
        integer, intent(in) :: j
        integer :: nI(nel)

        if (tStoredDets) then
            nI = global_determinants(:, j)
        else
            nI = 0
        end if
    end function get_determinant

end module
