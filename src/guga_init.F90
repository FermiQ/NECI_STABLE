#include "macros.h"
! guga module containing all necessary functionality needed to initialize
! a guga simulation
module guga_init
    ! module use statements
    use SystemData, only: tSPN, tHPHF, lNoSymmetry, STOT, nEl, t_fci_pchb_excitgen, &
                          nBasis, tGUGA, tNoBrillouin, tExactSizeSpace, tUHF, tUEGNewGenerator, &
                          tPickVirtUniform, tGenHelWeighted, tGen_4ind_2, tGen_4ind_weighted, &
                          tGen_4ind_reverse, tGen_sym_guga_ueg, tGen_sym_guga_mol, &
                          tGen_nosym_guga, nSpatOrbs, t_consider_diff_bias, &
                          treal, tHUB, t_guga_noreorder, tgen_guga_crude, &
                          t_new_real_space_hubbard, t_heisenberg_model, &
                          t_tJ_model, t_guga_pchb, t_guga_pchb_weighted_singles

    use CalcData, only: tUseRealCoeffs, tRealCoeffByExcitLevel, RealCoeffExcitThresh, &
                        tSpinProject, &
                        tReplicaEstimates, tPreCond, ss_space_in, trial_space_in, &
                        t_fast_pops_core, t_core_inits

    use hist_data, only: tHistSpawn

    use LoggingData, only: tCalcFCIMCPsi, tPrintOrbOcc, tRDMonfly, tExplicitAllRDM

    use bit_rep_data, only: tUseFlags, nifd

    use guga_data, only: init_guga_data_procPtrs, orbitalIndex, &
                         n_excit_info_bits

    use guga_procedure_pointers, only: pickOrbitals_single, pickOrbitals_double, &
                        calc_orbital_pgen_contr, &
                        pick_first_orbital, orb_pgen_contrib_type_2, orb_pgen_contrib_type_3, &
                        calc_off_diag_guga_ref, calc_orbital_pgen_contrib_start, &
                        calc_orbital_pgen_contrib_end

    use guga_excitations, only: pickOrbs_sym_uniform_ueg_single, pickOrbs_sym_uniform_ueg_double, &
                        pickOrbs_sym_uniform_mol_single, pickOrbs_sym_uniform_mol_double, &
                        calc_orbital_pgen_contr_ueg, calc_orbital_pgen_contr_mol, &
                        calc_mixed_x2x_ueg, &
                        calc_off_diag_guga_ref_direct, &
                        pickOrbs_real_hubbard_single, pickOrbs_real_hubbard_double, &
                        calc_orbital_pgen_contrib_start_def, calc_orbital_pgen_contrib_end_def

    use FciMCData, only: pExcit2, pExcit4, pExcit2_same, pExcit3_same

    use constants, only: dp, int_rdm, n_int, stdout, inum_runs

    use MPI_wrapper, only: iProcIndex

    use tj_model, only: pick_orbitals_guga_heisenberg, calc_orbital_pgen_contr_heisenberg, &
                        init_get_helement_tj_guga, init_get_helement_heisenberg_guga, &
                        init_guga_tJ_model, init_guga_heisenberg_model, &
                        pick_orbitals_guga_tJ

    use back_spawn, only: setup_virtual_mask

    use util_mod, only: operator(.div.), stop_all

    use guga_bitRepOps, only: init_guga_bitrep, new_CSF_Info_t, current_csf_i, csf_ref

    use guga_pchb_excitgen, only: pick_orbitals_pure_uniform_singles, &
                                  pick_orbitals_double_pchb, &
                                  calc_orbital_pgen_contr_pchb, &
                                  calc_orbital_pgen_contr_start_pchb, &
                                  calc_orbital_pgen_contr_end_pchb

    better_implicit_none

    private

    public :: checkInputGUGA, init_guga

