#include "macros.h"
module pcpp_excitgen
    use constants
    use aliasSampling, only: AliasSampler_t, clear_sampler_array
    use bit_rep_data, only: niftot
    use SystemData, only: nel, nBasis, G1, BRR, symmax, Symmetry
    use sym_mod, only: symprod, symconj
    use DetBitOps, only: EncodeBitDet
    use FciMCData, only: excit_gen_store_type, pDoubles, pSingles, projEDet, ilutRef
    use dSFMT_interface, only: genrand_real2_dSFMT
    use Integrals_neci, only: get_umat_el
    use UMatCache, only: gtID
    use excitation_types, only: Excite_1_t, Excite_2_t, canonicalize, occupation_allowed
    use sltcnd_mod, only: sltcnd_excit
    use MPI_wrapper, only: root
    use util_mod, only: binary_search_first_ge, getSpinIndex, swap, custom_findloc, &
                        operator(.div.)
    use get_excit, only: make_double, make_single
    use orb_idx_mod, only: calc_spin_raw
    implicit none

    ! these are the samplers used for generating single excitations
    ! we have one hole sampler for each orbital
    type(AliasSampler_t), allocatable :: single_hole_sampler(:)
    ! we have a single electron sampler, the electron is always chosen first
    type(AliasSampler_t) :: single_elec_sampler

    ! these are the samplers used for generating double excitations
    type(AliasSampler_t) :: double_elec_one_sampler
    type(AliasSampler_t), allocatable :: double_elec_two_sampler(:)

    type(AliasSampler_t), allocatable :: double_hole_one_sampler(:, :)
    ! there is one sampler per spin/symmetry of the last electron
    type(AliasSampler_t), allocatable :: double_hole_two_sampler(:, :, :)

    integer, allocatable :: refDet(:)
    ! maximal value of getSpinIndex
    integer, parameter :: spinMax = 1

