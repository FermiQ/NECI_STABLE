#include "macros.h"
#:include "macros.fpph"

module gasci_singles_pc_weighted
    use constants, only: dp, stdout, n_int, bits_n_int, maxExcit
    use fortran_strings, only: to_upper
    use util_mod, only: stop_all, EnumBase_t, operator(.div.)
    use bit_rep_data, only: NIfTot, nIfD
    use bit_reps, only: decode_bit_det
    use SymExcitDataMod, only: ScratchSize
    use SystemData, only: nEl, nBasis
    use excitation_generators, only: SingleExcitationGenerator_t
    use FciMCData, only: excit_gen_store_type
    use dSFMT_interface, only: genrand_real2_dSFMT
    use aliasSampling, only: AliasSampler_1D_t, AliasSampler_2D_t, do_direct_calculation
    use get_excit, only: make_single
    use MPI_wrapper, only: root
    use excitation_types, only: Excite_1_t, spin_allowed
    use gasci, only: GASSpec_t
    use gasci_util, only: gen_all_excits
    use gasci_supergroup_index, only: SuperGroupIndexer_t, lookup_supergroup_indexer
    use orb_idx_mod, only: calc_spin_raw
    use OneEInts, only: GetTMatEl
    use UMatCache, only: GTID, get_umat_el

    better_implicit_none
    private
    public :: do_allocation, print_options, &
        PC_WeightedSinglesOptions_t, PC_WeightedSinglesOptions_vals_t, &
        PC_Weighted_t


    type, extends(EnumBase_t) :: PC_singles_drawing_t
        private
        character(9) :: str
    contains
        procedure :: to_str
    end type

    type :: PC_singles_drawing_vals_t
        type(PC_singles_drawing_t) :: &
            UNDEFINED = PC_singles_drawing_t(-1, 'UNDEFINED'), &
            FULL_FULL = PC_singles_drawing_t(1, 'FULL:FULL'), &
                !! We draw from \( p(I)|_{D_i} \) and then \( p(A | I)_{A \notin D_i} \)
                !! and both probabilites come from the weighting scheme given in
                !! `possible_PC_singles_weighting_t`.
                !! We guarantee that \(I\) is occupied and \(A\) is unoccupied.
            UNIF_FULL = PC_singles_drawing_t(2, 'UNIF:FULL'), &
                !! We draw from \( \tilde{p}(I)|_{D_i} \) uniformly and then from
                !! \( p(A | I)_{A \notin D_i} \).
                !! I.e. only the second electron comes from the weighting scheme given in
                !! `possible_PC_singles_weighting_t`.
                !! We guarantee that \(I\) is occupied and \(A\) is unoccupied.
            UNIF_FAST = PC_singles_drawing_t(3, 'UNIF:FAST')
                !! We draw from \( \tilde{p}(I)|_{D_i} \) uniformly and then from \( p(A | I) \).
                !! I.e. only the second electron comes from the weighting scheme given in
                !! `possible_PC_singles_weighting_t`
                !! We only guarantee that \(I\) is occupied.
        contains
            procedure, nopass :: from_str => drawing_from_keyword
    end type

    type(PC_singles_drawing_vals_t), parameter :: &
        PC_singles_drawing_vals = PC_singles_drawing_vals_t()

    type :: PC_WeightedSinglesOptions_t
        type(PC_singles_drawing_t) :: drawing
    end type

    type :: PC_WeightedSinglesOptions_vals_t
        type(PC_singles_drawing_vals_t) :: drawing = PC_singles_drawing_vals_t()
    end type

    type, abstract, extends(SingleExcitationGenerator_t) :: PC_Weighted_t
        type(AliasSampler_1D_t) :: I_sampler
            !! p(I | i_sg)
            !! The probability of picking particle `I` in the supergroup i_sg.
        type(AliasSampler_2D_t) :: A_sampler
            !! p(A | I, i_sg)
            !! The probability of picking the hole A after having picked particle I
            !! in the supergroup i_sg.
        real(dp), allocatable :: weights(:, :, :)
            !! The weights w_{A, I, i_sg} for the excitation of I -> A.
            !! They are made independent of the determinant by various approximations:
            !! For example setting \( w_{A, I, i_sg} = | h_{I, A} + \sum_{R} g_{I, A, R, R} - g_{I, R, R, A} | \)
            !! where \(R\) runs over all orbitals instead of only the occupied.
        class(GASSpec_t), allocatable :: GAS_spec
            !! The GAS specification
        type(SuperGroupIndexer_t), pointer :: indexer => null()
            !! The Supergroup indexer.
            !! This is only a pointer because components cannot be targets
            !! otherwise. :-(
        logical, public :: use_lookup = .false.
            !! Use a lookup for the supergroup index in global_det_data.
        logical, public :: create_lookup = .false.

        integer(n_int), private :: last_possible_occupied
            !! The last element of the ilut array has some elements
            !! which are not used, if the number of spinorbitals is not a multiple of
            !! bitsize_n_int.
            !! To correctly zero them this bitmask is 1 wherever a determinant
            !! could be occupied in the last element, and 0 otherwise.
    contains
        private
        procedure, public :: init
        procedure, public :: finalize
        procedure, public :: gen_all_excits => gen_all_excits_PC_Weighted_t
        procedure :: get_unoccupied
    end type

    type, extends(PC_Weighted_t) :: PC_SinglesFullyWeighted_t
    contains
        private
        procedure, public :: gen_exc => PC_SinglesFullyWeighted_gen_exc
        procedure, public :: get_pgen => PC_SinglesFullyWeighted_get_pgen
    end type

    type, extends(PC_Weighted_t) :: PC_SinglesWeighted_t
    contains
        private
        procedure, public :: gen_exc => PC_SinglesWeighted_gen_exc
        procedure, public :: get_pgen => PC_SinglesWeighted_get_pgen
    end type

    type, extends(PC_Weighted_t) :: PC_SinglesFastWeighted_t
    contains
        private
        procedure, public :: gen_exc => PC_SinglesFastWeighted_gen_exc
        procedure, public :: get_pgen => PC_SinglesFastWeighted_get_pgen
    end type
contains

    subroutine do_allocation(generator, PC_singles_drawing)
        class(SingleExcitationGenerator_t), allocatable, intent(inout) :: generator
        type(PC_singles_drawing_t), intent(in) :: PC_singles_drawing
        routine_name("do_allocation")
        if (allocated(generator)) then
            call generator%finalize()
            deallocate(generator)
        end if
        if (PC_singles_drawing == PC_singles_drawing_vals%FULL_FULL) then
            allocate(PC_SinglesFullyWeighted_t :: generator)
        else if (PC_singles_drawing == PC_singles_drawing_vals%UNIF_FULL) then
            allocate(PC_SinglesWeighted_t :: generator)
        else if (PC_singles_drawing == PC_singles_drawing_vals%UNIF_FAST) then
            allocate(PC_SinglesFastWeighted_t :: generator)
        else
            call stop_all(this_routine, "Invalid choise for PC singles drawer.")
        end if
    end subroutine

    subroutine print_drawing_option(drawing, iunit)
        type(PC_singles_drawing_t), intent(in) :: drawing
        integer, intent(in) :: iunit
        routine_name("print_drawing_option")
        associate(vals => PC_singles_drawing_vals)
            if (drawing == vals%FULL_FULL) then
                write(iunit, *) 'We draw from \( p(I)|_{D_i} \) and then \( p(A | I)_{A \notin D_i} \) '
                write(iunit, *) 'and both probabilites come from the precomputed weighting for singles '
                write(iunit, *) 'We guarantee that \(I\) is occupied and \(A\) is unoccupied.'
            else if (drawing == vals%UNIF_FULL) then
                write(iunit, *) 'We draw from \( \tilde{p}(I)|_{D_i} \) uniformly and then from'
                write(iunit, *) '\( p(A | I)_{A \notin D_i} \).'
                write(iunit, *) 'I.e. only the second electron comes from the weighting scheme given in'
                write(iunit, *) '`possible_PC_singles_weighting_t`.'
                write(iunit, *) 'We guarantee that \(I\) is occupied and \(A\) is unoccupied.'
            else if (drawing == vals%UNIF_FAST) then
                write(iunit, *) 'We draw from \( \tilde{p}(I)|_{D_i} \) uniformly and then from \( p(A | I) \).'
                write(iunit, *) 'I.e. only the second electron comes from the weighting scheme given in'
                write(iunit, *) '`possible_PC_singles_weighting_t`'
                write(iunit, *) 'We only guarantee that \(I\) is occupied.'
            else
                call stop_all(this_routine, "Invalid choise for PC singles drawing.")
            end if
        end associate
    end subroutine

    subroutine print_options(options, iunit)
        type(PC_WeightedSinglesOptions_t), intent(in) :: options
        integer, intent(in) :: iunit
        write(iunit, *)
        call print_drawing_option(options%drawing, iunit)
        write(iunit, *)
    end subroutine

    pure function drawing_from_keyword(w) result(res)
        !! Parse a given keyword into the possible drawing schemes.
        character(*), intent(in) :: w
        type(PC_singles_drawing_t) :: res
        routine_name("from_keyword")
        select case(to_upper(w))
        case(PC_singles_drawing_vals%FULL_FULL%str)
            res = PC_singles_drawing_vals%FULL_FULL
        case(PC_singles_drawing_vals%UNIF_FULL%str)
            res = PC_singles_drawing_vals%UNIF_FULL
        case(PC_singles_drawing_vals%UNIF_FAST%str)
            res = PC_singles_drawing_vals%UNIF_FAST
        case default
            call stop_all(this_routine, trim(w)//" not a valid PC-WEIGHTED singles drawing scheme")
        end select
    end function

    pure function to_str(options) result(res)
        !! Parse a given keyword into the possible drawing schemes.
        class(PC_singles_drawing_t), intent(in) :: options
        character(9) :: res
        routine_name("from_keyword")
        if (options == PC_singles_drawing_vals%FULL_FULL) then
            res = PC_singles_drawing_vals%FULL_FULL%str
        else if (options == PC_singles_drawing_vals%UNIF_FULL) then
            res = PC_singles_drawing_vals%UNIF_FULL%str
        else if (options == PC_singles_drawing_vals%UNIF_FAST) then
            res = PC_singles_drawing_vals%UNIF_FAST%str
        else
            call stop_all(this_routine, "Should not be here.")
        end if
    end function

    subroutine init(this, GAS_spec, use_lookup, create_lookup)
        class(PC_Weighted_t), intent(inout) :: this
        class(GASSpec_t), intent(in) :: GAS_spec
        logical, intent(in) :: use_lookup, create_lookup
        routine_name("init")
        integer, allocatable :: supergroups(:, :)
        integer :: n_supergroups, nBI

        this%GAS_spec = GAS_spec
        allocate(this%indexer, source=SuperGroupIndexer_t(GAS_spec, nEl))
        this%create_lookup = create_lookup
        this%use_lookup = use_lookup

        if (this%create_lookup) then
            if (associated(lookup_supergroup_indexer)) then
                call stop_all(this_routine, 'Someone else is already managing the supergroup lookup.')
            else
                write(stdout, *) 'PC particles is creating and managing the supergroup lookup'
                lookup_supergroup_indexer => this%indexer
            end if
        end if
        if (this%use_lookup) write(stdout, *) 'PC particles is using the supergroup lookup'

        nBI = this%GAS_spec%n_spin_orbs()
        supergroups = this%indexer%get_supergroups()
        n_supergroups = size(supergroups, 2)

        this%last_possible_occupied = 0_n_int
        block
            integer :: i
            do i = 0, ilut_off(nBasis)
                this%last_possible_occupied = ibset(this%last_possible_occupied, i)
            end do
        end block

        call this%I_sampler%shared_alloc(n_supergroups, nBI, 'PC_singles_I')
        call this%A_sampler%shared_alloc([nBi, n_supergroups], nBI, 'PC_singles_A')
        allocate(this%weights(nBI, nBI, n_supergroups), source=0._dp)
        block
            integer :: i_sg, src, tgt
            type(Excite_1_t) :: exc
            do i_sg = 1, n_supergroups
                do src = 1, nBi
                    do tgt = 1, nBi
                        if (src == tgt) cycle
                        exc = Excite_1_t(src, tgt)
                        if (this%GAS_spec%is_allowed(exc, supergroups(:, i_sg)) &
                                .and. spin_allowed(exc) &
                                .and. symmetry_allowed(exc) &
                        ) then
                            this%weights(tgt, src, i_sg) = get_weight(exc)
                        end if
                    end do
                    call this%A_sampler%setup_entry(src, i_sg, root, this%weights(:, src, i_sg))
                end do
                call this%I_sampler%setup_entry(i_sg, root, sum(this%weights(:, :, i_sg), dim=1))
            end do
        end block

    contains
            ! For single excitations it is simple
            logical pure function symmetry_allowed(exc)
                use SymExcitDataMod, only: SpinOrbSymLabel
                type(Excite_1_t), intent(in) :: exc
                symmetry_allowed = SpinOrbSymLabel(exc%val(1, 1)) == SpinOrbSymLabel(exc%val(2, 1))
            end function
    end subroutine

    pure subroutine get_unoccupied(this, ilutI, ilut_unoccupied, unoccupied)
        !! Return a bitmask and enumeration of the unoccupied spin orbitals.
        class(PC_Weighted_t), intent(in) :: this
        integer(n_int), intent(in) :: ilutI(0 : nIfD)
        integer(n_int), intent(out) :: ilut_unoccupied(0 : nIfD)
        integer, intent(out) :: unoccupied(nBasis - nEl)
        ilut_unoccupied = not(ilutI)
        ilut_unoccupied(nIfd) = iand(ilut_unoccupied(nIfd), this%last_possible_occupied)
        call decode_bit_det(unoccupied, ilut_unoccupied)
    end subroutine

    subroutine PC_SinglesFullyWeighted_gen_exc(this, nI, ilutI, nJ, ilutJ, exFlag, ic, &
                                     ex, tParity, pGen, hel, store, part_type)
        class(PC_SinglesFullyWeighted_t), intent(inout) :: this
        integer, intent(in) :: nI(nel), exFlag
        integer(n_int), intent(in) :: ilutI(0:NIfTot)
        integer, intent(out) :: nJ(nel), ic, ex(2, maxExcit)
        integer(n_int), intent(out) :: ilutJ(0:NifTot)
        real(dp), intent(out) :: pGen
        logical, intent(out) :: tParity
        HElement_t(dp), intent(out) :: hel
        type(excit_gen_store_type), intent(inout), target :: store
        integer, intent(in), optional :: part_type

        integer :: elec, src, tgt, i_sg
        real(dp) :: p_src, p_tgt

        @:unused_var(exFlag, part_type)
#ifdef WARNING_WORKAROUND_
        hel = 0.0_dp
#endif
        ic = 1

        if (this%use_lookup) then
            i_sg = this%indexer%lookup_supergroup_idx(store%idx_curr_dets, nI)
        else
            i_sg = this%indexer%idx_nI(nI)
        end if

        select_particle: block
            real(dp) :: renorm_src
            renorm_src = sum(this%I_sampler%get_prob(i_sg, nI))
            call this%I_sampler%constrained_sample(i_sg, nI, ilutI(0 : nIfD), renorm_src, elec, src, p_src)
            if (src == 0) then
                call make_invalid()
                return
            end if
        end block select_particle

        select_hole: block
            real(dp) :: renorm_tgt
            integer :: dummy, unoccupied(nBasis - nEl)
            integer(n_int) :: ilut_unoccupied(0 : nIfD)
            call this%get_unoccupied(ilutI(0 : nIfD), ilut_unoccupied, unoccupied)
            renorm_tgt = 1._dp - sum(this%A_sampler%get_prob(src, i_sg, nI))
            if (do_direct_calculation(renorm_tgt)) then
                renorm_tgt = sum(this%A_sampler%get_prob(src, i_sg, unoccupied))
            end if

            call this%A_sampler%constrained_sample(&
                 src, i_sg, unoccupied, ilut_unoccupied, renorm_tgt, dummy, tgt, p_tgt)
            if (tgt == 0) then
                call make_invalid()
                return
            end if
        end block select_hole

        pGen = p_src * p_tgt
        call make_single(nI, nJ, elec, tgt, ex, tParity)
        ilutJ = ilutI
        clr_orb(ilutJ, src)
        set_orb(ilutJ, tgt)

        contains

            subroutine make_invalid()
                nJ(1) = 0
                ilutJ = 0_n_int
            end subroutine
    end subroutine PC_SinglesFullyWeighted_gen_exc


    function PC_SinglesFullyWeighted_get_pgen(this, nI, ilutI, ex, ic, ClassCount2, ClassCountUnocc2) result(p_gen)
        class(PC_SinglesFullyWeighted_t), intent(inout) :: this
        integer, intent(in) :: nI(nel)
        integer(n_int), intent(in) :: ilutI(0:NIfTot)
        integer, intent(in) :: ex(2, maxExcit), ic
        integer, intent(in) :: ClassCount2(ScratchSize), ClassCountUnocc2(ScratchSize)
        debug_function_name("get_pgen")
        real(dp) :: p_gen
        integer :: i_sg

        integer :: unoccupied(nBasis - nEl)
        integer(n_int) :: ilut_unoccupied(0 : nIfD)

        @:ASSERT(ic == 1)
        @:unused_var(ClassCount2, ClassCountUnocc2)
        i_sg = this%indexer%idx_nI(nI)
        call this%get_unoccupied(ilutI, ilut_unoccupied, unoccupied)
        associate (src => ex(1, 1), tgt => ex(2, 1))
            p_gen = this%I_sampler%get_prob(i_sg, src) &
                        / sum(this%I_sampler%get_prob(i_sg, nI)) &
                    * this%A_sampler%get_prob(src, i_sg, tgt) &
                        / sum(this%A_sampler%get_prob(src, i_sg, unoccupied))
        end associate
    end function PC_SinglesFullyWeighted_get_pgen


    subroutine PC_SinglesWeighted_gen_exc(this, nI, ilutI, nJ, ilutJ, exFlag, ic, &
                                     ex, tParity, pGen, hel, store, part_type)
        class(PC_SinglesWeighted_t), intent(inout) :: this
        integer, intent(in) :: nI(nel), exFlag
        integer(n_int), intent(in) :: ilutI(0:NIfTot)
        integer, intent(out) :: nJ(nel), ic, ex(2, maxExcit)
        integer(n_int), intent(out) :: ilutJ(0:NifTot)
        real(dp), intent(out) :: pGen
        logical, intent(out) :: tParity
        HElement_t(dp), intent(out) :: hel
        type(excit_gen_store_type), intent(inout), target :: store
        integer, intent(in), optional :: part_type

        integer :: elec, src, tgt, i_sg
        real(dp) :: p_src, p_tgt

        @:unused_var(exFlag, part_type)
#ifdef WARNING_WORKAROUND_
        hel = 0.0_dp
#endif
        ic = 1

        if (this%use_lookup) then
            i_sg = this%indexer%lookup_supergroup_idx(store%idx_curr_dets, nI)
        else
            i_sg = this%indexer%idx_nI(nI)
        end if

        select_particle: block
            elec = int(genrand_real2_dSFMT() * nel) + 1
            src = nI(elec)
            p_src = 1._dp / real(nEl, dp)
        end block select_particle

        select_hole: block
            real(dp) :: renorm_tgt
            integer :: dummy, unoccupied(nBasis - nEl)
            integer(n_int) :: ilut_unoccupied(0 : nIfD)
            call this%get_unoccupied(ilutI(0 : nIfD), ilut_unoccupied, unoccupied)
            renorm_tgt = 1._dp - sum(this%A_sampler%get_prob(src, i_sg, nI))
            if (do_direct_calculation(renorm_tgt)) then
                renorm_tgt = sum(this%A_sampler%get_prob(src, i_sg, unoccupied))
            end if

            call this%A_sampler%constrained_sample(&
                 src, i_sg, unoccupied, ilut_unoccupied, renorm_tgt, dummy, tgt, p_tgt)
            if (tgt == 0) then
                call make_invalid()
                return
            end if
        end block select_hole

        pGen = p_src * p_tgt
        call make_single(nI, nJ, elec, tgt, ex, tParity)
        ilutJ = ilutI
        clr_orb(ilutJ, src)
        set_orb(ilutJ, tgt)
        contains

            subroutine make_invalid()
                nJ(1) = 0
                ilutJ = 0_n_int
            end subroutine
    end subroutine PC_SinglesWeighted_gen_exc


    function PC_SinglesWeighted_get_pgen(this, nI, ilutI, ex, ic, ClassCount2, ClassCountUnocc2) result(p_gen)
        class(PC_SinglesWeighted_t), intent(inout) :: this
        integer, intent(in) :: nI(nel)
        integer(n_int), intent(in) :: ilutI(0:NIfTot)
        integer, intent(in) :: ex(2, maxExcit), ic
        integer, intent(in) :: ClassCount2(ScratchSize), ClassCountUnocc2(ScratchSize)
        debug_function_name("get_pgen")
        real(dp) :: p_gen
        integer :: i_sg
        real(dp) :: p_src, p_tgt

        integer :: unoccupied(this%GAS_spec%n_spin_orbs() - nEl)
        integer(n_int) :: ilut_unoccupied(0 : nIfD)

        @:ASSERT(ic == 1)
        @:unused_var(ClassCount2, ClassCountUnocc2)
        i_sg = this%indexer%idx_nI(nI)
        call this%get_unoccupied(ilutI, ilut_unoccupied, unoccupied)
        p_src = 1._dp / real(nEl, dp)
        associate (src => ex(1, 1), tgt => ex(2, 1))
            p_tgt = this%weights(tgt, src, i_sg) / sum(this%weights(unoccupied, src, i_sg))
        end associate
        p_gen = p_src * p_tgt
    end function PC_SinglesWeighted_get_pgen


    subroutine PC_SinglesFastWeighted_gen_exc(this, nI, ilutI, nJ, ilutJ, exFlag, ic, &
                                     ex, tParity, pGen, hel, store, part_type)
        class(PC_SinglesFastWeighted_t), intent(inout) :: this
        integer, intent(in) :: nI(nel), exFlag
        integer(n_int), intent(in) :: ilutI(0:NIfTot)
        integer, intent(out) :: nJ(nel), ic, ex(2, maxExcit)
        integer(n_int), intent(out) :: ilutJ(0:NifTot)
        real(dp), intent(out) :: pGen
        logical, intent(out) :: tParity
        HElement_t(dp), intent(out) :: hel
        type(excit_gen_store_type), intent(inout), target :: store
        integer, intent(in), optional :: part_type

        integer :: elec, src, tgt, i_sg
        real(dp) :: p_src, p_tgt

        @:unused_var(exFlag, part_type)
#ifdef WARNING_WORKAROUND_
        hel = 0.0_dp
#endif
        ic = 1

        if (this%use_lookup) then
            i_sg = this%indexer%lookup_supergroup_idx(store%idx_curr_dets, nI)
        else
            i_sg = this%indexer%idx_nI(nI)
        end if

        select_particle: block
            elec = int(genrand_real2_dSFMT() * nEl) + 1
            src = nI(elec)
            p_src = 1._dp / real(nEl, dp)
        end block select_particle

        select_hole: block
            call this%A_sampler%sample(src, i_sg, tgt, p_tgt)
            if (tgt == 0) then
                call make_invalid()
                return
            else if (IsOcc(ilutI, tgt)) then
                call make_invalid()
                return
            end if
        end block select_hole

        pGen = p_src * p_tgt
        call make_single(nI, nJ, elec, tgt, ex, tParity)
        ilutJ = ilutI
        clr_orb(ilutJ, src)
        set_orb(ilutJ, tgt)

        contains

            subroutine make_invalid()
                nJ(1) = 0
                ilutJ = 0_n_int
            end subroutine
    end subroutine PC_SinglesFastWeighted_gen_exc


    function PC_SinglesFastWeighted_get_pgen(this, nI, ilutI, ex, ic, ClassCount2, ClassCountUnocc2) result(p_gen)
        class(PC_SinglesFastWeighted_t), intent(inout) :: this
        integer, intent(in) :: nI(nel)
        integer(n_int), intent(in) :: ilutI(0:NIfTot)
        integer, intent(in) :: ex(2, maxExcit), ic
        integer, intent(in) :: ClassCount2(ScratchSize), ClassCountUnocc2(ScratchSize)
        debug_function_name("get_pgen")
        real(dp) :: p_gen
        integer :: i_sg

        @:ASSERT(ic == 1)
        @:unused_var(ilutI, ClassCount2, ClassCountUnocc2)
        i_sg = this%indexer%idx_nI(nI)
        associate (src => ex(1, 1), tgt => ex(2, 1))
            p_gen = 1._dp / real(nEl, dp) * this%A_sampler%get_prob(src, i_sg, tgt)
        end associate
    end function PC_SinglesFastWeighted_get_pgen


    subroutine finalize(this)
        class(PC_Weighted_t), intent(inout) :: this

        if (allocated(this%weights)) then
            ! Yes, we assume that either all, or none is allocated
            ! at the same time. It is good if the code breaks if
            ! that assumption is wrong.
            call this%I_sampler%finalize()
            call this%A_sampler%finalize()
            deallocate(this%indexer, this%weights, this%GAS_spec)
            if (this%create_lookup) nullify(lookup_supergroup_indexer)
        end if
    end subroutine


    pure function get_weight(exc) result(w)
        type(Excite_1_t), intent(in) :: exc
        real(dp) :: w
        integer :: R
        real(dp) :: two_el_term
        associate(I => exc%val(1, 1), A => exc%val(2, 1))
            two_el_term = 0._dp
            do R = 1, nBasis
                two_el_term = two_el_term + abs(g(I, A, R, R) - G(I, R, R, A))
            end do
            w = abs(h(I, A)) + two_el_term
        end associate
    end function


    HElement_t(dp) elemental function h(I, A)
        !! Return the 1el integral \( h_{I, A) \)
        !!
        !! I and A are **spin** indices.
        !! Follows the definition of the purple book.
        integer, intent(in) :: I, A
        h = GetTMATEl(I, A)
    end function


    HElement_t(dp) elemental function g(I, A, J, B)
        integer, intent(in) :: I, A, J, B
        !! Return the 2el integral \( g_{I, A, J, B} \)

        !! I, A, J, and B are **spin** indices.
        !! Order follows the definition of the purple book (chemist's notation).
        !! \( g_{I, A, J, B} = < I J | 1 / r | A B > \)
        if (calc_spin_raw(I) == calc_spin_raw(A) .and. calc_spin_raw(J) == calc_spin_raw(B)) then
            g = get_umat_el(gtID(I), gtID(J), gtID(A), gtID(B))
        else
            g = 0._dp
        end if
    end function


    subroutine gen_all_excits_PC_Weighted_t(this, nI, n_excits, det_list)
        class(PC_Weighted_t), intent(in) :: this
        integer, intent(in) :: nI(nEl)
        integer, intent(out) :: n_excits
        integer(n_int), allocatable, intent(out) :: det_list(:,:)

        call gen_all_excits(this%GAS_spec, nI, n_excits, det_list, ic=1)
    end subroutine

end module gasci_singles_pc_weighted
