program test_tc_freeze
    use constants, only: dp, stdout
    use Parallel_neci, only: MPIInit, MPIEnd, iProcIndex_intra
    use fruit, only: init_fruit, fruit_summary, fruit_finalize, &
                     get_failed_count, run_test_case, assert_true
    use unit_test_helper_excitgen, only: generate_random_integrals, &
        RandomFciDumpWriter_t, init_excitgen_test
    use util_mod, only: operator(.isclose.), operator(.div.), stop_all, &
        get_free_unit
    use sltcnd_mod, only: initSltCndPtr, dyn_sltcnd_excit
    use SystemData, only: t_mol_3_body, ECore, nEl
    use IntegralsData, only: nFrozen, UMAT
    use OneEInts, only: TMat2D
    use excitation_types, only: Excite_0_t, Excite_1_t, Excite_2_t, Excitation_t
    use orb_idx_mod, only: SpinProj_t
    use LMat_mod, only: readLMat, freeLMat
    use excitation_types, only: Excite_0_t, Excite_1_t, Excite_2_t

    implicit none
    integer, parameter :: n_con = 10
    integer, parameter :: n_f = 4
    integer, parameter :: nI_ref(n_con) = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10]
    integer, parameter :: nI_ref_frozen(n_con - n_f) = nI_ref(1:n_con - n_f)

    call MPIInit(.false.)
    call init_fruit()
    call tc_freeze_test_driver()
    call fruit_summary()
    call fruit_finalize()
    block
        integer :: failed_count
        call get_failed_count(failed_count)
        if (failed_count /= 0) call stop_all('test_tc_freeze', 'failed_tests')
    end block
    call MPIEnd(.false.)

