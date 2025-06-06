#include "macros.h"

module kp_fciqmc

    use kp_fciqmc_init
    use kp_fciqmc_proj_est
    use kp_fciqmc_procs

    use AnnihilationMod, only: DirectAnnihilation, communicate_and_merge_spawns
    use bit_rep_data, only: NIfTot, IlutBits, test_flag, &
        flag_deterministic, flag_determ_parent
    use bit_reps, only: extract_bit_rep, set_flag
    use CalcData, only: AvMCExcits, tSemiStochastic, tTruncInitiator, StepsSft
    use CalcData, only: tDetermHFSpawning, ss_space_in, tPairedReplicas
    use CalcData, only: tPrintReplicaOverlaps
    use constants
    use DetBitOps, only: FindBitExcitLevel, return_ms
    use FciMCData, only: fcimc_excit_gen_store, FreeSlot, iEndFreeSlot
    use FciMCData, only: TotWalkers, CurrentDets, iLutRef, max_calc_ex_level
    use FciMCData, only: iter_data_fciqmc, TotParts, exFlag, iter
    use core_space_util, only: cs_replicas
    use FciMCData, only: walker_time, annihil_time
    use FciMCData, only: Stats_Comms_Time, iLutHF_True
    use fcimc_initialisation, only: CalcApproxpDoubles
    use fcimc_helper, only: SumEContrib, end_iter_stats, create_particle_with_hash_table, &
                            CalcParentFlag, walker_death, decide_num_to_spawn
    use fcimc_output, only: end_iteration_print_warn
    use fcimc_iter_utils, only: calculate_new_shift_wrapper, update_iter_data
    use fcimc_pointed_fns, only: new_child_stats_normal
    use global_det_data, only: det_diagH, det_offdiagH
    use LoggingData, only: tPopsFile
    use Parallel_neci, only: iProcIndex
    use MPI_wrapper, only: root
    use PopsFileMod, only: WriteToPopsFileParOneArr
    use procedure_pointers, only: generate_excitation, attempt_create, encode_child, extract_bit_rep_avsign
    use semi_stoch_procs, only: is_core_state, check_determ_flag, determ_projection
    use soft_exit, only: ChangeVars, tSoftExitFound
    use SystemData, only: nel, lms, nbasis, tAllSymSectors, nOccAlpha, nOccBeta
    use SystemData, only: tRef_Not_HF
    use timing_neci, only: set_timer, halt_timer
    use util_mod, only: near_zero

    better_implicit_none

