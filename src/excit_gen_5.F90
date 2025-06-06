#include "macros.h"

module excit_gen_5

    use SystemData, only: t_mixed_hubbard, nOccAlpha, nOccBeta, AB_elec_pairs, &
                          t_olle_hubbard
    use excit_gens_int_weighted, only: gen_single_4ind_ex, pgen_single_4ind, &
                                       get_paired_cc_ind, select_orb, &
                                       opp_spin_pair_contrib, &
                                       same_spin_pair_contrib, &
                                       pick_biased_elecs, &
                                       pick_weighted_elecs, select_orb, &
                                       pgen_select_orb, pgen_weighted_elecs
    use SymExcitDataMod, only: SpinOrbSymLabel, SymInvLabel, ScratchSize
    use FciMCData, only: excit_gen_store_type, pSingles, pDoubles, projedet, &
                         pParallel
    use SystemData, only: G1, tUHF, tStoreSpinOrbs, nbasis, nel, &
                          tGen_4ind_part_exact, tGen_4ind_2_symmetric, tHPHF, &
                          tGen_guga_crude
    use SymExcit3, only: CountExcitations3, GenExcitations3
    use GenRandSymExcitNUMod, only: init_excit_gen_store
    use DetBitOps, only: ilut_lt, ilut_gt, EncodeBitDet
    use Determinants, only: get_helement
    use DeterminantData, only: write_det
    use dSFMT_interface, only: genrand_real2_dSFMT
    use procedure_pointers, only: get_umat_el
    use sym_general_mod, only: ClassCountInd
    use bit_rep_data, only: NIfTot, NIfD, test_flag, nIfGUGA
    use bit_reps, only: decode_bit_det, get_initiator_flag
    use get_excit, only: make_double
    use UMatCache, only: gtid
    use constants
    use sort_mod
    use util_mod
    use CalcData, only: t_back_spawn, t_back_spawn_occ_virt, t_back_spawn_flex, &
                        occ_virt_level
    use back_spawn, only: pick_virtual_electrons_double, pick_occupied_orbital, &
                          check_electron_location, pick_second_occupied_orbital

    use guga_bitRepOps, only: isProperCSF_ilut, convert_ilut_toGUGA, write_det_guga, &
                              CSF_Info_t, current_csf_i
    use guga_data, only: ExcitationInformation_t
    use guga_excitations, only: global_excitinfo, print_excitInfo
    use guga_matrixElements, only: calc_guga_matrix_element

    implicit none

contains

    subroutine gen_excit_4ind_weighted2(nI, ilutI, nJ, ilutJ, exFlag, ic, &
                                        ExcitMat, tParity, pGen, HelGen, store, part_type)
        !! An API interfacing function for generate_excitation to the rest of NECI:
        !!
        !! Requires guga_bitRepOps::current_csf_i to be set according to the ilutI.
        integer, intent(in) :: nI(nel), exFlag
        integer(n_int), intent(in) :: ilutI(0:NIfTot)
        integer, intent(out) :: nJ(nel), IC, ExcitMat(2, maxExcit)
        logical, intent(out) :: tParity
        real(dp), intent(out) :: pGen
        HElement_t(dp), intent(out) :: HElGen
        type(excit_gen_store_type), intent(inout), target :: store
        integer(n_int), intent(out) :: ilutJ(0:NIfTot)
        integer, intent(in), optional :: part_type
        character(*), parameter :: this_routine = 'gen_excit_4ind_weighted2'

        real(dp) :: pgen2
        real(dp) :: cum_arr(nbasis)
        type(ExcitationInformation_t) :: excitInfo
        integer(n_int) :: ilutGi(0:nifguga), ilutGj(0:nifguga)
#ifdef DEBUG_
        HElement_t(dp) :: temp_hel
