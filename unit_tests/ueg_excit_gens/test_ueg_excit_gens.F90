#include "macros.h"
program test_ueg_excit_gens

    use ueg_excit_gens, only: pick_uniform_elecs, calc_pgen_ueg, &
        create_ab_list_ueg
    use fruit, only: init_fruit, fruit_summary, fruit_finalize, &
        get_failed_count, run_test_case, assert_true, assert_equals

    implicit none

    integer :: failed_count

    call init_fruit()
    call ueg_excit_gens_driver()
    call fruit_summary()
    call fruit_finalize()

    call get_failed_count(failed_count)
    if (failed_count /= 0) stop -1

contains

    subroutine ueg_excit_gens_driver

        call run_test_case(pick_uniform_elecs_test, "pick_uniform_elecs_test")
        call run_test_case(create_ab_list_ueg_test, "create_ab_list_ueg_test")
        call run_test_case(calc_pgen_ueg_test, "calc_pgen_ueg_test")

    end subroutine ueg_excit_gens_driver

    subroutine pick_uniform_elecs_test
        use SystemData, only: ElecPairs
        use dSFMT_interface, only: dSFMT_init
        use constants, only: dp

        integer :: elecs(2)
        real(dp) :: pelec

        ElecPairs = 1

        print *, ""
        print *, "testing: pick_uniform_elecs "
        print *, "with necessary global data: "
        print *, "ElecPairs: ", ElecPairs
        print *, "dSFMT_init(): "
        call dSFMT_init(123)

        call pick_uniform_elecs(elecs, pelec)
        print *, "elecs: ", elecs

        call assert_equals([2,1], elecs, 2)
        call assert_equals(1.0_dp, pelec)

        ElecPairs = 4

        call pick_uniform_elecs(elecs, pelec)

        call assert_equals(1.0_dp / 4.0_dp, pelec)
        call assert_true(elecs(1) > elecs(2))

        ElecPairs = -1

    end subroutine pick_uniform_elecs_test

    subroutine create_ab_list_ueg_test
        ! i cant really test it efficiently since we would have to set
        ! up get_umat_el for the UEG.. which is a pain in the ass.
        use SystemData, only: G1, nBasis, nmaxx, nmaxy, nmaxz, tOrbECutoff
        use symexcitdatamod, only: KPointToBasisFn
        use bit_rep_data, only: NIfTot
        use constants, only: n_int, dp
        use procedure_pointers, only: get_umat_el

        integer(n_int), allocatable :: ilut(:)
        integer :: src(2)
        real(dp) :: cum_sum
        real(dp), allocatable :: cum_arr(:)

        get_umat_el => get_umat_test

        nBasis = 4
        allocate(G1(nBasis))
        nmaxx = 2
        nmaxy = 2
        nmaxz = 2
        tOrbECutoff = .false.
        niftot = 1
        allocate(KPointToBasisFn(-nmaxx:nmaxx, -nmaxy:nmaxy, -nmaxz:nmaxz, 2))

        allocate(ilut(0:niftot)); ilut = 0_n_int
        allocate(cum_arr(nBasis))

        G1(1)%k = [1,0,0]
        G1(2)%k = [0,1,0]
        G1(3)%k = [1,1,0]
        G1(4)%k = [0,0,0]

        ! i also have to set the G1%ms
        G1(1)%ms = -1
        G1(2)%ms = 1
        G1(3)%ms = -1
        G1(4)%ms = 1

        src = [1,2]

        KPointToBasisFn(0,1,0,2) = 2 ! i should get kb = [0,1,0]
        KPointToBasisFn(1,0,0,1) = 3
        KPointToBasisFn(0,0,0,2) = 4
        KPointToBasisFn(1,1,0,1) = 1

        call create_ab_list_ueg(ilut, src, cum_arr, cum_sum)

        call assert_equals([1.0_dp, 2.0_dp, 3.0_dp, 3.0_dp], cum_arr, 4)
        call assert_equals(3.0_dp, cum_sum)

        get_umat_el => null()
        nBasis = -1
        nmaxx = -1
        nmaxy = -1
        nmaxz = -2
        NIfTot = -1
        deallocate(KPointToBasisFn)
        deallocate(G1)

    end subroutine create_ab_list_ueg_test

    subroutine calc_pgen_ueg_test
        ! this is also hard to test here, since we also need to setup up
        ! get_umat_el for the ueg..
        ! first i have to write it...
        use constants, only: dp, n_int
        use bit_rep_data, only: niftot
        use SystemData, only: nel, nBasis, G1, nmaxx, nmaxy, nmaxz, ElecPairs, &
                              tOrbECutoff
        use symexcitdatamod, only: kpointtobasisfn
        use DetBitOps, only: EncodeBitDet
        use procedure_pointers, only: get_umat_el
        use dSFMT_interface, only: dSFMT_init

        integer :: ic = 1, ex(2,2)
        integer, allocatable :: nI(:)
        integer(n_int), allocatable :: ilut(:)


        ! use uniform matrix elements for testing(see below!)
        get_umat_el => get_umat_test
        nel = 2
        niftot = 1
        ElecPairs = 1
        nBasis = 4
        allocate(nI(nel)); nI = [1,2]
        allocate(ilut(0:niftot))
        call EncodeBitDet(nI, ilut)

        allocate(G1(nBasis))
        nmaxx = 2
        nmaxy = 2
        nmaxz = 2
        tOrbECutoff = .false.
        allocate(KPointToBasisFn(-nmaxx:nmaxx, -nmaxy:nmaxy, -nmaxz:nmaxz, 2))

        G1(1)%k = [1,0,0]
        G1(2)%k = [0,1,0]
        G1(3)%k = [1,1,0]
        G1(4)%k = [0,0,0]

        ! i also have to set the ms value in G1
        G1(1)%ms = -1
        G1(2)%ms = 1
        G1(3)%ms = -1
        G1(4)%ms = 1

        KPointToBasisFn(0,1,0,2) = 2 ! i should get kb = [0,1,0]
        KPointToBasisFn(1,0,0,1) = 3
        KPointToBasisFn(0,0,0,2) = 4
        KPointToBasisFn(1,1,0,1) = 1

        ex(1,:) = [1,2]
        ex(2,:) = [3,4]

        print *, ""
        print *, "testing: calc_pgen_ueg() "
        print *, "with necessary global data: "
        ! there is alot of setup necessary..

        call dSFMT_init(123)

        call assert_equals(0.0_dp, calc_pgen_ueg(ilut, ex, ic))
        ic = 2
        ! we still have spin-opposite excitations with cancelling matrix
        ! elements.. (i guess..)
        ! no i was just doing this wrong beforehand.. fix it now!
        call assert_equals(1.0_dp, calc_pgen_ueg(ilut, ex, ic))
        ! if we fake a (1,2) -> (1,2) excitation it should be fine as
        ! above

        ilut = 0_n_int
        ex(2,:) = [1,2]

        call assert_equals(1.0_dp/3.0_dp, calc_pgen_ueg(ilut, ex, ic))

        ! although this test is dangerous, since actually orb_b > orb_a is
        ! enforced in the excitation generator.. but anyway..
        ! hm.. but why does the function not capture that??
        ex(2,:) = [2,1]
        call assert_equals(1.0_dp/3.0_dp, calc_pgen_ueg(ilut, ex, ic))

        get_umat_el => null()
        nel = -1
        NIfTot = -1
        ElecPairs = -1
        nBasis = -1
        deallocate(G1)
        deallocate(KPointToBasisFn)

    end subroutine calc_pgen_ueg_test

    pure function get_umat_test(i, j, k, l) result(hel)
        use constants, only: dp
        implicit none
        integer, intent(in) :: i, j, k, l
        HElement_t(dp) :: hel

        hel = 1.0_dp

        unused_var(i); unused_var(j); unused_var(k); unused_var(l)
    end function get_umat_test

end program test_ueg_excit_gens