contains

    subroutine perform_kp_fciqmc(kp)

        use orthogonalise, only: calc_replica_overlaps

        type(kp_fciqmc_data), intent(inout) :: kp
        integer :: iiter, idet, ireplica, ispawn, ierr, err
        integer :: iconfig, irepeat, ivec, nlowdin
        integer :: nspawn, parent_flags, unused_flags
        integer :: ex_level_to_ref, ex_level_to_hf
        integer :: TotWalkersNew, determ_ind, ic, ex(2, maxExcit), ms_parent
        integer :: nI_parent(nel), nI_child(nel), MaxIndex
        integer(n_int) :: ilut_child(0:NIfTot)
        integer(n_int), pointer :: ilut_parent(:)
        real(dp) :: prob, unused_rdm_real, parent_hdiag
        real(dp) :: child_sign(lenof_sign), parent_sign(lenof_sign)
        real(dp) :: unused_sign(lenof_sign), precond_fac
        real(dp), allocatable :: lowdin_evals(:, :)
        logical :: tChildIsDeterm, tParentIsDeterm, tParentUnoccupied
        logical :: tParity, tSingBiasChange, tWritePopsFound
        HElement_t(dp) :: HElGen, parent_hoffdiag

        ! Stores of the overlap and projected Hamiltonian matrices.
        real(dp), pointer :: overlap_matrices(:, :, :)
        real(dp), pointer :: hamil_matrices(:, :, :)
        ! Pointers to the matrices for a given repeat only.
        real(dp), pointer :: overlap_matrix(:, :)
        real(dp), pointer :: hamil_matrix(:, :)

        ! Variables to hold information output for the test suite.
        real(dp) :: s_sum, h_sum

        integer(n_int) :: int_sign(lenof_all_signs)
        real(dp) :: test_sign(lenof_all_signs)
        type(ll_node), pointer :: temp_node

        ! Unused factor
        precond_fac = 1.0_dp

        call init_kp_fciqmc(kp)
        if (.not. tAllSymSectors) ms_parent = lms

        allocate(overlap_matrices(kp%nvecs, kp%nvecs, kp%nrepeats), stat=ierr)
        allocate(hamil_matrices(kp%nvecs, kp%nvecs, kp%nrepeats), stat=ierr)
        allocate(lowdin_evals(kp%nvecs, kp%nvecs), stat=ierr)
        overlap_matrices = 0.0_dp
        hamil_matrices = 0.0_dp

        outer_loop: do iconfig = 1, kp%nconfigs

            do irepeat = 1, kp%nrepeats

                ! Point to the regions of memory where the projected Hamiltonian
                ! and overlap matrices for this repeat will be accumulated and stored.
                overlap_matrix => overlap_matrices(:, :, irepeat)
                hamil_matrix => hamil_matrices(:, :, irepeat)
                overlap_matrix(:, :) = 0.0_dp
                hamil_matrix(:, :) = 0.0_dp

                call init_kp_fciqmc_repeat(iconfig, irepeat, kp%nrepeats, kp%nvecs, iter_data_fciqmc)

                do ivec = 1, kp%nvecs

                    ! Copy the current state of CurrentDets to krylov_vecs.
                    call store_krylov_vec(ivec)

                    ! Calculate the overlap of the perturbed ground state vector
                    ! with the new Krylov vector, if requested.
                    if (tOverlapPert) call calc_perturbation_overlap(ivec)

                    do iiter = 1, kp%niters(ivec)

                        call set_timer(walker_time)

                        iter = iter + 1
                        call init_kp_fciqmc_iter(iter_data_fciqmc, determ_ind)

                        !if (iter < 10) then
                        !    write(stdout,*) "CurrentDets before:"
                        !    do idet = 1, int(TotWalkers)
                        !        call extract_bit_rep(CurrentDets(:, idet), nI_parent, parent_sign, unused_flags, &
                        !                              fcimc_excit_gen_store)
                        !        if (tUseFlags) then
                        !            write(stdout,'(i7, i12, 4x, f18.7, 4x, f18.7, 4x, l1)') idet, CurrentDets(0,idet), parent_sign, &
                        !                test_flag(CurrentDets(:,idet), flag_deterministic)
                        !        else
                        !            write(stdout,'(i7, i12, 4x, f18.7, 4x, f18.7)') idet, CurrentDets(0,idet), parent_sign
                        !        end if
                        !    end do

                        !    write(stdout,"(A)") "Hash Table: "
                        !    do idet = 1, nWalkerHashes
                        !        temp_node => HashIndex(idet)
                        !        if (temp_node%ind /= 0) then
                        !            write(stdout,'(i9)',advance='no') idet
                        !            do while (associated(temp_node))
                        !                write(stdout,'(i9)',advance='no') temp_node%ind
                        !                temp_node => temp_node%next
                        !            end do
                        !            write(stdout,'()',advance='yes')
                        !        end if
                        !    end do
                        !end if

                        do idet = 1, int(TotWalkers)

                            ! The 'parent' determinant from which spawning is to be attempted.
                            ilut_parent => CurrentDets(:, idet)
                            parent_flags = 0_n_int

                            ! Indicate that the scratch storage used for excitation generation from the
                            ! same walker has not been filled (it is filled when we excite from the first
                            ! particle on a determinant).
                            fcimc_excit_gen_store%tFilled = .false.

                            call extract_bit_rep(ilut_parent, nI_parent, parent_sign, unused_flags, &
                                                 idet, fcimc_excit_gen_store)

                            ex_level_to_ref = FindBitExcitLevel(iLutRef(:, 1), ilut_parent, &
                                                                max_calc_ex_level)
                            if (tRef_Not_HF) then
                                ex_level_to_hf = FindBitExcitLevel(iLutHF_true, ilut_parent, max_calc_ex_level)
                            else
                                ex_level_to_hf = ex_level_to_ref
                            end if

                            tParentIsDeterm = check_determ_flag(ilut_parent, core_run)
                            tParentUnoccupied = IsUnoccDet(parent_sign)

                            ! If this determinant is in the deterministic space then store the relevant
                            ! data in arrays for later use.
                            if (tParentIsDeterm) then
                                ! Store the index of this state, for use in annihilation later.
                                associate(rep => cs_replicas(core_run))
                                    rep%indices_of_determ_states(determ_ind) = idet
                                    ! Add the amplitude to the deterministic vector.
                                    rep%partial_determ_vecs(:, determ_ind) = parent_sign
                                end associate
                                determ_ind = determ_ind + 1

                                ! The deterministic states are always kept in CurrentDets, even when
                                ! the amplitude is zero. Hence we must check if the amplitude is zero
                                ! and, if so, skip the state.
                                if (tParentUnoccupied) cycle
                            end if

                            ! If this slot is unoccupied (and also not a core determinant) then add it to
                            ! the list of free slots and cycle.
                            if (tParentUnoccupied) then
                                iEndFreeSlot = iEndFreeSlot + 1
                                FreeSlot(iEndFreeSlot) = idet
                                cycle
                            end if

                            ! The current diagonal matrix element is stored persistently.
                            parent_hdiag = det_diagH(idet)
                            parent_hoffdiag = det_offdiagH(idet)

                            if (tTruncInitiator) call CalcParentFlag(idet, parent_flags)

                            call SumEContrib(nI_parent, ex_level_to_ref, parent_sign, ilut_parent, &
                                             parent_hdiag, parent_hoffdiag, 1.0_dp, tPairedReplicas, idet)

                            ! If we're on the Hartree-Fock, and all singles and
                            ! doubles are in the core space, then there will be
                            ! no stochastic spawning from this determinant, so
                            ! we can the rest of this loop.
                            if (ss_space_in%tDoubles .and. ex_level_to_hf == 0 .and. tDetermHFSpawning) cycle

                            if (tAllSymSectors) then
                                ms_parent = return_ms(ilut_parent)
                                nOccAlpha = (nel + ms_parent) / 2
                                nOccBeta = (nel - ms_parent) / 2
                            end if

                            ! If this condition is not met (if all electrons have spin up or all have spin down)
                            ! then there will be no determinants to spawn to, so don't attempt spawning.
                            if (abs(ms_parent) /= nbasis / 2) then

                                do ireplica = 1, lenof_sign

                                    call decide_num_to_spawn(parent_sign(ireplica), AvMCExcits, nspawn)

                                    do ispawn = 1, nspawn

                                        ! Zero the bit representation, to ensure no extraneous data gets through.
                                        ilut_child = 0_n_int

                                        call generate_excitation(nI_parent, ilut_parent, nI_child, &
                                                                 ilut_child, exFlag, ic, ex, tParity, prob, &
                                                                 HElGen, fcimc_excit_gen_store)

                                        ! If a valid excitation.
                                        if (.not. IsNullDet(nI_child)) then

                                            call encode_child(ilut_parent, ilut_child, ic, ex)
                                            ilut_child(IlutBits%ind_flag) = 0_n_int

                                            if (tSemiStochastic) then
                                                tChildIsDeterm = is_core_state(ilut_child, nI_child)

                                                ! Is the parent state in the core space?
                                                if (tParentIsDeterm) then
                                                    ! If spawning is both from and to the core space, cancel it.
                                                    if (tChildIsDeterm) cycle
                                                    call set_flag(ilut_child, flag_determ_parent)
                                                else
                                                    if (tChildIsDeterm) call set_flag(ilut_child, flag_deterministic(core_run))
                                                end if
                                            end if

                                            child_sign = attempt_create(nI_parent, ilut_parent, parent_sign, &
                                                                        nI_child, ilut_child, prob, HElGen, ic, ex, tParity, &
                                                                        ex_level_to_ref, ireplica, unused_sign, &
                                                                        AvMCExcits, unused_rdm_real, precond_fac)

                                        else
                                            child_sign = 0.0_dp
                                        end if

                                        ! If any (valid) children have been spawned.
                                        if (.not. (all(near_zero(child_sign) .or. ic == 0 .or. ic > 2))) then

                                            call new_child_stats_normal(iter_data_fciqmc, ilut_parent, &
                                                                 nI_child, ilut_child, ic, ex_level_to_ref, &
                                                                 child_sign, parent_flags, ireplica)

                                            call create_particle_with_hash_table(nI_child, ilut_child, child_sign, &
                                                                                 ireplica, ilut_parent, iter_data_fciqmc, ierr)

                                        end if ! If a child was spawned.

                                    end do ! Over mulitple particles on same determinant.

                                end do ! Over the replicas on the same determinant.

                            end if ! If connected determinants exist to spawn to.

                            ! If this is a core-space determinant then the death step is done in
                            ! determ_projection.
                            if (.not. tParentIsDeterm) then
                                call walker_death(iter_data_fciqmc, nI_parent, ilut_parent, parent_hdiag, &
                                                  parent_sign, idet, ex_level_to_ref)
                            end if

                        end do ! Over all determinants.

                        if (tSemiStochastic) call determ_projection()

                        TotWalkersNew = int(TotWalkers)
                        call end_iter_stats(TotWalkersNew)
                        call end_iteration_print_warn(TotWalkersNew)

                        call halt_timer(walker_time)

                        call set_timer(annihil_time)

                        call communicate_and_merge_spawns(MaxIndex, iter_data_fciqmc, .false.)

                        call DirectAnnihilation(TotWalkersNew, MaxIndex, iter_data_fciqmc, ierr)

                        TotWalkers = int(TotWalkersNew, int64)

                        call halt_timer(annihil_time)

                        if (tPrintReplicaOverlaps) call calc_replica_overlaps()

                        call update_iter_data(iter_data_fciqmc)

                        if (mod(iter, StepsSft) == 0) then
                            call set_timer(Stats_Comms_Time)
                            call calculate_new_shift_wrapper(iter_data_fciqmc, TotParts, tPairedReplicas)
                            call halt_timer(Stats_Comms_Time)

                            call ChangeVars(tSingBiasChange, tWritePopsFound)
                            if (tWritePopsFound) call WriteToPopsfileParOneArr(CurrentDets, TotWalkers)
                            if (tSingBiasChange) call CalcApproxpDoubles()
                            if (tSoftExitFound) exit outer_loop
                        end if

                    end do ! Over all iterations between Krylov vectors.

                end do ! Over all Krylov vectors.

                call calc_overlap_matrix(kp%nvecs, krylov_vecs, TotWalkersKP, overlap_matrix)

                if (tExactHamil) then
                    call calc_hamil_exact(kp%nvecs, krylov_vecs, TotWalkersKP, hamil_matrix, krylov_helems)
                else
                    if (tSemiStochastic) then
                        call calc_projected_hamil(kp%nvecs, krylov_vecs, krylov_vecs_ht, TotWalkersKP, hamil_matrix, &
                                                  partial_determ_vecs_kp, full_determ_vecs_kp, krylov_helems)
                    else
                        call calc_projected_hamil(kp%nvecs, krylov_vecs, krylov_vecs_ht, TotWalkersKP, hamil_matrix, &
                                                  h_diag=krylov_helems)
                    end if
                end if

                ! Sum the overlap and projected Hamiltonian matrices from the various processors.
                call communicate_kp_matrices(overlap_matrix, hamil_matrix)

                if (iProcIndex == root) call output_kp_matrices_wrapper(iconfig, overlap_matrices, hamil_matrices)

            end do ! Over all repeats for a fixed initial walker configuration.

            if (tOverlapPert) call average_and_comm_pert_overlaps(kp%nrepeats)

            if (iProcIndex == root) then
                call average_kp_matrices_wrapper(iconfig, kp%nrepeats, overlap_matrices, hamil_matrices, &
                                                 kp_overlap_mean, kp_hamil_mean, kp_overlap_se, kp_hamil_se)
                call find_and_output_lowdin_eigv(iconfig, kp%nvecs, kp_overlap_mean, kp_hamil_mean, nlowdin, lowdin_evals, .true.)

                ! Calculate data for the testsuite.
                s_sum = sum(kp_overlap_mean)
                h_sum = sum(kp_hamil_mean)
            end if

        end do outer_loop ! Over all initial walker configurations.

        deallocate(overlap_matrices)
        deallocate(hamil_matrices)
        deallocate(lowdin_evals)

        if (tPopsFile) call WriteToPopsfileParOneArr(CurrentDets, TotWalkers)

        if (iProcIndex == root) call write_kpfciqmc_testsuite_data(s_sum, h_sum)

    end subroutine perform_kp_fciqmc

    subroutine perform_subspace_fciqmc(kp)

        use fcimc_helper, only: create_particle_with_hash_table
        use FciMCData, only: HashIndex, nWalkerHashes
        use orthogonalise, only: orthogonalise_replicas, orthogonalise_replica_pairs
        use orthogonalise, only: calc_replica_overlaps

        type(kp_fciqmc_data), intent(inout) :: kp

        integer :: iiter, idet, ireplica, ispawn, ierr, err
        integer :: iconfig, irepeat, ireport, nlowdin
        integer :: nspawn, parent_flags, unused_flags
        integer :: ex_level_to_ref, ex_level_to_hf
        integer :: TotWalkersNew, determ_ind, ic, ex(2, maxExcit), MaxIndex
        integer :: nI_parent(nel), nI_child(nel), unused_vecslot
        integer(n_int) :: ilut_child(0:NIfTot)
        integer(n_int), pointer :: ilut_parent(:)
        real(dp) :: prob, unused_rdm_real, parent_hdiag
        real(dp) :: child_sign(lenof_sign), parent_sign(lenof_sign)
        real(dp) :: unused_sign(lenof_sign), precond_fac
        real(dp), allocatable :: lowdin_evals(:, :), lowdin_spin(:, :)
        logical :: tChildIsDeterm, tParentIsDeterm, tParentUnoccupied
        logical :: tParity, tSingBiasChange, tWritePopsFound
        HElement_t(dp) :: HElGen, parent_hoffdiag

        ! Stores of the overlap, projected Hamiltonian and spin matrices.
        real(dp), pointer :: overlap_matrices(:, :, :, :)
        real(dp), pointer :: hamil_matrices(:, :, :, :)
        real(dp), pointer :: spin_matrices(:, :, :, :)
        ! Pointers to the matrices for a given report and repeat only.
        real(dp), pointer :: overlap_matrix(:, :)
        real(dp), pointer :: hamil_matrix(:, :)
        real(dp), pointer :: spin_matrix(:, :)

        type(ll_node), pointer :: temp_node

        ! Variables to hold information output for the test suite.
        real(dp) :: s_sum, h_sum

        ! Unused factor
        precond_fac = 1.0_dp

        call init_kp_fciqmc(kp)

        allocate(overlap_matrices(kp%nvecs, kp%nvecs, kp%nrepeats, kp%nreports), stat=ierr)
        allocate(hamil_matrices(kp%nvecs, kp%nvecs, kp%nrepeats, kp%nreports), stat=ierr)
        allocate(lowdin_evals(kp%nvecs, kp%nvecs), stat=ierr)
        overlap_matrices = 0.0_dp
        hamil_matrices = 0.0_dp
        lowdin_evals = 0.0_dp

        if (tCalcSpin) then
            allocate(spin_matrices(kp%nvecs, kp%nvecs, kp%nrepeats, kp%nreports), stat=ierr)
            allocate(lowdin_spin(kp%nvecs, kp%nvecs), stat=ierr)
            spin_matrices = 0.0_dp
            lowdin_spin = 0.0_dp
        end if

        outer_loop: do irepeat = 1, kp%nrepeats

            call init_kp_fciqmc_repeat(iconfig, irepeat, kp%nrepeats, kp%nvecs, iter_data_fciqmc)
            if (iProcIndex == root) call write_ex_state_header(kp%nvecs, irepeat)

            do ireport = 1, kp%nreports

                ! Point to the regions of memory where the projected Hamiltonian
                ! and overlap matrices for this repeat will be accumulated and stored.
                overlap_matrix => overlap_matrices(:, :, irepeat, ireport)
                hamil_matrix => hamil_matrices(:, :, irepeat, ireport)
                overlap_matrix(:, :) = 0.0_dp
                hamil_matrix(:, :) = 0.0_dp
                if (tCalcSpin) then
                    spin_matrix => spin_matrices(:, :, irepeat, ireport)
                    spin_matrix(:, :) = 0.0_dp
                end if

                call calc_overlap_matrix(kp%nvecs, CurrentDets, int(TotWalkers), overlap_matrix)

                if (tExactHamil) then
                    call calc_hamil_exact(kp%nvecs, CurrentDets, int(TotWalkers), hamil_matrix)
                else
                    if (tSemiStochastic) then
                        associate(rep => cs_replicas(core_run))
                            call calc_projected_hamil(kp%nvecs, CurrentDets, HashIndex, int(TotWalkers), &
                                                      hamil_matrix, rep%partial_determ_vecs, rep%full_determ_vecs)
                        end associate
                    else
                        call calc_projected_hamil(kp%nvecs, CurrentDets, HashIndex, int(TotWalkers), &
                                                  hamil_matrix)
                    end if
                end if

                !write(stdout,*) "CurrentDets before:"
                !do idet = 1, int(TotWalkers)
                !    call extract_bit_rep(CurrentDets(:, idet), nI_parent, parent_sign, unused_flags, &
                !                          fcimc_excit_gen_store)
                !    if (tUseFlags) then
                !        write(stdout,'(i7, i12, 4x, 3(f18.7, 4x), l1)') idet, CurrentDets(0,idet), parent_sign, &
                !            test_flag(CurrentDets(:,idet), flag_deterministic)
                !    else
                !        write(stdout,'(i7, i12, 3(4x, f18.7))') idet, CurrentDets(0,idet), parent_sign
                !    end if
                !end do

                !write(stdout,"(A)") "Hash Table: "
                !do idet = 1, nWalkerHashes
                !    temp_node => HashIndex(idet)
                !    if (temp_node%ind /= 0) then
                !        write(stdout,'(i9)',advance='no') idet
                !        do while (associated(temp_node))
                !            write(stdout,'(i9)',advance='no') temp_node%ind
                !            temp_node => temp_node%next
                !        end do
                !        write(stdout,'()',advance='yes')
                !    end if
                !end do

                ! Sum the overlap and projected Hamiltonian matrices from the various processors.
                if (tCalcSpin) then
                    ! Calculate the spin squared projected into the subspace.
                    call calc_projected_spin(kp%nvecs, CurrentDets, HashIndex, int(TotWalkers), spin_matrix)
                    call communicate_kp_matrices(overlap_matrix, hamil_matrix, spin_matrix)
                else
                    call communicate_kp_matrices(overlap_matrix, hamil_matrix)
                end if

                if (iProcIndex == root) then
                    call output_kp_matrices_wrapper(iter, overlap_matrices(:, :, 1:irepeat, ireport), &
                                                    hamil_matrices(:, :, 1:irepeat, ireport))
                    if (tCalcSpin) then
                        call find_and_output_lowdin_eigv(iter, kp%nvecs, overlap_matrix, hamil_matrix, nlowdin, &
                                                         lowdin_evals, .false., spin_matrix, lowdin_spin)
                        call write_ex_state_data(iter, nlowdin, lowdin_evals, hamil_matrix, overlap_matrix, &
                                                 spin_matrix, lowdin_spin)
                    else
                        call find_and_output_lowdin_eigv(iter, kp%nvecs, overlap_matrix, hamil_matrix, nlowdin, &
                                                         lowdin_evals, .false.)
                        call write_ex_state_data(iter, nlowdin, lowdin_evals, hamil_matrix, overlap_matrix)
                    end if
                end if

                do iiter = 1, kp%niters(ireport)

                    call set_timer(walker_time)

                    iter = iter + 1
                    call init_kp_fciqmc_iter(iter_data_fciqmc, determ_ind)

                    do idet = 1, int(TotWalkers)

                        ! The 'parent' determinant from which spawning is to be attempted.
                        ilut_parent => CurrentDets(:, idet)
                        parent_flags = 0_n_int

                        ! Indicate that the scratch storage used for excitation generation from the
                        ! same walker has not been filled (it is filled when we excite from the first
                        ! particle on a determinant).
                        fcimc_excit_gen_store%tFilled = .false.

                        call extract_bit_rep(ilut_parent, nI_parent, parent_sign, unused_flags, &
                                             idet, fcimc_excit_gen_store)

                        ex_level_to_ref = FindBitExcitLevel(iLutRef(:, 1), ilut_parent, &
                                                            max_calc_ex_level)
                        if (tRef_Not_HF) then
                            ex_level_to_hf = FindBitExcitLevel(iLutHF_true, ilut_parent, max_calc_ex_level)
                        else
                            ex_level_to_hf = ex_level_to_ref
                        end if

                        tParentIsDeterm = check_determ_flag(ilut_parent, core_run)
                        tParentUnoccupied = IsUnoccDet(parent_sign)

                        ! If this determinant is in the deterministic space then store the relevant
                        ! data in arrays for later use.
                        if (tParentIsDeterm) then
                            ! Store the index of this state, for use in annihilation later.
                            associate(rep => cs_replicas(core_run))
                                rep%indices_of_determ_states(determ_ind) = idet
                                ! Add the amplitude to the deterministic vector.
                                rep%partial_determ_vecs(:, determ_ind) = parent_sign
                            end associate
                            determ_ind = determ_ind + 1

                            ! The deterministic states are always kept in CurrentDets, even when
                            ! the amplitude is zero. Hence we must check if the amplitude is zero
                            ! and, if so, skip the state.
                            if (tParentUnoccupied) cycle
                        end if

                        ! If this slot is unoccupied (and also not a core determinant) then add it to
                        ! the list of free slots and cycle.
                        if (tParentUnoccupied) then
                            iEndFreeSlot = iEndFreeSlot + 1
                            FreeSlot(iEndFreeSlot) = idet
                            cycle
                        end if

                        ! The current diagonal matrix element is stored persistently.
                        parent_hdiag = det_diagH(idet)
                        parent_hoffdiag = det_offdiagH(idet)

                        if (tTruncInitiator) call CalcParentFlag(idet, parent_flags)

                        call SumEContrib(nI_parent, ex_level_to_ref, parent_sign, ilut_parent, &
                                         parent_hdiag, parent_hoffdiag, 1.0_dp, tPairedReplicas, idet)

                        ! If we're on the Hartree-Fock, and all singles and
                        ! doubles are in the core space, then there will be no
                        ! stochastic spawning from this determinant, so we can
                        ! the rest of this loop.
                        if (ss_space_in%tDoubles .and. ex_level_to_hf == 0 .and. tDetermHFSpawning) cycle

                        do ireplica = 1, lenof_sign

                            call decide_num_to_spawn(parent_sign(ireplica), AvMCExcits, nspawn)

                            do ispawn = 1, nspawn

                                ! Zero the bit representation, to ensure no extraneous data gets through.
                                ilut_child = 0_n_int

                                call generate_excitation(nI_parent, ilut_parent, nI_child, &
                                                         ilut_child, exFlag, ic, ex, tParity, prob, &
                                                         HElGen, fcimc_excit_gen_store)

                                ! If a valid excitation.
                                if (.not. IsNullDet(nI_child)) then

                                    call encode_child(ilut_parent, ilut_child, ic, ex)
                                    ilut_child(IlutBits%ind_flag) = 0_n_int

                                    if (tSemiStochastic) then
                                        tChildIsDeterm = is_core_state(ilut_child, nI_child)

                                        ! Is the parent state in the core space?
                                        if (tParentIsDeterm) then
                                            ! If spawning is both from and to the core space, cancel it.
                                            if (tChildIsDeterm) cycle
                                            call set_flag(ilut_child, flag_determ_parent)
                                        else
                                            if (tChildIsDeterm) call set_flag(ilut_child, flag_deterministic(core_run))
                                        end if
                                    end if

                                    child_sign = attempt_create(nI_parent, ilut_parent, parent_sign, &
                                                                nI_child, ilut_child, prob, HElGen, ic, ex, tParity, &
                                                                ex_level_to_ref, ireplica, unused_sign, &
                                                                AvMCExcits, unused_rdm_real, precond_fac)
                                else
                                    child_sign = 0.0_dp
                                end if

                                ! If any (valid) children have been spawned.
                                if (.not. (all(near_zero(child_sign) .or. ic == 0 .or. ic > 2))) then

                                    call new_child_stats_normal(iter_data_fciqmc, ilut_parent, &
                                                         nI_child, ilut_child, ic, ex_level_to_ref, &
                                                         child_sign, parent_flags, ireplica)

                                    call create_particle_with_hash_table(nI_child, ilut_child, child_sign, &
                                                                         ireplica, ilut_parent, iter_data_fciqmc, ierr)

                                end if ! If a child was spawned.

                            end do ! Over mulitple particles on same determinant.

                        end do ! Over the replicas on the same determinant.

                        ! If this is a core-space determinant then the death step is done in
                        ! determ_projection.
                        if (.not. tParentIsDeterm) then
                            call walker_death(iter_data_fciqmc, nI_parent, ilut_parent, parent_hdiag, &
                                              parent_sign, idet, ex_level_to_ref)
                        end if

                    end do ! Over all determinants.

                    if (tSemiStochastic) call determ_projection()

                    TotWalkersNew = int(TotWalkers)
                    call end_iter_stats(TotWalkersNew)
                    call end_iteration_print_warn(TotWalkersNew)

                    call halt_timer(walker_time)

                    call set_timer(annihil_time)

                    call communicate_and_merge_spawns(MaxIndex, iter_data_fciqmc, .false.)

                    call DirectAnnihilation(TotWalkersNew, MaxIndex, iter_data_fciqmc, ierr)

                    TotWalkers = int(TotWalkersNew, int64)

                    call halt_timer(annihil_time)

                    if (tOrthogKPReplicas .and. iter > orthog_kp_iter) then
                        call orthogonalise_replicas(iter_data_fciqmc)
                    else if (tPrintReplicaOverlaps) then
                        call calc_replica_overlaps()
                    end if

                    call update_iter_data(iter_data_fciqmc)

                    if (mod(iter, StepsSft) == 0) then
                        call set_timer(Stats_Comms_Time)
                        call calculate_new_shift_wrapper(iter_data_fciqmc, TotParts, tPairedReplicas)
                        call halt_timer(Stats_Comms_Time)

                        call ChangeVars(tSingBiasChange, tWritePopsFound)
                        if (tWritePopsFound) call WriteToPopsfileParOneArr(CurrentDets, TotWalkers)
                        if (tSingBiasChange) call CalcApproxpDoubles()
                        if (tSoftExitFound) exit outer_loop
                    end if

                end do ! Over all iterations per report cycle.

            end do ! Over all report cycles.

        end do outer_loop ! Over all repeats of the whole calculation.

        ! Output the Lowdin estimates for the final *averaged* matrices.
        if (iProcIndex == root) then
            iter = 0
            do ireport = 1, kp%nreports
                call average_kp_matrices_wrapper(iter, kp%nrepeats, overlap_matrices(:, :, 1:kp%nrepeats, ireport), &
                                                 hamil_matrices(:, :, 1:kp%nrepeats, ireport), kp_overlap_mean, &
                                                 kp_hamil_mean, kp_overlap_se, kp_hamil_se)
                if (tCalcSpin) then
                    call find_and_output_lowdin_eigv(iter, kp%nvecs, kp_overlap_mean, kp_hamil_mean, nlowdin, &
                                                     lowdin_evals, .true., spin_matrix, lowdin_spin)
                else
                    call find_and_output_lowdin_eigv(iter, kp%nvecs, kp_overlap_mean, kp_hamil_mean, nlowdin, &
                                                     lowdin_evals, .true.)
                end if
                ! Update the iteration label.
                iter = iter + kp%niters(ireport)
            end do
        end if

        ! Calculate data for the testsuite.
        s_sum = sum(kp_overlap_mean)
        h_sum = sum(kp_hamil_mean)

        deallocate(overlap_matrices)
        deallocate(hamil_matrices)
        deallocate(lowdin_evals)

        if (tPopsFile) call WriteToPopsfileParOneArr(CurrentDets, TotWalkers)

        call write_kpfciqmc_testsuite_data(s_sum, h_sum)

    end subroutine perform_subspace_fciqmc

end module kp_fciqmc