#endif
        unused_var(exFlag); unused_var(part_type); unused_var(store)

        HElGen = HEl_zero

        ! Choose if we want to do a single or a double excitation
        ! TODO: We can (in principle) re-use this random number by subdivision
        if (genrand_real2_dSFMT() < pSingles) then

            ic = 1
            call gen_single_4ind_ex(nI, ilutI, nJ, ilutJ, ExcitMat, &
                                    tParity, pGen)
            pgen = pgen * pSingles

        else

            ! OK, we want to do a double excitation
            ic = 2
            call gen_double_4ind_ex2(nI, ilutI, nJ, ilutJ, ExcitMat, tParity, &
                                     pGen)
            pgen = pgen * pDoubles

        end if

        if (nJ(1) == 0) then
            pgen = 0.0_dp
            return
        end if

        ! try implementing the crude guga excitation approximation via the
        ! determinant excitation generator
        if (tGen_guga_crude) then

            call convert_ilut_toGUGA(ilutJ, ilutGj)

            if (.not. isProperCSF_ilut(ilutGJ, .true.)) then
                nJ(1) = 0
                pgen = 0.0_dp
                return
            end if

            call calc_guga_matrix_element(ilutI, current_csf_i, ilutJ, CSF_Info_t(ilutJ), excitInfo, HelGen, .true.)

            if (abs(HelGen) < EPS) then
                nJ(1) = 0
                pgen = 0.0_dp
            end if

            global_excitinfo = excitInfo

            return
        end if

        ! And a careful check!
#ifdef DEBUG_
        if (.not. IsNullDet(nJ)) then
            pgen2 = calc_pgen_4ind_weighted2(nI, ilutI, ExcitMat, ic)
            if (abs(pgen - pgen2) > 1.0e-6_dp) then
                if (.not. tHPHF) then
                    temp_hel = get_helement(nI, nJ, ilutI, ilutJ)
                end if

                write(stdout, *) 'Calculated and actual pgens differ.'
                write(stdout, *) 'This will break HPHF calculations'
                call write_det(stdout, nI, .false.)
                write(stdout, '(" --> ")', advance='no')
                call write_det(stdout, nJ, .true.)
                write(stdout, *) 'Excitation matrix: ', ExcitMat(1, 1:ic), '-->', &
                    ExcitMat(2, 1:ic)
                write(stdout, *) 'Generated pGen:  ', pgen
                write(stdout, *) 'Calculated pGen: ', pgen2
                write(stdout, *) 'matrix element: ', temp_hel
                call stop_all(this_routine, "Invalid pGen")
            end if
        end if
