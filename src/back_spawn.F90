#include "macros.h"

module back_spawn

    use CalcData, only: t_back_spawn, tTruncInitiator, t_back_spawn_occ_virt, &
                        t_back_spawn_flex, tReadPops, back_spawn_delay

    use SystemData, only: nel, nbasis, G1, tGen_4ind_2, tGen_4ind_2_symmetric, &
                          tHub, tUEG, nmaxx, nmaxy, nmaxz, tOrbECutoff, OrbECutoff, &
                          tUEGNewGenerator, t_k_space_hubbard

    use constants, only: n_int, dp, bits_n_int, lenof_sign, inum_runs

    use bit_rep_data, only: nifd, niftot

    use fcimcdata, only: projedet, max_calc_ex_level, ilutref

    use dSFMT_interface, only: genrand_real2_dSFMT

    use SymExcitDataMod, only: OrbClassCount, SymLabelCounts2, SymLabelList2, &
                               SpinOrbSymLabel, KPointToBasisFn

    use Parallel_neci, only: iprocindex

    use DetBitOps, only: EncodeBitDet

    use lattice_mod, only: lat

    use sym_mod, only: mompbcsym

    use SystemData, only: tHub, nbasismax

    use lattice_models_utils, only: get_orb_from_kpoints, get_ispn

    use util_mod, only: operator(.div.), stop_all

    implicit none
    private

    public :: is_in_ref, mask_virt_ni, check_electron_location, &
        check_electron_location_spatial, is_in_virt_mask, mask_virt_ilut, &
        init_back_spawn, setup_virtual_mask, pick_occupied_orbital_single, &
        pick_occupied_orbital, pick_virtual_electron_single, &
        pick_virtual_electrons_double_hubbard, pick_occupied_orbital_ueg, &
        pick_second_occupied_orbital, is_allowed_ueg_k_vector, &
        encode_mask_virt, pick_virtual_electrons_double, &
        pick_occupied_orbital_hubbard, check_orbital_location_spatial, &
        check_orbital_location

    ! i need a list to indicate the virtual orbitals in the reference
    ! determinant: the idea of the first implementation is for non-initiators
    ! to only pick electrons from these orbitals, so that the chance to
    ! de-excite relative to the reference determinant is higher and thus to
    ! increase the chance to hit already occupied determinants

    ! i could use a mask in the ilut format..
    integer(n_int), allocatable :: mask_virt_ilut(:, :)

    ! or i could use a list of orbitals in the nI format
    integer, allocatable :: mask_virt_ni(:, :)

contains

    ! what do i need..
    subroutine init_back_spawn()
        ! init routine
        character(*), parameter :: this_routine = "init_back_spawn"

        ! also add some output so people know we use this method
        root_print "BACK-SPAWNING method in use! "
        if (t_back_spawn_flex) then
            root_print "Flex option in use: we pick the electrons randomly"
            root_print " and then decide, where to pick the orbitals from "
            root_print " depending where the electrons are relative to the ref"
        else
            root_print "For non-initiators we only pick electrons from the virtual"
            root_print " orbitals of the reference determinant!"
            root_print " so non-initiators only lower or keep the excitation level constant!"
        end if

        if (t_back_spawn_occ_virt) then
            root_print "additionally option to pick the first orbital (a) from "
            root_print " the occupied manifold of the reference is activated!"
        end if
        ! first it only makes sense if we actually use the initiator method
        if (.not. tTruncInitiator) then
            call stop_all(this_routine, &
                          "back spawning makes only sense in the initiator method!")
        end if

        if (.not. tGen_4ind_2) then
            if (.not. (tHub .or. tUEG)) then
                call stop_all(this_routine, &
                              "for molecular systems this back-spawning need 4ind-weighted-2 or above!")
            end if
        end if

        if (tGen_4ind_2_symmetric) then
            call stop_all(this_routine, &
                          "back-spawning not compatible with symmetric excitation generator!")
        end if

        if (tUEG .and. t_back_spawn) then
            if (.not. tUEGNewGenerator) then
                call stop_all(this_routine, &
                              "the old UEG excitation generator only works with back-spawn-flex")
            end if
        end if

        if (tReadPops) then
            if (back_spawn_delay /= 0) then
                root_print "WARNING: "
                root_print "Restarting from POPSFILE but using a delayed back-spawn! "
                root_print " Are you sure? "
            end if
        end if

        call setup_virtual_mask()

        ! also change the max excitation level calculated
        max_calc_ex_level = nel

    end subroutine init_back_spawn

    subroutine setup_virtual_mask()
        ! routine to setup the list of virtual orbitals in the current
        ! reference determinant, these are then used to choose the electrons
        ! for non-initiator determinants
        ! for now this is only done for single-runs! not dneci, mneci for now!
        character(*), parameter :: this_routine = "setup_virtual_mask"
        integer :: i, j, k

        ! and assure that this routine is called after the first HFDET is
        ! already assigned
        ASSERT(allocated(projedet))
        if (.not. allocated(projedet)) then
            call stop_all(this_routine, &
                          "init_back_spawn() called to early; run reference not yet setup!")
        end if

        ASSERT(allocated(ilutref))
        if (.not. allocated(ilutref)) then
            call stop_all(this_routine, &
                          "init_back_spawn() called to early; run reference not yet setup!")
        end if

        ! first use the most simple implementation of an nI style
        ! virtual orbital indication:
        if (allocated(mask_virt_ni)) deallocate(mask_virt_ni)

        ! i need to adapt that for replica runs
        allocate(mask_virt_ni(nBasis - nel, inum_runs))

        ! i guess the easiest way to do that is to loop over all the
        ! spin-orbitals and only write an entry if this orbital is not
        ! occupied in the reference

        ! ok now for more efficiency i also want to have an ilut version of
        ! mask_virt_ni!
        if (allocated(mask_virt_ilut)) deallocate(mask_virt_ilut)
        allocate(mask_virt_ilut(0:niftot, inum_runs))

        mask_virt_ilut = 0_n_int
        mask_virt_ni = 0

        do k = 1, inum_runs
            j = 1
            do i = 1, nbasis
                ! if (i) is in the reference cycle
                if (is_in_ref(i, k)) cycle