contains

    !------------------------------------------------------------------------------------------!
    ! Main routines generating the excitation
    !------------------------------------------------------------------------------------------!

    ! this is the interface routine that calls the corresponding generator to create
    ! a single/double or potentially triple excitation
    subroutine gen_rand_excit_pcpp(nI, ilut, nJ, ilutnJ, exFlag, ic, ExcitMat, tParity, pGen, &
                                   HElGen, store, part_type)
        implicit none
        ! The interface is common to all excitation generators, see proc_ptrs.F90
        integer, intent(in) :: nI(nel), exFlag
        integer(n_int), intent(in) :: iLut(0:niftot)
        integer, intent(out) :: nJ(nel), IC, ExcitMat(2, maxExcit)
        logical, intent(out) :: tParity
        real(dp), intent(out) :: pGen
        type(excit_gen_store_type), intent(inout), target :: store

        ! Not used
        integer(n_int), intent(out) :: ilutnJ(0:niftot)
        HElement_t(dp), intent(out) :: HElGen

        integer, intent(in), optional :: part_type

        real(dp) :: r
        integer :: elec_map(nel)

        unused_var(exFlag); unused_var(part_type)

        HElgen = 0.0

        ! create the map for the electrons
        if (.not. store%tFilled) then
            store%elec_map = create_elec_map(ilut)
            store%tFilled = .true.
        end if
        elec_map = store%elec_map
        ! decide whether to generate a single or double excitation
        r = genrand_real2_dSFMT()
        if (r < pDoubles) then
            call generate_double_pcpp(nI, elec_map, ilut, nJ, excitMat, tParity, pGen)
            IC = 2
            pGen = pGen * pDoubles
        else
            call generate_single_pcpp(nI, elec_map, ilut, nJ, excitMat, tParity, pGen)
            IC = 1
            pGen = pGen * pSingles
        end if

        ! assign ilutnJ
        if (nJ(1) == 0) then
            ilutnJ = 0_n_int
        else
            call EncodeBitDet(nJ, ilutnJ)
        end if

    end subroutine gen_rand_excit_pcpp

    !------------------------------------------------------------------------------------------!

    subroutine generate_double_pcpp(nI, elec_map, ilut, nJ, excitMat, tParity, pGen)
        implicit none
        ! given the initial determinant (both as nI and ilut), create a random double excitation
        ! given by nJ/ilutnJ/excitMat with probability pGen. tParity indicates the fermi sign
        ! picked up by applying the excitation operator
        ! Input: nI - determinant to excite from
        !        elec_map - map to translate electron picks to orbitals
        !        ilut - determinant to excite from in ilut format
        !        nJ - on return, excited determinant
        !        excitMat - on return, excitation matrix nI -> nJ
        !        tParity - on return, the parity of the excitation nI -> nJ
        !        pGen - on return, the probability of generating the excitation nI -> nJ
        integer, intent(in) :: nI(nel)
        integer, intent(in) :: elec_map(nel)
        integer(n_int), intent(in) :: ilut(0:NIfTot)
        integer, intent(out) :: nJ(nel)
        integer, intent(out) :: ExcitMat(2, 2)
        logical, intent(out) :: tParity
        real(dp), intent(out) :: pGen
        ! temporary storage for the probabilities in each step
        real(dp) :: pSGen1, pSGen2, pTGen1, pTGen2
        ! temporary storage for the probabilities in the swapped steps
        real(dp) :: pSSwap1, pSSwap2, pTSwap1, pTSwap2
        ! temporary storage for the unmapped electrons
        integer :: umElec1, umElec2, swapOrb1
        ! chosen source/target orbitals
        integer :: src1, src2
        integer :: tgt1, tgt2
        integer :: elec1, elec2
        ! symmetry + spin to enforce for the last orbital
        type(Symmetry) :: tgtSym
        integer :: tgt1MS, tgt2MS

        call double_elec_one_sampler%sample(umElec1, pSGen1)
        src1 = elec_map(umElec1)

        ! in very rare cases, no mapping is possible in the first place
        ! then, abort
        if (invalid_mapping(src1)) then
            ! the pgen here is just for bookkeeping purpose, it is never
            ! used
            pGen = pSGen1
            return
        end if

        call double_elec_two_sampler(src1)%sample(umElec2, pSGen2)
        src2 = elec_map(umElec2)

        ! it is possible to not be able to map the second electron if
        ! the first mapping occupied the only available slot
        if (invalid_mapping(src2, src1)) then
            pGen = pSGen1 * pSGen2
            return
        end if

        if (src2 < src1) call swap(src1, src2)

        ! we could also have drawn the electrons the other way around
        pSSwap1 = double_elec_one_sampler%get_prob(umElec2)
        swapOrb1 = elec_map(umElec2)
        pSSwap2 = double_elec_two_sampler(swapOrb1)%get_prob(umElec1)
        ! we now have industuingishible src1/src2, add the probabilites
        ! for drawing them either way
        pGen = pSGen1 * pSGen2 + pSSwap1 * pSSwap2

        ! decide which spins the tgt orbs shall have
        ! default to: src1 has the same spin as tgt1
        tgt1MS = getSpinIndex(src1)
        tgt2MS = getSpinIndex(src2)
        ! if we have opposite spins, chose their distribution randomly
        if (G1(src1)%MS /= G1(src2)%MS) then
            if (genrand_real2_dSFMT() < 0.5) call swap(tgt1MS, tgt2MS)
            pGen = pGen * 0.5
        end if

        call double_hole_one_sampler(src1, tgt1MS)%sample(tgt1, pTGen1)
        ! update generation probability so far to ensure it has a valid value on return in any case
        if (abort_excit(tgt1)) then
            pGen = pGen * pTGen1
            return
        end if
        ! we need a specific symmetry now
        tgtSym = getTgtSym(tgt1)
        call double_hole_two_sampler(src2, tgtSym%s, tgt2MS)%sample(tgt2, pTGen2)

        if (abort_excit(tgt2, tgt1)) then
            pGen = pGen * pTGen1 * pTGen2
            return
        end if
        ! Update the generation probability
        ! We could have drawn the target orbitals the other way around
        ! -> adapt pGen
        pTSwap1 = double_hole_one_sampler(src1, tgt2MS)%get_prob(tgt2)
        tgtSym = getTgtSym(tgt2)
        pTSwap2 = double_hole_two_sampler(src2, tgtSym%s, tgt1MS)%get_prob(tgt1)
        pGen = pGen * (pTGen1 * pTGen2 + pTSwap1 * pTSwap2)

        ! generate the output determinant
        elec1 = binary_search_first_ge(nI, src1)
        elec2 = binary_search_first_ge(nI, src2)
        call make_double(nI, nJ, elec1, elec2, tgt1, tgt2, ExcitMat, tParity)

    contains

        function getTgtSym(tgt) result(sym)
            ! return the symmetry of the last target orbital given a first
            ! target orbital tgt
            ! Input: tgt - first target orbital
            ! Output: sym - symmetry of the missing orbital
            implicit none
            integer, intent(in) :: tgt
            type(symmetry) :: sym

            sym = symprod(G1(src1)%Sym, G1(src2)%Sym)
            sym = symprod(sym, symconj(G1(tgt)%Sym))

        end function getTgtSym

        function getTgtSpin(tgt) result(ms)
            ! return the spin of the last target orbital given a first target orbital
            ! Input: tgt - first target orbital
            ! Output: ms - spin index of the missing orbital:
            !              0 - alpha
            !              1 - beta
            implicit none
            integer, intent(in) :: tgt
            integer :: ms

            ! if the electrons have the same spin, return the spin index of tgt
            if (G1(src1)%MS == G1(src2)%MS) then
                ms = getSpinIndex(tgt)
            else
                ! else, the opposite spin index
                ms = 1 - getSpinIndex(tgt)
            end if
        end function getTgtSpin

        function invalid_mapping(src, src2) result(abort)
            ! check if the mapping was successful
            ! Input: src - electron we want to know about: did the mapping succeed?
            !        src2 - other chosen electron
            ! Output: abort - true if the mapping failed
            implicit none

            integer, intent(in) :: src
            integer, optional, intent(in) :: src2
            logical :: abort

            abort = src == 0
            if (present(src2)) abort = abort .or. (src == src2)
            if (abort) then
                nJ = 0
                tParity = .false.
                ExcitMat = 0
                ExcitMat(1, 1) = src
                if (present(src2)) ExcitMat(1, 2) = src2
            end if

        end function invalid_mapping

        function abort_excit(tgt, tgt2) result(abort)
            ! check if the target orbital is valid
            ! Input: tgt - orbital we want to know about: Is an excitation to this possible
            !        tgt2 - second target orbital if already obtained
            ! Output: abort - true if there is no allowed excitation
            implicit none
            integer, intent(in) :: tgt
            integer, optional, intent(in) :: tgt2
            logical :: abort

            abort = IsOcc(ilut, tgt) .or. (tgt == 0)
            if (present(tgt2)) abort = abort .or. tgt == tgt2
            if (abort) then
                nJ = 0
                ExcitMat(1, 1) = src1
                ExcitMat(1, 2) = src2
                ExcitMat(2, 1) = tgt
                if (present(tgt2)) then
                    ExcitMat(2, 2) = tgt2
                else
                    ExcitMat(2, 2) = 0
                end if
                tParity = .false.
            end if

        end function abort_excit
    end subroutine generate_double_pcpp

    !------------------------------------------------------------------------------------------!


    !------------------------------------------------------------------------------------------!

    subroutine generate_single_pcpp(nI, elec_map, ilut, nJ, excitMat, tParity, pGen)
        implicit none
        ! given the initial determinant (both as nI and ilut), create a random double excitation
        ! given by nJ/ilutnJ/excitMat with probability pGen. tParity indicates the fermi sign
        ! picked up by applying the excitation operator
        ! Input: nI - determinant to excite from
        !        elec_map - map to translate electron picks to orbitals
        !        ilut - determinant to excite from in ilut format
        !        nJ - on return, excited determinant
        !        excitMat - on return, excitation matrix nI -> nJ
        !        tParity - on return, the parity of the excitation nI -> nJ
        !        pGen - on return, the probability of generating the excitation nI -> nJ

        integer, intent(in) :: nI(nel)
        integer, intent(in) :: elec_map(nel)
        integer(n_int), intent(in) :: ilut(0:NIfTot)
        integer, intent(out) :: nJ(nel)
        integer, intent(out) :: ExcitMat(2, 2)
        logical, intent(out) :: tParity
        real(dp), intent(out) :: pGen

        integer :: src, elec, tgt
        real(dp) :: pHole

        ! get a random electron
        call single_elec_sampler%sample(src, pGen)

        ! map the electron to the current determinant
        src = elec_map(src)

        ! get a random associated orbital
        call single_hole_sampler(src)%sample(tgt, pHole)

        if (IsOcc(ilut, tgt)) then
            ! invalidate the excitation, we hit an occupied orbital
            nJ = 0
            excitMat = 0
            excitMat(1, 1) = src
            excitMat(2, 1) = tgt
            ! report the failure
            tParity = .false.
        else
            elec = binary_search_first_ge(nI, src)
            call make_single(nI, nJ, elec, tgt, excitMat, tParity)
        end if
        ! add the probability to find this hole from this electron
        pGen = pGen * pHole

    end subroutine generate_single_pcpp

    !------------------------------------------------------------------------------------------!
    ! Functions that map orbital and electron indices between reference and current determinant
    !------------------------------------------------------------------------------------------!

    pure function create_elec_map(ilut) result(map)
        ! Create a map to transfer orbitals between the current det (nI)
        ! and the reference determinant
        ! Input: nI - current determinant
        ! Output: map - list of orbitals where the n-th electron goes to
        implicit none
        integer(n_int), intent(in) :: ilut(0:NifTot)
        integer :: map(nel)
        integer :: i, j
        integer :: ms
        integer(n_int) :: excitedOrbs(0:NifTot)

        ! an ilut of orbitals present in ilut and not in ref
        excitedOrbs = iand(ilut, not(ilutRef(:, 1)))

        do i = 1, nel
            ! occupied orbitals get mapped to themselves
            if (IsOcc(ilut, refDet(i))) then
                map(i) = refDet(i)
            else
                ! unoccupied orbitals get mapped to the next occupied orbital
                ! only look at orbitals with the right spin
                ms = (3 + G1(refDet(i))%MS) / 2
                do j = ms, nBasis, 2
                    ! we check the orbitals in energetical order
                    ! utilize that BRR(j) has the same spin as j
                    if (IsOcc(excitedOrbs, BRR(j))) then
                        map(i) = BRR(j)
                        ! remove the selected orb from the candidates
                        clr_orb(excitedOrbs, BRR(j))
                        exit
                    end if
                end do
            end if
        end do

    end function create_elec_map

    !------------------------------------------------------------------------------------------!
    ! Support routines for HPHF & testing
    !------------------------------------------------------------------------------------------!

    function calc_pgen_pcpp(ilutI, ex, ic) result(pgen)
        integer(n_int), intent(in) :: ilutI(0:NIfTot)
        integer, intent(in) :: ex(2,2), ic
        real(dp) :: pgen

        if(ic == 1) then
            pgen = calc_pgen_singles_pcpp(ilutI,ex(:,1))
            pgen = pgen * pSingles
        else
            pgen = calc_pgen_doubles_pcpp(ilutI,ex(:,1:2))
            pgen = pgen * (1.0_dp - pSingles)
        endif

    contains
    end function calc_pgen_pcpp

    !------------------------------------------------------------------------------------------!

    !> Returns the probability of generating a single excitation using the pcpp excitation generator
    !> @param[in] ilutI  starting determinant of the excitation in the ilut format
    !> @param[in] ex  excitation as a 1-D integer array of size 2
    !> @return pgen  probability of picking ex as an excitation from ilutI with pcpp mode
    !!               (does not account for pSingles)
    function calc_pgen_singles_pcpp(ilutI,ex) result(pgen)
        integer(n_int), intent(in) :: ilutI(0:NIfTot)
        integer, intent(in) :: ex(2)

        real(dp) :: pgen

        integer :: src
        integer :: elec_map(nel)

        ! First, get the probability to draw the target orbital given the source orbital
        pgen = single_hole_sampler(ex(1))%get_prob(ex(2))
        ! Now, trace back what the originally drawn source orbital has been
        elec_map = create_elec_map(ilutI)
        src = custom_findloc(elec_map, ex(1))
        ! And then add the probability of drawing that one
        pgen = pgen * single_elec_sampler%get_prob(src)

    end function calc_pgen_singles_pcpp

    !------------------------------------------------------------------------------------------!

    !> Returns the probability of generating a double excitation using the pcpp excitation generator
    !> @param[in] ilutI  starting determinant of the excitation in the ilut format
    !> @param[in] ex  excitation as a 2-D integer array of size 2x2
    !> @return pgen  probability of picking ex as an excitation from ilutI with pcpp mode
    !!               (does not account for 1.0-pSingles)
    function calc_pgen_doubles_pcpp(ilutI,ex) result(pgen)
        integer(n_int), intent(in) :: ilutI(0:NIfTot)
        integer, intent(in) :: ex(2,2)

        real(dp) :: pgen
        real(dp) :: pHoles, pElecs
        integer :: umElec1, umElec2
        integer :: elec_map(nel)

        elec_map = create_elec_map(ilutI)
        associate(tgt1 => ex(2,1), tgt2 => ex(2,2), src1 => ex(1,1), src2 => ex(1,2))
          ! Get the probability of drawing the two holes (in either order)
          pHoles = pgen_holes(tgt1, tgt2) + pgen_holes(tgt2, tgt1)

          ! Recover the originally drawn electrons by inverting the map
          umElec1 = custom_findloc(elec_map, src1)
          umElec2 = custom_findloc(elec_map, src2)

          ! Get the probability of drawing the two electrons (again, in either order)
          pElecs = pgen_elecs(umElec1, umElec2, src1) &
              + pgen_elecs(umElec2, umElec1, elec_map(umElec2))

          pgen = pHoles * pElecs
          ! If the spins are different, both combinations could have been chosen,
          ! so pgen is halved
          if(G1(tgt2)%Ms /= G1(tgt1)%Ms) pgen = pgen * 0.5
        end associate

    contains

        function pgen_holes(t1, t2) result(pH)
            integer, intent(in) :: t1, t2
            real(dp) :: pH
            real(dp):: pTGen1, pTGen2

            pTGen2 = double_hole_two_sampler(ex(1,2), G1(t2)%sym%s, getSpinIndex(t2))%get_prob(t2)
            pTGen1 = double_hole_one_sampler(ex(1,1), getSpinIndex(t1))%get_prob(t1)
            pH = pTGen1*pTGen2
        end function pgen_holes

        function pgen_elecs(s1, s2, sI) result(pE)
            integer, intent(in) :: s1, s2, sI
            real(dp) :: pE
            real(dp) :: pSGen1, pSGen2

            pSGen1 = double_elec_one_sampler%get_prob(s1)
            pSGen2 = double_elec_two_sampler(sI)%get_prob(s2)
            pE = pSGen1*pSGen2
        end function pgen_elecs

    end function calc_pgen_doubles_pcpp

    !------------------------------------------------------------------------------------------!
    ! Initialization routines for the pcpp excitation generator
    !------------------------------------------------------------------------------------------!

    subroutine init_pcpp_excitgen()
        implicit none

        if (.not. allocated(refDet)) allocate(refDet(nel))
        refDet = projEDet(:, 1)

        call init_pcpp_doubles_excitgen()
        call init_pcpp_singles_excitgen()

    end subroutine init_pcpp_excitgen

    !------------------------------------------------------------------------------------------!

    subroutine init_pcpp_doubles_excitgen()
        implicit none

        call setup_elec_one_sampler()
        call setup_elec_two_sampler()

        call setup_hole_one_sampler()
        call setup_hole_two_sampler()
    contains

        subroutine setup_elec_one_sampler()
            integer :: i
            integer :: a, b, j
            real(dp) :: w(nel)
            logical :: tPar
            integer :: iEl, jEl

            tPar = .false.
            do iEl = 1, nel
                w(iEl) = 0
                do jEl = 1, nel
                    if (iEl /= jEl) then
                        i = refDet(iEl)
                        j = refDet(jEl)
                        do a = 1, nBasis
                            if (.not. any(a == [i, j])) then
                                do b = 1, nBasis
                                    if (.not. any(b == [a, i, j]) &
                                            .and. calc_spin_raw(i) + calc_spin_raw(j) == calc_spin_raw(a) + calc_spin_raw(b)) then
                                        w(iEl) = w(iEl) + abs(sltcnd_excit(refDet, Excite_2_t(i, a, j, b), tPar, assert_occupation=.false.))
                                    end if
                                end do
                            end if
                        end do
                    end if
                end do
            end do

            call apply_lower_bound(w)
            call double_elec_one_sampler%setup(root, w)
        end subroutine setup_elec_one_sampler

        !------------------------------------------------------------------------------------------!

        subroutine setup_elec_two_sampler()
            implicit none
            real(dp) :: w(nel)
            type(Excite_2_t) :: ex
            logical :: tPar
            integer :: aerr
            integer :: i, j, a, b
            integer :: jEl

            allocate(double_elec_two_sampler(nBasis), stat=aerr)
            tPar = .false.
            do i = 1, nBasis
                w = 0.0_dp
                do jEl = 1, nel
                    j = refDet(jEl)
                    if (i /= j) then
                        do a = 1, nBasis
                            if (.not. any(a == [i, j])) then
                                do b = 1, nBasis
                                    if (.not. any(b == [a, i, j]) &
                                            .and. calc_spin_raw(i) + calc_spin_raw(j) == calc_spin_raw(a) + calc_spin_raw(b)) then
                                            w(jEl) = w(jEl) + abs(sltcnd_excit(refDet, Excite_2_t(i, a, j, b), tPar, assert_occupation=.false.))
                                    end if
                                end do
                            end if
                        end do
                    end if
                end do

                ! to prevent bias, a lower bound for the probabilities is set
                call apply_lower_bound(w)

                call double_elec_two_sampler(i)%setup(root, w)
            end do

        end subroutine setup_elec_two_sampler
        !------------------------------------------------------------------------------------------!

        subroutine setup_hole_one_sampler()
            ! generate precomputed probabilities for picking a hole given a selected electron
            ! this is for picking the first hole where no symmetry restrictions apply
            implicit none
            real(dp) :: w(nBasis, 0:spinMax)
            integer :: i, a, iSpin
            integer :: aerr

            allocate(double_hole_one_sampler(nBasis, 0:spinMax), stat=aerr)
            do i = 1, nBasis
                w = 0.0_dp
                do a = 1, nBasis
                    ! we will be requesting orbitals with a defined spin, store it along
                    if (a /= i) &
                        w(a, getSpinIndex(a)) = pp_weight_function(i, a)
                end do

                do iSpin = 0, spinMax
                    call double_hole_one_sampler(i, iSpin)%setup(root, w(:, iSpin))
                end do
            end do
        end subroutine setup_hole_one_sampler

        !------------------------------------------------------------------------------------------!

        subroutine setup_hole_two_sampler()
            ! generate precomputed probabilities for picking hole number 2 given a selected electron
            ! this is for picking the second hole where symmetry restrictions apply
            implicit none
            real(dp) :: w(nBasis, 0:symmax - 1, 0:spinMax)
            integer :: j, b, iSym, iSpin
            integer :: aerr

            ! there is one table for each symmetry and each starting orbital
            allocate(double_hole_two_sampler(nBasis, 0:symmax - 1, 0:spinMax), stat=aerr)
            do j = 1, nBasis
                w = 0.0_dp
                do b = 1, nBasis
                    ! only same-spin and symmetry-allowed excitations from j -> b
                    if (b /= j) &
                        w(b, G1(b)%Sym%s, getSpinIndex(b)) = pp_weight_function(j, b)
                end do

                do iSpin = 0, spinMax
                    do iSym = 0, symmax - 1
                        call double_hole_two_sampler(j, iSym, iSpin)%setup(root, w(:, iSym, iSpin))
                    end do
                end do
            end do

        end subroutine setup_hole_two_sampler

        !------------------------------------------------------------------------------------------!

    end subroutine init_pcpp_doubles_excitgen

    !------------------------------------------------------------------------------------------!

    subroutine init_pcpp_singles_excitgen()
        ! create the probability distributions for drawing single excitations
        ! The normalization 1/n_{jb} used by Neufeld and Thom seems to be just a constant, we
        ! omit it for now
        implicit none

        call setup_elecs_sampler()
        call setup_holes_sampler()

    contains

        !------------------------------------------------------------------------------------------!

        subroutine setup_elecs_sampler()
            ! the probability distribution for selection of electrons
            ! creates a sampler for electron indices within the reference determinant
            ! these later have to be transferred to the current determinant

            ! even though strictly speaking, these are sums of the hole probabilities,
            ! expressing them in terms of the latter would be an unwanted dependency,
            ! since this relation is merely a matter of choice of the algorithm and should not
            ! be reflected in the design of the implementation
            implicit none
            real(dp) :: w(nel)
            integer :: i, a
            integer :: iEl

            do iEl = 1, nel
                w(iEl) = 0
                i = refDet(iEl)
                do a = 1, nBasis
                    w(iEl) = w(iEl) + acc_doub_matel(i, a)
                end do
            end do
            ! load the probabilites for electron selection into the alias table
            call single_elec_sampler%setup(root, w)

        end subroutine setup_elecs_sampler

        !------------------------------------------------------------------------------------------!

        subroutine setup_holes_sampler()
            ! the probability distributions for selection of holes, given the electron orbital
            implicit none
            real(dp) :: w(nBasis)
            integer :: i, a
            integer :: aerr

            ! there is one table for given source orbital
            allocate(single_hole_sampler(nBasis), stat=aerr)

            ! each table has probabilities for all given virtual orbitals a (some of them might
            ! be 0, this has no additional cost)
            do i = 1, nBasis
                w = 0.0_dp
                do a = 1, nBasis
                    ! we never want to sample the source orbital
                    if (i /= a) &
                        ! store the accumulated matrix elements (= un-normalized probability) with
                        ! the corresponding symmetry (if spins of a/i are different, w is 0)
                        w(a) = acc_doub_matel(i, a)
                end do

                call single_hole_sampler(i)%setup(root, w)
            end do

        end subroutine setup_holes_sampler

        !------------------------------------------------------------------------------------------!

        function acc_doub_matel(src, tgt) result(prob)
            ! Accumulate all single excitation matrix elements connecting
            ! D_(j,src)^(b,tgt) for all (j,b), where D is the reference
            ! Input: src - orbital we want to excite from (any orbital is allowed)
            !        tgt - orbital we want to excite to (any orbital is allowed)
            ! Output: prob - Accumulated matrix elements of singles
            !                If src/tgt have different spin, the result is 0, if they have
            !                different symmetry, it is not necessarily
            !
            ! IMPORTANT: The matrix elements are calculated as
            ! <D_j^b|H|D_(j,src)^(b,tgt)> := h_src^tgt + sum_(k occ in D_j^b) <tgt k|src k> - <tgt k|k src>
            ! That is, the left side is to be understood symbolic, there is no actual excitation
            ! from src to tgt
            ! symmetry has to be preserved
            implicit none
            integer, intent(in) :: src, tgt
            real(dp) :: prob
            integer :: b, j
            integer :: nI(nel)
            type(Excite_1_t) :: ex
            logical :: tPar

            prob = 0

            if (symAllowed(src, tgt)) then
                do b = 1, nBasis
                    ! loop over all non-occupied orbitals
                    if (.not. any(b == refDet(:))) then
                        do j = 1, nel
                            ! get the excited determinant D_j^b used for the matrix element
                            if (symAllowed(refDet(j), b)) then
                                call make_single(refDet(:), nI, j, b, ex%val, tPar)
                                ! this is a symbolic excitation, we do NOT require src to be occupied
                                ! we just use the formula for excitation matrix elements
                                prob = prob + abs(sltcnd_excit(nI, Excite_1_t(src, tgt), tPar, assert_occupation=.false.))
                            end if
                        end do
                    end if
                end do
            end if

        end function acc_doub_matel
        !------------------------------------------------------------------------------------------!
    end subroutine init_pcpp_singles_excitgen

    !------------------------------------------------------------------------------------------!

    subroutine update_pcpp_excitgen()

        call finalize_pcpp_excitgen()
        call init_pcpp_excitgen()

    end subroutine update_pcpp_excitgen

    !------------------------------------------------------------------------------------------!
    ! Finalization routines
    !------------------------------------------------------------------------------------------!

    subroutine finalize_pcpp_excitgen()
        implicit none
        integer :: j, k, l
        deallocate(refDet)

        call single_elec_sampler%finalize()

        call clear_sampler_array(single_hole_sampler)
        call double_elec_one_sampler%finalize()
        call clear_sampler_array(double_elec_two_sampler)
        do j = 1, size(double_hole_one_sampler, 1)
            do k = 1, size(double_hole_one_sampler, 2)
                call double_hole_one_sampler(j, k - 1)%finalize()
            end do
        end do
        do j = 1, size(double_hole_two_sampler, 1)
            do k = 1, size(double_hole_two_sampler, 2)
                do l = 1, size(double_hole_two_sampler, 3)
                    call double_hole_two_sampler(j, k - 1, l - 1)%finalize()
                end do
            end do
        end do
        deallocate(double_hole_two_sampler)
    contains

    end subroutine finalize_pcpp_excitgen

    !------------------------------------------------------------------------------------------!
    ! Auxiliary functions
    !------------------------------------------------------------------------------------------!

    pure elemental function gtSpin(spinOrb) result(spinInd)
        ! get a spin index encoding the spin of the input orbital
        ! Input: spinOrb - spin orbital which spin index to get
        ! Output: spinInd - 1 if MS is +1
        !                   2 if MS is -1
        implicit none
        integer, intent(in) :: spinOrb
        integer :: spinInd

        spinInd = mod(spinOrb, 2)
    end function gtSpin

    !------------------------------------------------------------------------------------------!

    pure subroutine apply_lower_bound(w)
        ! even if some excitation is not possible in the reference frame, it might be in the
        ! current determinant, so we enforce a minimum value on the probabilities
        ! Input/Output: w - on input, list of probabilities
        !                 - on output, same list with a minimal value enforced
        implicit none
        real(dp), intent(inout) :: w(:)
        real(dp) :: mVal
        integer :: i

        mVal = 0.001 * minVal(w, w > eps)
        do i = 1, size(w)
            w(i) = max(w(i), mVal)
        end do

    end subroutine apply_lower_bound

    !------------------------------------------------------------------------------------------!

    function pp_weight_function(i, a) result(w)
        ! Given an excitation, return the power-pitzer weights
        ! Can be tweaked to handle 3-body excitations
        ! Input: i - selected electron
        !        a - possible orbital to excite to
        ! Output: w - approximate weight of this excitation
        implicit none

        integer, intent(in) :: i, a
        real(dp) :: w

        w = sqrt(abs(get_umat_el(gtID(i), gtID(a), gtID(a), gtID(i))))
    end function pp_weight_function

    !------------------------------------------------------------------------------------------!

    function symAllowed(a, b) result(allowed)
        ! Check if a transition from a to be is symmetry-allowed
        ! Input: a,b - orbitals to check
        ! Output: allowed - true if and only if a,b have the same symmetries
        implicit none
        integer, intent(in) :: a, b
        logical :: allowed

        allowed = same_spin(a, b) .and. (G1(a)%Sym%s == G1(b)%Sym%s)
    end function symAllowed

end module pcpp_excitgen