#endif

    end subroutine

    function calc_pgen_4ind_weighted2(nI, ilutI, ex, ic) &
        result(pgen)

        ! What is the probability of the excitation _from_ determinant nI
        ! described by the excitation matrix ex, and the excitation level ic,
        ! being generated according to the 4ind_weighted excitaiton generator?

        integer, intent(in) :: nI(nel), ex(2, 2), ic
        integer(n_int), intent(in) :: ilutI(0:NIfTot)
        real(dp) :: pgen, cum_arr(nbasis)
        character(*), parameter :: this_routine = 'calc_pgen_4ind_weighted2'

        integer :: iSpn, src(ic), tgt(ic)
        real(dp) :: cum_sums(2), int_cpt(2), cpt_pair(2), sum_pair(2)
        logical :: generate_list

        if (ic == 1) then

            ! Singles are calculated in the same way for the _ex and the
            ! _reverse excitation generators
            pgen = pSingles * pgen_single_4ind(nI, ilutI, ex(1, 1), ex(2, 1))

        else if (ic == 2) then

            ! This is a double excitation...
            pgen = pDoubles

            ! Get properties of source electrons
            src = ex(1, :)
            if (is_beta(src(1)) .eqv. is_beta(src(2))) then
                if (is_beta(src(1))) then
                    iSpn = 1
                else
                    iSpn = 3
                end if
            else
                iSpn = 2
            end if

            ! Select a pair of electrons in a weighted fashion
            if (t_mixed_hubbard .or. t_olle_hubbard) then
                pgen = pgen * (1.0_dp - pParallel) / AB_elec_pairs
            else
                pgen = pgen * pgen_weighted_elecs(nI, src)
            end if

            ! Obtain the probability components of picking the electrons in
            ! either A--B or B--A order.
            ! Note that if tGen_4ind_symmtric is not true, then for
            ! non-parallel electrons, one of these components will be zero.
            ! Hence the optimisation comparing the cpt values for A selection
            tgt = ex(2, :)
            call pgen_select_a_orb(ilutI, src, tgt(1), iSpn, int_cpt(1), &
                                   cum_sums(1), cum_arr, .true.)
            if (int_cpt(1) > EPS) then
                ! [W.D.]
                ! this threshold is also really arbitrary..
                ! todo: investigate that!
                ! it has to be atleast twice the integral cut-off to be
                ! anywhere consistent.. although also that is kind of
                ! strange..
                ! now.. i would have to be 2*sqrt(umateps) .. but also that..
                ! just remove it i guess..
                call pgen_select_orb(ilutI, src, tgt(1), tgt(2), int_cpt(2), &
                                     cum_sums(2))
                generate_list = .false.
            else
                generate_list = .true.
                int_cpt(2) = 0.0_dp
                cum_sums(2) = 1.0_dp
            end if

            call pgen_select_a_orb(ilutI, src, tgt(2), iSpn, cpt_pair(1), &
                                   sum_pair(1), cum_arr, generate_list)
            if (cpt_pair(1) > EPS) then
                call pgen_select_orb(ilutI, src, tgt(2), tgt(1), cpt_pair(2), &
                                     sum_pair(2))
            else
                cpt_pair(2) = 0.0_dp
                sum_pair(2) = 1.0_dp
            end if

            ! i think i also have to deal with divisions by zero here
            ! in a correct way, when removing the lower pgen threshold.
            if (any(cum_sums < EPS)) then
                cum_sums = 1.0_dp
                int_cpt = 0.0_dp
            end if

            if (any(sum_pair < EPS)) then
                sum_pair = 1.0_dp
                cpt_pair = 0.0_dp
            end if

            ! And adjust the probability for the components
            pgen = pgen * (product(int_cpt) / product(cum_sums) + &
                           product(cpt_pair) / product(sum_pair))

        else

            ! Deal with some outsider cases that can leak through the HPHF
            ! system.
            pgen = 0.0_dp

        end if

    end function

    subroutine gen_double_4ind_ex2(nI, ilutI, nJ, ilutJ, ex, par, pgen)

        use GenRandSymExcitNUMod, only: RandExcitSymLabelProd
        use SymExcitDataMod, only: SpinOrbSymLabel
        use lattice_models_utils, only: pick_spin_opp_elecs

        integer, intent(in) :: nI(nel)
        integer(n_int), intent(in) :: ilutI(0:NIfTot)
        integer, intent(out) :: nJ(nel), ex(2, maxExcit)
        integer(n_int), intent(out) :: ilutJ(0:NIfTot)
        logical, intent(out) :: par
        real(dp), intent(out) :: pgen
        character(*), parameter :: this_routine = 'gen_double_4ind_ex2'

        integer :: elecs(2), src(2), orbs(2), ispn, sum_ml, cc_a, cc_b
        integer :: sym_product
        real(dp) :: int_cpt(2), cum_sum(2), cpt_pair(2), sum_pair(2)

        ! This array stores the cumulative list used in selecting the first
        ! orbital so that it can be used for calculating the reverse
        ! probability if required.
        real(dp) :: cum_arr(nbasis)

        real(dp) :: scratch_cpt, scratch_sm
        integer :: scratch_orb
        integer :: loc

        ! Pick the electrons in a weighted fashion
        if (t_mixed_hubbard .or. t_olle_hubbard) then
            call pick_biased_elecs(nI, elecs, src, sym_product, ispn, sum_ml, pgen)
        else
            call pick_weighted_elecs(nI, elecs, src, sym_product, ispn, sum_ml, &
                                     pgen)
        end if

        ! then first pick (a) orbital:
        ! for opposite spin excitations (a) is restricted to be a beta orbital!
        ! and the probability is split p(a|ij) = p(j)*p(a|i)
        ! except in the symmetric excitation generator, which isn't used
        ! ever anyway..
        orbs(1) = pick_a_orb(ilutI, src, iSpn, int_cpt(1), cum_sum(1), cum_arr)

        ! Select the B orbital, in the same way as before!!
        ! The symmetry of this second orbital depends on that of the first.
        if (orbs(1) /= 0) then
            cc_a = ClassCountInd(orbs(1))
            cc_b = get_paired_cc_ind(cc_a, sym_product, sum_ml, iSpn)

            ! pick the last orbitals weighted with the exact matrix
            ! element
            orbs(2) = select_orb(ilutI, src, cc_b, orbs(1), int_cpt(2), &
                                 cum_sum(2))
        end if

        ! what does this assert do?  do i have to pick the electrons in a
        ! certain order??

        ASSERT((.not. (is_beta(orbs(2)) .and. .not. is_beta(orbs(1)))) .or. tGen_4ind_2_symmetric)
        if (any(orbs == 0)) then
            nJ(1) = 0
            pgen = 0.0_dp
            return
        end if

        ! can i exit right away if this happens??
        ! i am pretty sure this means
        if (any(cum_sum < EPS)) then
            cum_sum = 1.0_dp
            int_cpt = 0.0_dp
        end if

        ! Calculate the pgens. Note that all of these excitations can be
        ! selected as both A--B or B--A. So these need to be calculated
        ! explicitly.
        if (.not. tGen_guga_crude) then
            ASSERT(tGen_4ind_part_exact)
        end if
        if ((is_beta(orbs(1)) .eqv. is_beta(orbs(2))) .or. tGen_4ind_2_symmetric) then

            ! in the case of parallel spin excitations or symmetrice excitation
            ! generation(but does actually someone use that?) we have to
            ! calculate the probability of picking the holes the other
            ! way around
            call pgen_select_a_orb(ilutI, src, orbs(2), iSpn, cpt_pair(1), &
                                   sum_pair(1), cum_arr, .false.)
            call pgen_select_orb(ilutI, src, orbs(2), orbs(1), &
                                 cpt_pair(2), sum_pair(2))

        else
            cpt_pair = 0.0_dp
            sum_Pair = 1.0_dp
        end if

        if (any(sum_pair < EPS)) then
            cpt_pair = 0.0_dp
            sum_pair = 1.0_dp
        end if

        pgen = pgen * (product(int_cpt) / product(cum_sum) + &
                       product(cpt_pair) / product(sum_pair))

        ! And generate the actual excitation
        call make_double(nI, nJ, elecs(1), elecs(2), orbs(1), orbs(2), &
                         ex, par)
        ilutJ = ilutI
        clr_orb(ilutJ, src(1))
        clr_orb(ilutJ, src(2))
        set_orb(ilutJ, orbs(1))
        set_orb(ilutJ, orbs(2))

    end subroutine gen_double_4ind_ex2

    subroutine gen_a_orb_cum_list(ilut, src, ispn, cum_arr)

        ! This routine generates the cumulative list used in selecting the
        ! first electron. This list is the same whether we are calculating
        ! just the probability, or actually making the selection, so we should
        ! have only one place it is generated.

        integer(n_int), intent(in) :: ilut(0:NIfTot)
        integer, intent(in) :: src(2), iSpn
        real(dp), intent(out) :: cum_arr(nbasis)

        integer :: orb
        character(*), parameter :: t_r = 'gen_a_orb_cum_list'
        character(*), parameter :: this_routine = t_r

        integer :: srcid(2)
        logical :: beta, parallel, valid
        real(dp) :: cum_sum, cpt

        ! Just in case. eeep.
        ! Note that we scale spin/spatial orbitals here with factors of 2
        ! which need more care if using spin orbitals
        if (tUHF .or. tStoreSpinOrbs) &
            call stop_all(this_routine, "ASSUMES RHF orbitals")

        if (iSpn == 1) then
            parallel = .true.
            beta = .true.
        else if (iSpn == 2) then
            parallel = .false.
            beta = .true.
        else
            parallel = .true.
            beta = .false.
        end if

        cum_sum = 0
        do orb = 1, nbasis

            ! TODO: This should be doable in a better way...
            if (beta .eqv. is_beta(src(1))) then
                srcid = gtID(src)
            else
                ASSERT(iSpn == 2)
                ASSERT(beta .eqv. is_beta(src(2)))
                srcid(1) = gtID(src(2))
                srcid(2) = gtID(src(1))
            end if

            valid = .true.
            if (IsOcc(ilut, orb)) valid = .false.
            if (((.not. tGen_4ind_2_symmetric) .or. parallel) .and. &
                (is_beta(orb) .neqv. beta)) valid = .false.

            cpt = 0
            if (valid) then
                ! Get the correct element depending on spin terms
                if (parallel) then
                    cpt = same_spin_pair_contrib(srcid(1), srcid(2), orb, -1)
                else
                    cpt = opp_spin_pair_contrib(srcid(1), srcid(2), orb, -1)
                end if
            end if

            cum_sum = cum_sum + cpt
            cum_arr(orb) = cum_sum
        end do

    end subroutine

    function pick_a_orb(ilut, src, ispn, cpt, cum_sum, cum_arr) result(orb)

        integer(n_int), intent(in) :: ilut(0:NifTot)
        integer, intent(in) :: src(2), iSpn
        real(dp), intent(out) :: cpt, cum_sum
        real(dp), intent(inout) :: cum_arr(nbasis)
        integer :: orb
        character(*), parameter :: t_r = 'pick_a_orb'
        character(*), parameter :: this_routine = t_r

        real(dp) :: r, cum_tst, cpt_tst
        integer :: start_ind, srcid(2)

        logical :: beta, parallel, valid

        ! Just in case. eeep.
        ! Note that we scale spin/spatial orbitals here with factors of 2
        ! which need more care if using spin orbitals
        if (tUHF .or. tStoreSpinOrbs) &
            call stop_all(this_routine, "ASSUMES RHF orbitals")

        ! Generate the cumulative list for making the selection, and bail if
        ! there is no selection avaialable
        call gen_a_orb_cum_list(ilut, src, ispn, cum_arr)
        cum_sum = cum_arr(nbasis)
        if (cum_sum < EPS) then
            orb = 0
            return
        end if

        ! Pick the orbital, and extract the relevant list components for
        ! probability generation purposes
        r = genrand_real2_dSFMT() * cum_sum
        orb = binary_search_first_ge(cum_arr, r)
        if (orb == 1) then
            cpt = cum_arr(1)
        else
            cpt = cum_arr(orb) - cum_arr(orb - 1)
        end if