!                 if (any(i == projedet(:,k))) cycle
                ! otherwise fill up the virtual mask
                mask_virt_ni(j, k) = i
                j = j + 1
            end do
            if (any(mask_virt_ni(:, k) == 0)) then
                call stop_all(this_routine, &
                              "something went wrong in the mask_virt_ni setup")
            end if

            ! and also encode the the ilut version
            ! oh thats true.. mask_virt_ni is not always of length(nel)
            call encode_mask_virt(mask_virt_ni(:, k), mask_virt_ilut(:, k))
        end do

    end subroutine setup_virtual_mask

    pure subroutine encode_mask_virt(nI, ilut)
        integer, intent(in) :: nI(nBasis - nel)
        integer(n_int), intent(out) :: ilut(0:niftot)

        integer :: i, pos

        ilut = 0_n_int

        do i = 1, nBasis - nel
            pos = (nI(i) - 1) / bits_n_int
            ilut(pos) = ibset(ilut(pos), mod(nI(i) - 1, bits_n_int))
        end do

    end subroutine encode_mask_virt

    function check_electron_location(src, ic, part_type) result(loc)
        ! routine which determines where the electrons of of an determinant
        ! are located with respect to the reference determinant to
        ! then decide where to pick the orbitals from..
        integer, intent(in) :: src(2), ic
        integer, intent(in) :: part_type
        integer :: loc
        character(*), parameter :: this_routine = "check_electron_location"

        integer :: i
        ! the output integer encodes:
        ! 0 ... both electrons are in the virtual space of the reference
        ! 1 ... the electrons are mixed in occupied and virtual manifold
        ! 2 ... electron(s) are/is in the refernce determinant

        if (ic == 1) then
            ! single exctitation
            ! for complex code part_type_to_run does not actually do
            ! what i need it to do..
            ! the run input here goes from 1 to lenof_sign..
            ! in a single non-complex run:
            ! lenof_sign = 1
            ! inum_runs = 1
            ! so there everything is fine i actually have to change the
            ! unit-tests
            if (is_in_ref(src(1), part_type)) then
                ! this means the electron is in the reference determinant
                ! which means we should pick a hole also in the
                ! reference determinant, or otherwise we definetly
                ! increase the excitation level
                loc = 2
            else
                ! only option 0 and 2 for single excitations!
                loc = 0
            end if

        else if (ic == 2) then
            ! for double excitations we have to check both
            loc = 0
            do i = 1, 2
                if (is_in_ref(src(i), part_type)) then
                    loc = loc + 1
                end if
            end do
        end if

        ASSERT(loc >= 0)
        ASSERT(loc <= 2)

    end function check_electron_location

    function check_electron_location_spatial(orbs, ic, part_type) result(loc)
        ! same function as above, just for spatial orbitals
        integer, intent(in) :: orbs(2), ic, part_type
        integer :: loc
        character(*), parameter :: this_routine = "check_electron_location_spatial"

        integer :: i

        ASSERT(all(orbs >= [0, 0]))
        ASSERT(all(orbs <= [nBasis / 2, nBasis / 2]))

        if (ic == 1) then
            if (is_in_ref_spatial(orbs(1), part_type)) then
                ! this means the electron is in the reference determinant
                ! which means we should pick a hole also in the
                ! reference determinant, or otherwise we definetly
                ! increase the excitation level
                loc = 2
            else
                ! only option 0 and 2 for single excitations!
                loc = 0
            end if

        else if (ic == 2) then
            ! for double excitations we have to check both
            loc = 0
            do i = 1, 2
                if (is_in_ref_spatial(orbs(i), part_type)) then
                    loc = loc + 1
                end if
            end do
        end if

    end function check_electron_location_spatial

    function check_orbital_location(src, ic, part_type) result(loc)
        ! same function as above, but checks if a picked orbital is in the
        ! virtual space of the reference determinant
        integer, intent(in) :: src(2), ic, part_type
        integer :: loc
        character(*), parameter :: this_routine = "check_orbital_location"

        integer :: i

        ! the output:
        ! 0 ... both holes are in the occupied space of the reference
        ! 1 ... the holes are mixed in the occupied and virtual space
        ! 2 ... both holes are in the virtual space of the reference

        if (ic == 1) then
            if (is_in_virt_mask(src(1), part_type)) then
                loc = 2
            else
                loc = 0
            end if
        else if (ic == 2) then
            loc = 0
            do i = 1, 2
                if (is_in_virt_mask(src(i), part_type)) then
                    loc = loc + 1
                end if
            end do
        end if
        ASSERT(loc >= 0)
        ASSERT(loc <= 2)

    end function check_orbital_location

    function check_orbital_location_spatial(orbs, ic, part_type) result(loc)
        ! same function as above just for spatial orbitals
        integer, intent(in) :: orbs(2), ic, part_type
        integer :: loc
        character(*), parameter :: this_routine = "check_orbital_location_spatial"

        integer :: i

        ! the output:
        ! 0 ... both holes are in the occupied space of the reference
        ! 1 ... the holes are mixed in the occupied and virtual space
        ! 2 ... both holes are in the virtual space of the reference

        if (ic == 1) then
            if (is_in_virt_mask_spatial(orbs(1), part_type)) then
                loc = 2
            else
                loc = 0
            end if
        else if (ic == 2) then
            loc = 0
            do i = 1, 2
                if (is_in_virt_mask_spatial(orbs(i), part_type)) then
                    loc = loc + 1
                end if
            end do
        end if
        ASSERT(loc >= 0)
        ASSERT(loc <= 2)

    end function check_orbital_location_spatial

    subroutine pick_virtual_electrons_double(nI, part_type, elecs, src, ispn, &
                                             sum_ml, pgen, calc_pgen)
        ! this is the important routine!
        ! for non-initiator determinants this pick electrons only from the
        ! virtual orbitals of the reference determinant to increase the
        ! chance to de-excite and to spawn to an already occupied
        ! determinant from an non-initiator!
        integer, intent(in) :: nI(nel), part_type
        integer, intent(out) :: elecs(2), src(2), ispn, sum_ml
        real(dp), intent(out) :: pgen
        logical, intent(in), optional :: calc_pgen
        character(*), parameter :: this_routine = "pick_virtual_electrons_double"

        integer :: i, n_valid, j, ind, n_valid_pairs, ind_1, ind_2
        integer :: virt_elecs(nel)

        ! i guess for now i only want to choose uniformly from all the
        ! available electron in the virtual orbitals of the reference

        ! what do we need here?
        ! count all the electrons in the virtual of the reference, then
        ! pick two random orbitals out of those!
        ! check the routine in symrandexcit3.f90 this does the job i guess..

        n_valid = 0
        j = 1
        virt_elecs = -1
        elecs = -1
        src = -1
        ispn = -1
        sum_ml = -1

        do i = 1, nel
            if (is_in_virt_mask(nI(i), part_type)) then
                n_valid = n_valid + 1
                virt_elecs(j) = i
                j = j + 1
            end if
        end do

        if (n_valid < 2) then
            ! something went wrong
            ! in this case i have to abort as no valid double excitation
            ! could have been found
            elecs = 0
            src = 0
            pgen = 0.0_dp
            ! can i set defaults here which do not break the rest of the
            ! code?..
            iSpn = -1
            sum_ml = -1
            return
        end if

        ! determine how many valid pairs there are now
        n_valid_pairs = (n_valid * (n_valid - 1)) / 2

        ASSERT(n_valid_pairs > 0)
        ! and the pgen is now:
        pgen = 1.0_dp / real(n_valid_pairs, dp)

        if (present(calc_pgen)) then
            if (calc_pgen) return
        end if

        ! and is it now enough to do is just like in the symrandexcit3 routine:
        ind = 1 + int(n_valid_pairs * genrand_real2_dSFMT())
        ind_1 = ceiling((1 + sqrt(1 + 8 * real(ind, dp))) / 2)
        ind_2 = ind - ((ind_1 - 1) * (ind_1 - 2)) / 2

        ! and retro pick the electron number from the created list?
        elecs(1) = virt_elecs(ind_1)
        elecs(2) = virt_elecs(ind_2)

        ! hm.. test this tomorrow

        ! now i have to pick two random ones from the list!
        ! all the symmetry related stuff at the end:
        src = nI(elecs)

        ispn = get_ispn(src)

        ! The Ml value is obtained from the orbitals
        sum_ml = sum(G1(src)%Ml)

    end subroutine pick_virtual_electrons_double

    subroutine pick_occupied_orbital_single(ilut, src, cc_index, part_type, &
                                            pgen, orb, calc_pgen)
        integer, intent(in) :: src, cc_index, part_type
        integer(n_int), intent(in) :: ilut(0:niftot)
        real(dp), intent(out) :: pgen
        integer, intent(out) :: orb
        logical, intent(in), optional :: calc_pgen

        ! routine to pick an orbital from the occupied manifold in the
        ! reference determinant for single excitations
        ! i have to take symmetry into account now..  that complicates
        ! things.. and spin..
        character(*), parameter :: this_routine = "pick_occupied_orbital_single"

        integer :: n_valid, j, occ_orbs(nel), i, ind, norb, label_index

        j = 1
        occ_orbs = -1
        orb = -1

        norb = OrbClassCount(cc_index)
        label_index = SymLabelCounts2(1, cc_index)

        ! damn i did not include symmetries todo
        ! ok do it now with symmetries
        do i = 1, norb
            orb = SymLabelList2(label_index + i - 1)
            if (is_in_ref(orb, part_type) .and. IsNotOcc(ilut, orb)) then

                ASSERT(SpinOrbSymLabel(orb) == SpinOrbSymLabel(src))

                occ_orbs(j) = orb
                j = j + 1
            end if
        end do

        n_valid = j - 1

        if (n_valid == 0) then
            orb = 0
            pgen = 0.0_dp
            return
        end if

        ASSERT(n_valid > 0)
        pgen = 1.0_dp / real(n_valid, dp)

        if (present(calc_pgen)) then
            if (calc_pgen) return
        end if

        ! else pick uniformly from that available list..
        ind = 1 + int(genrand_real2_dSFMT() * n_valid)
        orb = occ_orbs(ind)

        ASSERT(orb > 0)

    end subroutine pick_occupied_orbital_single

    subroutine pick_occupied_orbital_hubbard(ilutI, part_type, pgen, orb, calc_pgen)
        ! routine to pick one possible orbital from the occupied manifold
        ! thats the easiest of all implementations actually..
        integer, intent(in) :: part_type
        integer(n_int), intent(in) :: ilutI(0:niftot)
        real(dp), intent(out) :: pgen
        integer, intent(out) :: orb
        logical, intent(in), optional :: calc_pgen
        character(*), parameter :: this_routine = "pick_occupied_orbital_hubbard"
        integer :: n_valid, j, occ_orbs(nel), ind, i

        integer :: orb_a
        n_valid = 0
        j = 1
        occ_orbs = -1
        orb = -1

        ! i also have to include the whole symmetry shabang in the
        ! picker here or?? wtf
        do i = 1, nel
            orb_a = projedet(i, part_type_to_run(part_type))

            ! what am i testing here, actually
            ! i want to loop over the reference det and check if it is
            ! no in nI! that can stay..
            ! or i could just pass also ilut into this function and then
            ! check if ref(i) is occupied..
            ! and i also should include k-point symmetry here or??
            ! why didn't i do that and why does it work anyway..
            ! nah.. in the hubbard this just works fine..
            if (IsNotOcc(ilutI, orb_a)) then
                n_valid = n_valid + 1
                occ_orbs(j) = orb_a
                j = j + 1
            end if
        end do

        if (n_valid == 0) then
            orb = 0
            pgen = 0.0_dp
            return
        end if

        ASSERT(n_valid > 0)

        pgen = 1.0_dp / real(n_valid, dp)
        if (present(calc_pgen)) then
            if (calc_pgen) return
        end if

        ind = 1 + int(n_valid * genrand_real2_dSFMT())
        orb = occ_orbs(ind)

        ASSERT(orb > 0)
        ASSERT(orb <= nbasis)

    end subroutine pick_occupied_orbital_hubbard

    subroutine pick_occupied_orbital_ueg(ilutI, src, ispn, part_type, cpt, &
                                         cum_sum, orb, calc_pgen)
        integer, intent(in) :: src(2), ispn, part_type
        integer(n_int), intent(in) :: ilutI(0:niftot)
        real(dp), intent(out) :: cpt, cum_sum
        integer, intent(out) :: orb
        logical, intent(in), optional :: calc_pgen
        character(*), parameter :: this_routine = "pick_occupied_orbital_ueg"

        integer :: occ_orbs(nel), n_valid, j, ind, i, orb_a, orb_b
        ! the only difference in the ueg orbital picker is that it is not
        ! restricted to pick a beta-orbital first in the case of
        ! a opposite spin excitation

        ! better idea:
        n_valid = 0
        j = 1
        occ_orbs = -1
        orb = -1

        ! loop over ref det
        ! in this routine i also have to check if the momentum is
        ! allowed! why didn't i do that before??
        do i = 1, nel
            orb_a = projedet(i, part_type_to_run(part_type))
            ! check if ref-det electron is NOT in nI
            if (IsNotOcc(ilutI, orb_a)) then
                ! check the symmetry here.. or atleast the spin..
                ! if we are parallel i have to ensure the orbital has the
                ! same spin
                if (is_allowed_ueg_k_vector(src(1), src(2), orb_a)) then
                    ! i also have to check if orb b is not occupied ofc..
                    ! what the fuck? why didn't i do that before
                    orb_b = get_orb_from_kpoints(src(1), src(2), orb_a)

                    if (IsNotOcc(ilutI, orb_b) .and. (orb_a /= orb_b)) then
                        if (ispn /= 2) then
                            if (is_beta(orb_a) .eqv. is_beta(src(1))) then
                                ! this is a valid orbital i guess..
                                n_valid = n_valid + 1
                                occ_orbs(j) = orb_a
                                j = j + 1
                            end if
                        else
                            ! in the ueg case we can pick the first orbital freely
                            ! for a ispn == 2 excitation..
                            n_valid = n_valid + 1
                            occ_orbs(j) = orb_a
                            j = j + 1
                        end if
                    end if
                end if
            end if
        end do

        ! so now we have a list of the possible orbitals in occ_orbs
        ! this has to be atleast 2, or otherwise we won't find a second
        ! orbital.. well no! since the second orbital can be picked from
        ! all the orbitals!
        if (n_valid == 0) then
            orb = 0
            cpt = 0.0_dp
            ! can i set cum_sum to 0 here, or does this invoke divisions by zero?
            cum_sum = 1.0_dp
            return
        end if

        ASSERT(n_valid > 0)
        ! and now the cum_sums and pgens..
        cpt = 1.0_dp / real(n_valid, dp)
        cum_sum = 1.0_dp

        if (present(calc_pgen)) then
            if (calc_pgen) return
        end if

        ind = 1 + int(genrand_real2_dSFMT() * n_valid)

        orb = occ_orbs(ind)

        ASSERT(orb > 0)
        ASSERT(orb <= nbasis)

    end subroutine pick_occupied_orbital_ueg

    subroutine pick_occupied_orbital(ilutI, src, ispn, part_type, cpt, cum_sum, &
                                     orb, calc_pgen)
        integer, intent(in) :: src(2), ispn, part_type
        integer(n_int), intent(in) :: ilutI(0:niftot)
        real(dp), intent(out) :: cpt, cum_sum
        integer, intent(out) :: orb
        logical, intent(in), optional :: calc_pgen
        ! routine to pick an orbital of the occupied manifold of the
        ! reference determinant uniformly
        ! to be compatible with the rest of the 4ind-weighted-2
        ! excitation generators i have to be carefull with the cum_lists
        ! and stuff..
        character(*), parameter :: this_routine = "pick_occupied_orbital"
        integer :: occ_orbs(nel), n_valid, j, ind, i, orb_a

        ! soo what do i need?
        ! i have to check if any of the possible orbitals for nI is occupied
        ! in the reference determinant!

        ! better idea:
        n_valid = 0
        j = 1
        occ_orbs = -1
        orb = -1
        ! loop over ref det
        do i = 1, nel
            orb_a = projedet(i, part_type_to_run(part_type))
            ! check if ref-det electron is NOT in nI
            if (IsNotOcc(ilutI, orb_a)) then
                ! check the symmetry here.. or atleast the spin..
                ! if we are parallel i have to ensure the orbital has the
                ! same spin
                if (ispn /= 2) then
                    if (is_beta(orb_a) .eqv. is_beta(src(1))) then
                        ! this is a valid orbital i guess..
                        n_valid = n_valid + 1
                        occ_orbs(j) = orb_a
                        j = j + 1
                    end if
                else
                    ! there is some weird shenanigan in the gen_a_orb_cum_list
                    ! if the spins are anti-parallel.. why?
                    ! this "only" has to do with the weighting of the
                    ! matrix element.. so it does not affect me here i guess
                    ! so here all the orbitals are alowed..
                    ! UPDATE: nope this also implies that (a) is always a
                    ! beta orbital for anti-parallel spin excitations
                    ! i do not know why exactly, but somebody decided to do
                    ! it this way.. so just to be sure, also do it like that
                    ! in the back-spawn method
                    if (is_beta(orb_a)) then
                        n_valid = n_valid + 1
                        occ_orbs(j) = orb_a
                        j = j + 1
                    end if
                end if
            end if
        end do

        ! so now we have a list of the possible orbitals in occ_orbs
        ! this has to be atleast 2, or otherwise we won't find a second
        ! orbital.. well no! since the second orbital can be picked from
        ! all the orbitals!
        if (n_valid == 0) then
            orb = 0
            cpt = 0.0_dp
            ! can i set cum_sum to 0 here, or does this invoke divisions by zero?
            cum_sum = 1.0_dp
            return
        end if

        ASSERT(n_valid > 0)

        cpt = 1.0_dp / real(n_valid, dp)
        cum_sum = 1.0_dp

        if (present(calc_pgen)) then
            if (calc_pgen) return
        end if

        ind = 1 + int(genrand_real2_dSFMT() * n_valid)
        orb = occ_orbs(ind)

        ASSERT(orb > 0)
        ASSERT(orb <= nbasis)

    end subroutine pick_occupied_orbital

    subroutine pick_second_occupied_orbital(ilutI, cc_b, orb_a, ispn, &
                                            part_type, cpt, cum_sum, orb, calc_pgen)
        ! routine which picks second orbital from the occupied manifold for
        ! a double excitation. this function gets called if we have picked
        ! two electrons also from the occupied manifold in the flex version
        ! of the back-spawning method. to ensure we keep the excitation
        ! level the same but also increase the flexibility of the method
        ! this now has to take symmetries into account, which makes it a
        ! bit more complicated
        integer, intent(in) :: cc_b, orb_a, ispn, part_type
        integer(n_int), intent(in) :: ilutI(0:niftot)
        real(dp), intent(out) :: cpt, cum_sum
        integer, intent(out) :: orb
        logical, intent(in), optional :: calc_pgen
        character(*), parameter :: this_routine = "pick_second_occupied_orbital"

        integer :: label_index, norb, sym_orbs(OrbClassCount(cc_b))
        integer :: i, n_valid, occ_orbs(nel), j, ind, orb_b
        ! i need to take symmetry and spin into account for the valid
        ! "occupied" orbitals.
        ! because we have picked the first indepenent of spin and symmetry

        ! i could compare the reference det and the symmetry allowed list
        ! of orbitals
        label_index = SymLabelCounts2(1, cc_b)
        norb = OrbClassCount(cc_b)

        ! create the symmetry allowed orbital list
        do i = 1, norb
            sym_orbs(i) = SymLabelList2(label_index + i - 1)
        end do

        j = 1
        occ_orbs = -1
        orb = -1

        ! check which occupied orbitals fit all the restrictions:
        ! or i guess this is already covered in the symlabel list!
        ! check that!
        if (ispn == 2) then
            ! then we want the opposite spin of orb_a!
            do i = 1, nel
                orb_b = projedet(i, part_type_to_run(part_type))
                ! check if in occupied manifold
                if (IsNotOcc(ilutI, orb_b)) then
                    ! check if symmetry fits
                    if (any(orb_b == sym_orbs)) then
                        ! and check if spin is opposit