contains

    subroutine init_guga_orbital_pickers()
        character(*), parameter :: this_routine = "init_guga_orbital_pickers"
        ! this routine, depending on the input set the orbital pickers
        ! to differentiate between the different excitation generators


        if (tGen_sym_guga_ueg) then
            calc_orbital_pgen_contrib_start => calc_orbital_pgen_contrib_start_def
            calc_orbital_pgen_contrib_end => calc_orbital_pgen_contrib_end_def
            if (.not. (treal .or. t_new_real_space_hubbard)) then
                pickOrbitals_double => pickOrbs_sym_uniform_ueg_double
                calc_orbital_pgen_contr => calc_orbital_pgen_contr_ueg
            else
                pickOrbitals_single => pickOrbs_real_hubbard_single
            end if

        else if (tGen_sym_guga_mol) then

            pickOrbitals_single => pickOrbs_sym_uniform_mol_single    ! PickOrbitals_t
            pickOrbitals_double => pickOrbs_sym_uniform_mol_double    ! PickOrbitals_t                          in beiden Fällen
            calc_orbital_pgen_contr => calc_orbital_pgen_contr_mol    ! calc_orbital_pgen_contr_t               nur für doubles
            calc_orbital_pgen_contrib_start => calc_orbital_pgen_contrib_start_def  ! CalcOrbitalPgenContr_t    nur für doubles
            calc_orbital_pgen_contrib_end => calc_orbital_pgen_contrib_end_def  ! CalcOrbitalPgenContr_t        nur für doubles

        else if (t_guga_pchb) then

            if (t_guga_pchb_weighted_singles) then
                pickOrbitals_single => pickOrbs_sym_uniform_mol_single
            else
                pickOrbitals_single => pick_orbitals_pure_uniform_singles
            end if

            pickOrbitals_double => pick_orbitals_double_pchb
            ! rest has to be determined what needs a change..
            calc_orbital_pgen_contr => calc_orbital_pgen_contr_pchb
            calc_orbital_pgen_contrib_start => calc_orbital_pgen_contr_start_pchb
            calc_orbital_pgen_contrib_end => calc_orbital_pgen_contr_end_pchb

        else if (t_heisenberg_model) then
            pickOrbitals_double => pick_orbitals_guga_heisenberg
            calc_orbital_pgen_contr => calc_orbital_pgen_contr_heisenberg

            ! No single excitations + pure exchange doubles

        else if (t_tJ_model) then
            pickOrbitals_single => pick_orbitals_guga_tJ
            pickOrbitals_double => pick_orbitals_guga_heisenberg
            calc_orbital_pgen_contr => calc_orbital_pgen_contr_heisenberg

            ! singles + pure exchange doubles

        else ! standardly also use nosymmetry version
            root_print "please specify guga excitation generator explicitly!"
            root_print "options are: "
            root_print "'mol-guga-weighted' ... standard for molecular systems"
            root_print "'ueg-guga' ... standard for UEG and Hubbard/Heisenberg/tJ models"
            root_print "'guga-pchb' ... GUGA version of PCHB excit. gen. for molecular systems"
            call Stop_All(this_routine, &
                "please specify guga excitation generator explicitly!")

        end if

    end subroutine init_guga_orbital_pickers

    ! in Fortran no executable code is allowed to be in the module header part
    ! so a initialization subroutine is needed, which has to be called in the
    ! other modules using the guga_data module
    subroutine init_guga()
        integer :: i
        character(*), parameter :: this_routine = "init_guga"
        ! main initialization routine

        ! this routine is called in SysInit() of System_neci.F90
        write(stdout, *) ' ************ Using the GUGA-CSF implementation **********'
        write(stdout, *) ' Restricting the total spin of the system, tGUGA : ', tGUGA
        write(stdout, '(A,I5)') '  Restricting total spin S in units of h/2 to ', STOT
        write(stdout, *) ' So eg. S = 1 corresponds to one unpaired electron '
        write(stdout, *) ' not quite sure yet how to deal with extensively used m_s quantum number..'
        write(stdout, *) ' NOTE: for now, although SPIN-RESTRICT is set off, internally m_s(LMS) '
        write(stdout, *) ' is set to STOT, to make use of reference determinant creations already implemented'
        write(stdout, *) ' Since NECI always seems to take the beta orbitals first for open shell or '
        write(stdout, *) ' spin restricted systems, associate those to positively coupled +h/2 orbitals '
        write(stdout, *) ' to always ensure a S >= 0 value!'
        write(stdout, *) ' *********************************************************'

        if (tGen_nosym_guga) then
            call Stop_All(this_routine, "'nosym-guga' option deprecated!")
        end if

        if (t_fci_pchb_excitgen) then
            call stop_all(this_routine, &
                "please specify 'guga-pchb' as excitation generator to work with GUGA!")
        end if

        ! initialize the procedure pointer arrays, needed in the matrix
        ! element calculation
        call init_guga_data_procPtrs()

        ! initialize and point the excitation generator functions to the
        ! correct ones
        call init_guga_orbital_pickers()

        ! also have to set tRealCoeffs true to use it in excitation creation
        ! dont actually need realCoeffs anymore since i changed the accessing
        ! of the ilut lists used for excitation creation
        ! but probably have to set a few other things so it works with
        ! reals
        tUseRealCoeffs = .true.

        tUseFlags = .true.

        ! define global variable of spatial orbitals
        ! do that in a more general setup routine! where nBasis is defined
        ! eg
        ! i have to all this routine again from a point after freezing
        ! where the new number of NBasis is determined already..
        nSpatOrbs = nBasis .div. 2

        ! but also have to set up the global orbitalIndex list
        orbitalIndex = [(i, i = 1, nSpatOrbs)]


        ! Store GUGA specific information about the current CSF.
        ! In principle this is redundant and could be computed from nI or ilut,
        !   but we precompute it for performance reasons.
        call new_CSF_Info_t(nSpatOrbs, current_csf_i)
        if (allocated(csf_ref)) deallocate(csf_ref)
        allocate(csf_ref(inum_runs))
        call new_CSF_Info_t(nSpatOrbs, csf_ref)

        ! for now (time/iteration comparison) reasons, decide which
        ! reference energy calculation method we use
        ! use the new "direct" calculation method
        calc_off_diag_guga_ref => calc_off_diag_guga_ref_direct

        ! make checks for the RDM calculation
        if (tRDMonfly) then
            call check_rdm_guga_setup()
        end if

        ! make a unified bit rep initializer:
        call init_guga_bitrep(nifd)

        ! set some defaults for non-working things:
        t_fast_pops_core = .false.
        ss_space_in%tApproxSpace = .false.
        trial_space_in%tApproxSpace = .false.

    end subroutine init_guga

    subroutine check_rdm_guga_setup
        character(*), parameter :: this_routine = "check_rdm_guga_setup"

        ! check if the integer types fit for out setup
        if (bit_size(0_n_int) /= bit_size(0_int_rdm)) then
            call stop_all(this_routine, "n_int and int_rdm have different size!")
        end if

        ! we use some bits in the rdm_ind for other information..
        ! check if we still have enough space for all the indices..
        if (nSpatOrbs**4 > 2**(bit_size(int_rdm) - n_excit_info_bits - 1) - 1) then
            call stop_all(this_routine, "cannot store enough indices in rdm_ind!")
        end if

    end subroutine check_rdm_guga_setup

    subroutine checkInputGUGA()
        ! routine to check if all the input parameters given are consistent
        ! and otherwise stops the excecution
        ! is called inf checkinput() in file readinput.F90
        character(*), parameter :: this_routine = 'checkInputGUGA'

        if (tSPN) then
            call stop_all(this_routine, &
                          "GUGA not yet implemented with spin restriction SPIN-RESTRICT!")
        end if

        if (tHPHF) then
            call stop_all(this_routine, &
                          "GUGA not compatible with HPHF option!")
        end if

        if (tSpinProject) then
            call stop_all(this_routine, &
                          "GUGA not compatible with tSpinProject!")
        end if

        ! with the new UEG/Hubbard implementation of the excitation generator
        ! i need symmetry actually!! or otherwise its wrong
        ! have to somehow find out how to check if k-point symmetry is
        ! provided
        if (tGen_sym_guga_ueg .and. lNoSymmetry .and. .not. treal) then
            call stop_all(this_routine, &
                          "UEG/Hubbard implementation of GUGA excitation generator needs symmetry but NOSYMMETRY set! abort!")
        end if

        ! in the real-space do not reorder the orbitals!
        if (treal) t_guga_noreorder = .true.

        if (tExactSizeSpace) then
            call stop_all(this_routine, &
                          "calculation of exact Hilbert space size not yet implemented with GUGA!")
        end if

        if (tUEGNewGenerator) then
            call stop_all(this_routine, &
                          "wrong input: ueg excitation generator chosen! abort!")
        end if

        if (tPickVirtUniform) then
            call stop_all(this_routine, &
                          "wrong input: tPickVirtUniform excitation generator chosen! abort!")
        end if

        if (tGenHelWeighted) then
            call stop_all(this_routine, &
                          "wrong input: tGenHelWeighted excitation generator chosen with GUGA! abort!")
        end if

        if (tGen_4ind_2) then
            call stop_all(this_routine, &
                          "wrong input: tGen_4ind_2 excitation generator chosen with GUGA! abort!")
        end if

        if (tGen_4ind_weighted) then
            call stop_all(this_routine, &
                          "wrong input: tGen_4ind_weighted excitation generator chosen with GUGA! abort!")
        end if

        if (tGen_4ind_reverse) then
            call stop_all(this_routine, &
                          "wrong input: tGen_4ind_reverse excitation generator chosen with GUGA! abort!")
        end if

        if (.not. tNoBrillouin) then
            call stop_all(this_routine, &
                          "Brillouin theorem not valid for GUGA approach!(I think atleast...)")
        end if

        ! also check if provided input values match:
        ! CONVENTION: STOT in units of h/2!
        if (STOT > nEl) then
            call stop_all(this_routine, &
                          "total spin S in units of h/2 cannot be higher than number of electrons!")
        end if

        if (mod(STOT, 2) /= mod(nEl, 2)) then
            call stop_all(this_routine, &
                          "number of electrons nEl and total spin S in units of h/2 must have same parity!")
        end if

        ! maybe more to come...
        ! UHF basis is also not compatible with guga? or not... or atleast
        ! i am not yet implementing it in such a way so it can work
        if (tUHF) then
            call stop_all(this_routine, &
                          "GUGA approach and UHF basis not yet (or never?) compatible!")
        end if

        if (tRealCoeffByExcitLevel) then
            if (RealCoeffExcitThresh > 2) then
                call stop_all(this_routine, &
                              "can only determine up to excit level 2 in GUGA for now!")
            end if
        end if

        if (tReplicaEstimates) then
            call stop_all(this_routine, &
                          "'replica-estimates' not yet implemented with GUGA")
        end if

        if (tPreCond) then
            call stop_all(this_routine, &
                          "'precond' not yet implemented with GUGA. mostly because of communication")
        end if

    end subroutine checkInputGUGA

end module guga_init