#ifdef DEBUG_
        call pgen_select_a_orb(ilut, src, orb, iSpn, cpt_tst, cum_tst, &
                               cum_arr, .false.)
        if (abs(cpt_tst - cpt) > 1e-6 .or. abs(cum_tst - cum_sum) > 1e-6) then
            call stop_all(t_r, 'Calculated probability does not match')
        end if
#endif

    end function pick_a_orb

    subroutine pgen_select_a_orb(ilut, src, orb, iSpn, cpt, cum_sum, &
                                 cum_arr, first)

        ! This calculates the probability of selecting the A orbital with the
        ! parameters as specified
        !
        ! cum_arr contains the cumulative array used in making the selection.
        ! This can either be generated in this routine, or generated by this
        ! routine on a previous call, or generated in the pick_a_orb routine.
        ! The parameter first determines if this routine is being called to
        ! generate this array, or if it should be used to save computational
        ! cost.

        integer(n_int), intent(in) :: ilut(0:NIfTot)
        integer, intent(in) :: src(2), orb, iSpn
        real(dp), intent(out) :: cpt, cum_sum
        real(dp), intent(inout) :: cum_arr(nbasis)
        logical, intent(in) :: first
        character(*), parameter :: t_r = 'pgen_select_a_orb'
        character(*), parameter :: this_routine = t_r

        ASSERT(is_beta(src(1)) .or. iSpn /= 1)
        ASSERT(is_beta(src(2)) .or. iSpn /= 1)
        ASSERT(.not. is_beta(src(1)) .or. iSpn /= 3)
        ASSERT(.not. is_beta(src(2)) .or. iSpn /= 3)

        ! If we are not using symmetric calculations, and this electron
        ! has the wrong spin, then the probability is (obviously) zero.
        if (iSpn == 2 .and. .not. tGen_4ind_2_symmetric .and. &
            .not. is_beta(orb)) then
            cpt = 0.0_dp
            cum_sum = 1.0_dp
            return
        end if

        ! If this is the first choice (i.e. selecting A of A-B, rather than B
        ! of B-A), then we need to generate the list.
        if (first) then
            call gen_a_orb_cum_list(ilut, src, ispn, cum_arr)
        end if

        ! If the selection is not possible (this can only happen when
        ! calculating HPHF components) then we should ensure that the
        ! pgen contribution is 0.0, whilst avoiding a divide by zero error.
        cum_sum = cum_arr(nbasis)
        if (cum_sum < EPS) then
            cpt = 0.0_dp
            cum_sum = 1.0_dp
            return
        end if

        ! And extract the relevant component
        if (orb == 1) then
            cpt = cum_arr(1)
        else
            cpt = cum_arr(orb) - cum_arr(orb - 1)
        end if

    end subroutine

end module