!                         if (.not. (is_beta(orb_a) .eqv. is_beta(orb_b))) then
                        if (.not. same_spin(orb_a, orb_b)) then
                            occ_orbs(j) = orb_b
                            j = j + 1
                        end if
                    end if
                end if
            end do
        else
            ! otherwise we want the same spin but have to ensure it is not
            ! already picked orbital (a)
            do i = 1, nel
                orb_b = projedet(i, part_type_to_run(part_type))
                if (IsNotOcc(ilutI, orb_b)) then
                    if (any(orb_b == sym_orbs)) then
                        if (same_spin(orb_a, orb_b) .and. (orb_a /= orb_b)) then
                            occ_orbs(j) = orb_b
                            j = j + 1
                        end if
                    end if
                end if
            end do
        end if

        n_valid = j - 1

        if (n_valid == 0) then
            orb = 0
            cpt = 0.0_dp
            ! ok here i decide to output it to 1.0.. so do it in all the
            ! other routines too..
            cum_sum = 1.0_dp
            return
        end if

        ASSERT(n_valid > 0)
        cpt = 1.0_dp / real(n_valid, dp)
        cum_sum = 1.0_dp

        if (present(calc_pgen)) then
            if (calc_pgen) return
        end if

        ind = 1 + int(genrand_real2_dSFMT() * n_valid)

        orb = occ_orbs(ind)

        ASSERT(orb > 0)
        ASSERT(orb <= nbasis)

    end subroutine pick_second_occupied_orbital

    subroutine pick_virtual_electrons_double_hubbard(nI, part_type, elecs, src, &
                                                     ispn, pgen, calc_pgen)
        ! specific routine to pick 2 electrons in the k-space hubbard,
        ! since apparently it is important to allow all orderings of
        ! electrons possible.. although this could just be a artifact of the
        ! old hubbard excitation generation
        integer, intent(in) :: nI(nel), part_type
        integer, intent(out) :: elecs(2), src(2), ispn
        real(dp), intent(out) :: pgen
        logical, intent(in), optional :: calc_pgen
        character(*), parameter :: this_routine = "pick_virtual_electrons_double_hubbard"

        integer :: n_valid, i, j, ind_1, ind_2
        integer :: virt_elecs(nel)
        integer :: n_beta, n_alpha
        ! but it is also good to to it here so i can do it more cleanly
        n_valid = 0

        n_beta = 0
        n_alpha = 0
        ! actually for the correct generation probabilities i have to count
        ! the number of valid alpha and beta electrons!
        virt_elecs = -1
        elecs = -1
        src = -1

        j = 1
        do i = 1, nel
            if (is_in_virt_mask(nI(i), part_type)) then
                if (is_beta(nI(i))) n_beta = n_beta + 1
                if (is_alpha(nI(i))) n_alpha = n_alpha + 1
                ! the electron is in the virtual of the
                n_valid = n_valid + 1
                virt_elecs(j) = i
                j = j + 1
            end if
        end do

        ! in the hubbard case i also have to check if there is atleast on
        ! pair possible with opposite spin
        if (n_valid < 2 .or. n_beta == 0 .or. n_alpha == 0) then
            ! something went wrong
            ! in this case i have to abort as no valid double excitation
            ! could have been found
            elecs = 0
            src = 0
            pgen = 0.0_dp
            ! what is ispn on return?? argh too many uninitialized vars.
            ispn = 0
            return
        end if

        ! apparently i have to have both ordering of the electrons in
        ! the hubbard excitation generator
        ! but it must be easier to do that... and more efficient

        ASSERT(n_valid > 1)
        pgen = 1.0_dp / real(n_alpha * n_beta, dp)

        if (present(calc_pgen)) then
            if (calc_pgen) return
        end if

        do i = 1, 1000
            ind_1 = 1 + int(n_valid * genrand_real2_dSFMT())

            do j = 1, 1000
                ind_2 = 1 + int(n_valid * genrand_real2_dSFMT())

                if (ind_1 /= ind_2) exit
            end do

            elecs(1) = virt_elecs(ind_1)
            elecs(2) = virt_elecs(ind_2)
            src = nI(elecs)

            if (is_beta(src(1)) .neqv. is_beta(src(2))) then
                ispn = 2
                exit
            end if
        end do

        if (i > 999 .or. j > 999) then
            print *, "something went wrong, did not find two valid electrons!"
            print *, "nI: ", nI
            print *, "mask_virt_ni:", mask_virt_ni(:, part_type_to_run(part_type))
            print *, "virt_elecs: ", virt_elecs
        end if

    end subroutine pick_virtual_electrons_double_hubbard

    subroutine pick_virtual_electron_single(nI, part_type, elec, pgen_elec, calc_pgen)
        ! same as above for a single excitation
        ! remember: elec is really just the number in the ilut!
        integer, intent(in) :: nI(nel), part_type
        integer, intent(out) :: elec
        real(dp), intent(out) :: pgen_elec
        logical, intent(in), optional :: calc_pgen

        character(*), parameter :: this_routine = "pick_virtual_electron_single"

        integer :: i, n_valid, j, ind
        integer:: virt_elecs(nel)

        ! what do we need here?
        ! count all the electrons in the virtual of the reference, then
        ! create a list of them and pick one uniformly
        n_valid = 0
        j = 1
        virt_elecs = -1
        elec = -1

        do i = 1, nel
            if (is_in_virt_mask(nI(i), part_type)) then
                ! the electron is in the virtual of the
                n_valid = n_valid + 1
                virt_elecs(j) = i
                j = j + 1
            end if
        end do

        if (n_valid == 0) then
            ! something went wrong
            ! yes.. this means it was called on the hartree fock..
            ! but i think aborting the excitation is enough.. i do not
            ! need to stop_all or? but this could catch some bugs..
            elec = 0
            pgen_elec = 0.0_dp
            return
        end if

        ! does this work with an optional logical as input:
        ASSERT(n_valid > 0)

        pgen_elec = 1.0_dp / real(n_valid, dp)

        ! if i only want to calculate the pgens i dont want to call the
        ! random number generator
        if (present(calc_pgen)) then
            if (calc_pgen) return
        end if

        ! and now pick a random number:
        ind = 1 + floor(genrand_real2_dSFMT() * n_valid)
        elec = virt_elecs(ind)
        ASSERT(elec > 0)

    end subroutine pick_virtual_electron_single

    logical function is_in_ref(orb, part_type)
        ! write a function if a certain orbital is in the reference
        ! determinant of replica part_type
        integer, intent(in) :: orb
        integer, intent(in), optional :: part_type

        integer :: temp_part_type
        integer(n_int) :: temp_ilut(0:niftot)

        if (present(part_type)) then
            temp_part_type = part_type
        else
            temp_part_type = 1
        end if

        ! there is an inefficient way to check projedet:

        temp_ilut = ilutref(:, part_type_to_run(temp_part_type))
        is_in_ref = (IsOcc(temp_ilut, orb))

    end function is_in_ref

    logical function is_in_ref_spatial(orb, part_type)
        ! the same function as above, but for a spatial orbital orb
        integer, intent(in) :: orb
        integer, intent(in), optional :: part_type
        character(*), parameter :: this_routine = "is_in_ref_spatial"

        integer :: temp_part_type
        integer(n_int) :: temp_ilut(0:niftot)

        ASSERT(orb >= 0)
        ASSERT(orb <= nBasis / 2)

        if (present(part_type)) then
            temp_part_type = part_type
        else
            temp_part_type = 1
        end if

        ! there is an inefficient way to check projedet:

        temp_ilut = ilutref(:, part_type_to_run(temp_part_type))
        is_in_ref_spatial = (IsOcc(temp_ilut, 2 * orb) .or. IsOcc(temp_ilut, 2 * orb - 1))

    end function is_in_ref_spatial

    logical function is_in_virt_mask(orb, part_type)
        ! also write a quicker routine which checks if an orbital is in
        ! the virtual electron mask
        integer, intent(in) :: orb
        integer, intent(in), optional :: part_type

        integer :: temp_part_type
        integer(n_int) :: temp_ilut(0:niftot)

        if (present(part_type)) then
            temp_part_type = part_type
        else
            temp_part_type = 1
        end if

        temp_ilut = mask_virt_ilut(:, part_type_to_run(temp_part_type))
        is_in_virt_mask = (IsOcc(temp_ilut, orb))

    end function is_in_virt_mask

    logical function is_in_virt_mask_spatial(orb, part_type)
        ! same function as above just for spatial orbital orb
        integer, intent(in) :: orb
        integer, intent(in), optional :: part_type
        character(*), parameter :: this_routine = "is_in_virt_mask_spatial"

        integer :: temp_part_type
        integer(n_int) :: temp_ilut(0:niftot)

        ASSERT(orb >= 0)
        ASSERT(orb <= nBasis / 2)

        if (present(part_type)) then
            temp_part_type = part_type
        else
            temp_part_type = 1
        end if

        temp_ilut = mask_virt_ilut(:, part_type_to_run(temp_part_type))
        is_in_virt_mask_spatial = (IsOcc(temp_ilut, 2 * orb) .or. IsOcc(temp_ilut, 2 * orb - 1))

    end function is_in_virt_mask_spatial

    function is_allowed_ueg_k_vector(orbi, orbj, orba) result(is_allowed)
        integer, intent(in) :: orbi, orbj, orba
        logical :: is_allowed

        integer :: ki(3), kj(3), ka(3), kb(3)
        real(dp) :: testE

        ki = G1(orbi)%k
        kj = G1(orbj)%k

        ! Obtain the new momentum vectors
        ka = G1(orba)%k
        kb = ki + kj - ka

        ! Is kb allowed by the size of the space?
        testE = sum(kb**2)
        if (abs(kb(1)) <= nmaxx .and. abs(kb(2)) <= nmaxy .and. &
            abs(kb(3)) <= nmaxz .and. &
            (.not. (tOrbECutoff .and. (testE > OrbECutoff)))) then

            is_allowed = .true.
        else
            is_allowed = .false.
        end if

    end function is_allowed_ueg_k_vector

end module back_spawn