contains

    subroutine tc_freeze_test_driver()
        type(Excite_0_t) :: exc_0
        type(Excite_1_t) :: exc_1
        type(Excite_2_t) :: exc_2
        integer :: i

        ! Initialize the matrix element calculation
        associate (ref_det => [(i, i=1, n_con)])
            call init_excitgen_test(ref_det, &
                RandomFcidumpWriter_t(&
                    14, ref_det, sparse=0.9_dp, sparseT=0.1_dp) &
            )
        end associate
        t_mol_3_body = .true.
        call initSltCndPtr()

        write(stdout, *) "Checking diagonal matrix elements"

        ! Test the diagonal elements
        call test_freeze([1, 1, 2, 2, 1, 1], exc_0)
        call test_freeze([1, 1, 2, 1, 1, 2], exc_0)
        call test_freeze([1, 2, 2, 1, 1, 1], exc_0)
        call test_freeze([1, 1, 3, 1, 1, 3], exc_0)
        call test_freeze([1, 1, 3, 1, 3, 1], exc_0)
        call test_freeze([1, 3, 3, 1, 1, 1], exc_0)
        call test_freeze([1, 1, 1, 1, 3, 3], exc_0)
        call test_freeze([1, 2, 3, 1, 2, 3], exc_0)
        call test_freeze([1, 2, 3, 1, 2, 3], exc_0)
        call test_freeze([1, 2, 3, 2, 1, 3], exc_0)
        call test_freeze([2, 2, 3, 1, 1, 3], exc_0)
        call test_freeze([2, 3, 2, 1, 1, 3], exc_0)
        call test_freeze([1, 3, 4, 1, 3, 4], exc_0)
        call test_freeze([1, 3, 4, 3, 1, 4], exc_0)
        call test_freeze([1, 3, 4, 4, 1, 3], exc_0)
        call test_freeze([3, 3, 4, 1, 1, 4], exc_0)
        call test_freeze([1, 3, 3, 4, 1, 4], exc_0)

        write(stdout, *) "Checking single excitaion matrix elements"

        ! Test the single excitation matrix elements
        exc_1 = Excite_1_t(5, 21)
        call test_freeze([1, 1, 3, 1, 1, 11], exc_1)
        call test_freeze([1, 1, 3, 11, 1, 1], exc_1)
        call test_freeze([11, 1, 3, 1, 1, 1], exc_1)
        call test_freeze([3, 1, 11, 1, 1, 1], exc_1)
        call test_freeze([1, 1, 1, 11, 1, 3], exc_1)

        call test_freeze([1, 2, 3, 1, 2, 11], exc_1)
        call test_freeze([1, 2, 3, 2, 1, 11], exc_1)
        call test_freeze([1, 2, 3, 1, 11, 2], exc_1)
        call test_freeze([1, 2, 3, 11, 1, 2], exc_1)
        call test_freeze([1, 1, 3, 11, 2, 2], exc_1)
        call test_freeze([11, 2, 3, 1, 1, 2], exc_1)
        call test_freeze([1, 2, 11, 3, 1, 2], exc_1)
        call test_freeze([1, 2, 11, 1, 2, 3], exc_1)
        call test_freeze([11, 2, 2, 1, 1, 3], exc_1)

        write(stdout, *) "Checking double excitaion matrix elements"

        ! Test the double excitation matrix elements
        exc_2 = Excite_2_t(5, 21, 7, 23)
        call test_freeze([1, 3, 4, 1, 11, 12], exc_2)
        call test_freeze([1, 11, 4, 1, 3, 12], exc_2)
        call test_freeze([1, 3, 4, 12, 1, 11], exc_2)
        call test_freeze([12, 3, 4, 1, 1, 11], exc_2)
        call test_freeze([1, 3, 4, 1, 12, 11], exc_2)
        call test_freeze([1, 3, 4, 11, 1, 12], exc_2)
        call test_freeze([11, 3, 4, 1, 1, 12], exc_2)
        call test_freeze([1, 3, 11, 1, 12, 4], exc_2)
        call test_freeze([11, 1, 4, 1, 3, 12], exc_2)
        call test_freeze([12, 3, 11, 1, 1, 4], exc_2)
        exc_2 = Excite_2_t(5, 11, 6, 12)
        call test_freeze([1, 3, 3, 1, 11, 11], exc_2)
        call test_freeze([1, 3, 3, 11, 1, 11], exc_2)
        call test_freeze([1, 3, 11, 1, 11, 3], exc_2)
        call test_freeze([1, 3, 3, 11, 11, 1], exc_2)
        call test_freeze([11, 3, 3, 1, 1, 11], exc_2)
        call test_freeze([11, 1, 3, 1, 3, 11], exc_2)

    end subroutine tc_freeze_test_driver

    subroutine test_freeze(inds, exc)
        integer, intent(in) :: inds(6)
        class(Excitation_t), intent(in) :: exc
        class(Excitation_t), allocatable :: exc_frozen
        logical :: t_par
        real(dp) :: e_ref, e_freeze

        t_par = .false.
        call reset_ints()
        call write_single_tcdump(inds)
        nFrozen = 0
        call readLMat()
        e_ref = dyn_sltcnd_excit(nI_ref, exc, t_par)
        call freeLMat()
        nFrozen = 4
        call readLMat()
        nel = nel - nFrozen
        select type (exc)
        type is (Excite_1_t)
            allocate(Excite_1_t :: exc_frozen)
            exc_frozen = Excite_1_t(exc%val- nFrozen)
        type is (Excite_2_t)
            allocate(Excite_2_t :: exc_frozen)
            exc_frozen = Excite_2_t(exc%val - nFrozen)
        class default
            exc_frozen = exc
        end select
        e_freeze = dyn_sltcnd_excit(nI_ref_frozen, exc_frozen, t_par) + ECore
        nel = nel + nFrozen
        call freeLMat()

        call assert_true(e_freeze .isclose. e_ref)
        write(stdout, *) e_freeze, e_ref
    end subroutine test_freeze

    subroutine write_single_tcdump(inds)
        integer, intent(in) :: inds(6)
        integer :: iunit

        iunit = get_free_unit()
        open(iunit, file="TCDUMP", status='replace')

        write(iunit, *) 1.0, inds
        close(iunit)
    end subroutine write_single_tcdump

    subroutine reset_ints()
        if (iProcIndex_intra == 0) then
            UMat = 0.0_dp
        end if
        TMat2D = 0.0_dp
        ECore = 0.0_dp

    end subroutine reset_ints

end program test_tc_freeze
