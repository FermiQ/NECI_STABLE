#include "macros.h"

module unit_test_helper_excitgen
    use constants
    use read_fci, only: readfciint, initfromfcid, fcidump_name
    use shared_memory_mpi, only: shared_allocate_mpi, shared_deallocate_mpi
    use IntegralsData, only: UMat, umat_win
    use Integrals_neci, only: IntInit, get_umat_el_normal
    use procedure_pointers, only: get_umat_el, generate_excitation
    use SystemData, only: nel, nBasis, UMatEps, tStoreSpinOrbs, tReadFreeFormat, &
                          tReadInt, t_pcpp_excitgen, tUHF, tMolpro
    use sort_mod
    use gasci, only: GASSpec_t
    use System, only: SysInit, SetSysDefaults, SysCleanup
    use Parallel_neci, only: MPIInit, MPIEnd, mpi_comm_rank, mpi_comm_world
    use UMatCache, only: GetUMatSize, tTransGTID, setupUMat2d_dense
    use OneEInts, only: Tmat2D
    use bit_rep_data, only: NIfTot, nifd, extract_sign, IlutBits
    use bit_reps, only: encode_sign, decode_bit_det, init_bit_rep
    use DetBitOps, only: EncodeBitDet, DetBitEq, GetBitExcitation
    use SymExcit3, only: countExcitations3, GenExcitations3
    use FciMCData, only: pSingles, pDoubles, pParallel, ilutRef, projEDet, &
                         fcimc_excit_gen_store
    use SymExcitDataMod, only: excit_gen_store_type, scratchSize
    use GenRandSymExcitNUMod, only: init_excit_gen_store, construct_class_counts
    use Calc, only: CalcInit, CalcCleanup, SetCalcDefaults
    use dSFMT_interface, only: dSFMT_init, genrand_real2_dSFMT
    use Determinants, only: DetInit, DetPreFreezeInit, get_helement, DefDet, tDefineDet
    use util_mod, only: stop_all, operator(.div.)
    use orb_idx_mod, only: SpinProj_t, calc_spin_raw, sum
    better_implicit_none
    private
    public :: test_excitation_generator, generate_uniform_integrals, FciDumpWriter_t, &
        init_excitgen_test, generate_random_integrals, set_ref, free_ref, calc_pgen, &
        finalize_excitgen_test, InputWriter_t, Writer_t, delete_file, &
        RandomFcidumpWriter_t
    abstract interface
        function calc_pgen_t(nI, ilutI, ex, ic, ClassCount2, ClassCountUnocc2) result(pgen)
            use constants
            use SymExcitDataMod, only: scratchSize
            use bit_rep_data, only: NIfTot
            use SystemData, only: nel
            implicit none
            integer, intent(in) :: nI(nel)
            integer(n_int), intent(in) :: ilutI(0:NIfTot)
            integer, intent(in) :: ex(2, 2), ic
            integer, intent(in) :: ClassCount2(ScratchSize), ClassCountUnocc2(ScratchSize)

            real(dp) :: pgen

        end function calc_pgen_t
    end interface

    interface RandomFcidumpWriter_t
        module procedure construct_RandomFciDumpWriter_t, construct_GAS_RandomFciDumpWriter_t
    end interface

    procedure(calc_pgen_t), pointer :: calc_pgen

    type, abstract :: Writer_t
        ! I would like it to be:
        ! character(:), allocatable :: filepath
        ! but for gfortran <= 4.8.5 it has to be
        character(512) :: filepath
    contains
        procedure :: write
        procedure(to_unit_writer_t), deferred :: write_to_unit
    end type

    abstract interface
        subroutine to_unit_writer_t(this, iunit)
            import :: Writer_t
            implicit none
            class(Writer_t), intent(in) :: this
            integer, intent(in) :: iunit
        end subroutine
    end interface

    type, abstract, extends(Writer_t) :: FciDumpWriter_t
    end type

    type, extends(FciDumpWriter_t) :: RandomFcidumpWriter_t
        integer :: n_el, n_spat_orb
        real(dp) :: sparse, sparseT
        type(SpinProj_t) :: total_ms
        logical :: uhf, hermitian
    contains
        procedure :: write_to_unit => RandomFcidumpWriter_t_write
    end type

    type, abstract, extends(Writer_t) :: InputWriter_t
    end type

contains

    subroutine test_excitation_generator(sampleSize, pTot, pNull, numEx, nFound, t_calc_pgen, start_nI)
        ! Test an excitation generator by creating a large number of excitations and
        ! compare the generated excits with a precomputed list of all excitations
        ! We thus make sure that
        !   a) all possible excitations are generated with some weight
        !   b) no invalid excitations are obtained
        integer, intent(in) :: sampleSize
        real(dp), intent(out) :: pTot, pNull
        integer, intent(out) :: numEx, nFound
        logical, intent(in) :: t_calc_pgen
        integer, intent(in), optional :: start_nI(nEl)
        integer :: nI(nel), nJ(nel)
        integer :: i, ex(2, maxExcit), exflag
        integer(n_int) :: ilut(0:NIfTot), ilutJ(0:NIfTot)
        real(dp) :: pgen
        logical :: tPar, tAllExFound, tFound
        integer :: j, nSingles, nDoubles
        integer(n_int), allocatable :: allEx(:, :)
        real(dp) :: pgenArr(lenof_sign)
        real(dp) :: matel, matelN, pgenCalc
        logical :: exDoneDouble(0:nBasis, 0:nBasis, 0:nBasis, 0:nBasis)
        logical :: exDoneSingle(0:nBasis, 0:nBasis)
        integer :: ic, part, nullExcits
        integer :: ClassCountOcc(scratchSize), ClassCountUnocc(scratchSize)
        integer(int64) :: start, finish, rate
        character(*), parameter :: t_r = "test_excitation_generator"
        HElement_t(dp) :: HEl
        exDoneDouble = .false.
        exDoneSingle = .false.
        call system_clock(count_rate=rate)

        ! some starting det - do NOT use the reference for the pcpp test, that would
        ! defeat the purpose
        if (present(start_nI)) then
            nI = start_nI
        else
            do i = 1, nel
                if (2 * i < nBasis) then
                    nI(i) = 2 * i - mod(i, 2)
                else
                    nI(i) = i
                end if
            end do
            call sort(nI)
        end if

        call EncodeBitDet(nI, ilut)

        exflag = 3
        ex = 0
        ! create a list of all singles and doubles for reference
        call CountExcitations3(nI, exflag, nSingles, nDoubles)
        allocate(allEx(0:(NIfTot + 1), nSingles + nDoubles), source=0_n_int)
        numEx = 0
        tAllExFound = .false.
        do
            call GenExcitations3(nI, ilut, nJ, exflag, ex(:,1:2), tPar, tAllExFound, .false.)
            if (tAllExFound) exit
            call encodeBitDet(nJ, ilutJ)
            numEx = numEx + 1
            allEx(0:nifd, numEx) = ilutJ(0:nifd)
        end do
        call sort(nI)

        write(stdout, *) "In total", numEx, "excits, (", nSingles, nDoubles, ")"
        write(stdout, *) "Exciting from", nI

        call EncodeBitDet(nI, ilut)

        ! set the biases for excitation generation
        pParallel = 0.5_dp
        pSingles = 0.1_dp
        pDoubles = 0.9_dp
        pNull = 0.0_dp
        nullExcits = 0
        call system_clock(start)
        do i = 1, sampleSize
            fcimc_excit_gen_store%tFilled = .false.
            call generate_excitation(nI, ilut, nJ, ilutJ, exFlag, ic, ex, tPar, pgen, HEl, fcimc_excit_gen_store, part)
            ! lookup the excitation
            tFound = .false.
            do j = 1, numEx
                if (DetBitEQ(ilutJ, allEx(:, j))) then
                    pgenArr = pgen
                    call encode_sign(allEx(:, j), pgenArr)
                    ! increase its counter by 1
                    allEx(NIfTot + 1, j) = allEx(NIfTot + 1, j) + 1
                    tFound = .true.
                    exit
                end if
            end do
            ! if it was not found, and is not marked as invalid, we have a problem: this is not
            ! an excitaion
            if (.not. tFound .and. .not. nJ(1) == 0) then
                call decode_bit_det(nJ, ilutJ)
                write(stdout, *) "Created excitation", nJ
                call stop_all(t_r, "Error: Invalid excitation")
            end if
            ! check if the generated excitation is invalid, if it is, mark this specific constellation
            ! so we do not double-count when calculating pNull
            if (nJ(1) == 0) then
                nullExcits = nullExcits + 1
                if (ic == 2) then
                    if (.not. exDoneDouble(ex(1, 1), ex(1, 2), ex(2, 1), ex(2, 2))) then
                        exDoneDouble(ex(1, 1), ex(1, 2), ex(2, 1), ex(2, 2)) = .true.
                        pNull = pNull + pgen
                    end if
                else if (ic == 1) then
                    if (.not. exDoneSingle(ex(1, 1), ex(1, 2))) then
                        exDoneSingle(ex(1, 1), ex(1, 2)) = .true.
                        pNull = pNull + pgen
                    end if
                end if
            end if
        end do
        call system_clock(finish)

        ! check that all excits have been generated and all pGens are right
        ! probability normalization
        pTot = pNull
        matelN = 0.0
        do i = 1, numEx
            call decode_bit_det(nJ, allEx(:, i))
            matelN = matelN + abs(get_helement(nI, nJ))
        end do
        nFound = 0
        ! class counts might be required for comparing the pgen
        call construct_class_counts(nI, classCountOcc, classCountUnocc)
        do i = 1, numEx
            call extract_sign(allEx(:, i), pgenArr)
            call decode_bit_det(nJ, allEx(:, i))
            matel = get_helement(nI, nJ)
            if (pgenArr(1) > eps) then
                nFound = nFound + 1
                write(stdout, *) i, pgenArr(1), real(allEx(NIfTot + 1, i)) / real(sampleSize), &
                    abs(matel) / (pgenArr(1) * matelN)
                ! compare the stored pgen to the directly computed one
                if (t_calc_pgen) then
                    if (i > nSingles) then
                        ic = 2
                    else
                        ic = 1
                    end if
                    ex(1, 1) = 2
                    call getBitExcitation(ilut, allEx(:, i), ex, tPar)
                    pgenCalc = calc_pgen(nI, ilut, ex, ic, ClassCountOcc, ClassCountUnocc)
                    if (abs(pgenArr(1) - pgenCalc) > eps) then
                        write(stdout, *) "Stored: ", pgenArr(1), "calculated:", pgenCalc
                        write(stdout, *) "For excit", nJ
                        call stop_all(t_r, "Incorrect pgen")
                    end if
                end if
            else
                ! excitations with zero matrix element are not required to be found
                if (abs(matel) < eps) then
                    nFound = nFound + 1
                else if (i < nSingles) then
                    write(stdout, *) "Unfound single excitation", nJ
                else
                    write(stdout, *) "Unfound double excitation", nJ, matel
                end if
            end if
            pTot = pTot + pgenArr(1)
        end do
        write(stdout, *) "Total prob. ", pTot
        write(stdout, *) "pNull ", pNull
        write(stdout, *) "Null ratio", nullExcits / real(sampleSize)
        write(stdout, *) "In total", numEx, "excitations"
        write(stdout, *) "With", nSingles, "single excitation"
        write(stdout, *) "Found", nFound, "excitations"
        write(stdout, *) 'Elapsed Time in seconds:', dble(finish - start) / dble(rate)
        write(stdout, *) 'Elapsed Time in micro seconds per excitation:', dble(finish - start) * 1e6_dp / dble(sampleSize* rate)

    end subroutine test_excitation_generator

    !------------------------------------------------------------------------------------------!

    subroutine init_excitgen_test(ref_det, fcidump_writer, setdefaults)
        ! mimic the initialization of an FCIQMC calculation to the point where we can generate
        ! excitations with a weighted excitgen
        ! This requires setup of the basis, the symmetries and the integrals
        integer, intent(in) :: ref_det(:)
        class(FciDumpWriter_t), intent(in) :: fcidump_writer
        logical, optional, intent(in) :: setdefaults
            !! whether or not to set the default flags in this function
            !! IMO this should be done using test fixtures and not in this function,
            !! but much of the existing tests rely on it being here
        logical :: setdefaults_
        integer :: nBasisMax(5, 3), lms
        integer(int64) :: umatsize
        real(dp) :: ecore
        character(*), parameter :: this_routine = 'init_excitgen_test'
        integer, parameter :: seed = 25

        def_default(setdefaults_, setdefaults, .true.)

        umatsize = 0
        nel = size(ref_det)

        IlutBits%len_orb = 0
        IlutBits%ind_pop = 1
        IlutBits%len_pop = 1
        IlutBits%len_tot = 2

        nifd = 0
        NIfTot = 2

        fcidump_name = "FCIDUMP"
        UMatEps = 1.0e-8
        if (tUHF .and. tMolpro) then
            tStoreSpinOrbs = .true.
        else
            tStoreSpinOrbs = .false.
        end if
        tTransGTID = .false.
        tReadFreeFormat = .true.

        call dSFMT_init(seed)

        if (setdefaults_) then
            call SetCalcDefaults()
            call SetSysDefaults()
        end if
        tReadInt = .true.

        call fcidump_writer%write()

        get_umat_el => get_umat_el_normal

        call initfromfcid(nel, nbasismax, nBasis, lms, .false.)

        call GetUMatSize(nBasis, umatsize)

        allocate(TMat2d(nBasis, nBasis))

        call shared_allocate_mpi(umat_win, umat, [umatsize])

        UMat = h_cast(0._dp)
        call readfciint(UMat, umat_win, nBasis, ecore)

        ! init the umat2d storage
        call setupUMat2d_dense(nBasis)

        call SysInit()
        ! required: set up the spin info

        call DetInit()
        ! call SpinOrbSymSetup()

        tDefineDet = .true.
        DefDet = ref_det
        call DetPreFreezeInit()

        call CalcInit()

        call set_ref()

        t_pcpp_excitgen = .true.
        call init_excit_gen_store(fcimc_excit_gen_store)

        call init_bit_rep()
    end subroutine init_excitgen_test

    !------------------------------------------------------------------------------------------!

    subroutine finalize_excitgen_test()
        deallocate(TMat2D)
        call shared_deallocate_mpi(umat_win, UMat)
        call CalcCleanup()
        call SysCleanup()
    end subroutine finalize_excitgen_test

    !------------------------------------------------------------------------------------------!

    ! generate an FCIDUMP file with random numbers with a given sparsity and write to iunit
    subroutine generate_random_integrals(iunit, n_el, n_spat_orb, sparse, sparseT, &
            total_ms, uhf, hermitian)
        integer, intent(in) :: iunit, n_el, n_spat_orb
        real(dp), intent(in) :: sparse, sparseT
        type(SpinProj_t), intent(in) :: total_ms
        logical, optional, intent(in) :: uhf, hermitian
            !! specify if the FCIDUMP is UHF
            !! specify if the FCIDUMP is hermitian
            !!
            !! @note if uhf then assume
            !! num spin-up basis functions = num spin-down basis functions
        logical :: uhf_, hermitian_
        integer :: i, j, k, l, j_end, l_end
        real(dp) :: r, matel
        ! we get random matrix elements from the cauchy-schwartz inequalities, so
        ! only <ij|ij> are random -> random 2d matrix
        real(dp), allocatable :: umatRand(:, :)
        integer :: norb ! n_spin_orb or n_spat_orb

        def_default(hermitian_, hermitian, .true.)
        ! UHF FCIDUMPs have six sectors:
        ! two-body integrals: up-up, down-down, up-down
        ! one-body integrals: up, down
        ! nuclear repulsion
        ! delimiter: 0.0000000000000000E+00   0   0   0   0
        def_default(uhf_, uhf, .false.)

        norb = merge(2*n_spat_orb, n_spat_orb, uhf_)
        allocate(umatRand(norb, norb), source=0.0_dp)

        do i = 1, norb
            do j = 1, norb
                r = genrand_real2_dSFMT()
                if (r < sparse) then
                    umatRand(i, j) = r * r
                    if (hermitian_) then
                        umatRand(j, i) = umatRand(i, j)
                    else
                        ! have the conjugate be similar
                        umatRand(j, i) = (1 + genrand_real2_dSFMT() * 0.1) * umatRand(i, j)
                    endif
                end if
            end do
        end do

        ! write the canonical FCIDUMP header (norb here is num spatial orbitals)
        write(iunit, *) "&FCI NORB=", n_spat_orb, ",NELEC=", n_el, "MS2=", total_ms%val, ","
        write(iunit, "(A)", advance="no") "ORBSYM="
        do i = 1, n_spat_orb
            write(iunit, "(A)", advance="no") "1,"
        end do
        write(iunit, *)
        write(iunit, *) "ISYM=1,"
        write(iunit, *) "&END"
        ! generate random 4-index integrals with a given sparsity
        ! then
        ! generate random 2-index integrals with a given sparsity
        if(uhf_) then
            ! three 4-index sectors, so three calls to write_4index
            call write_4index(1, n_spat_orb, 1, n_spat_orb, hermitian_)
            write(iunit, *) 0.0000000000000000E+00, 0, 0, 0, 0 ! delimiter
            ! we can keep using the spatial orbitals as indices because of the
            ! partitioning of the dump file
            call write_4index(1, n_spat_orb, 1, n_spat_orb, hermitian_)
            write(iunit, *) 0.0000000000000000E+00, 0, 0, 0, 0
            call write_4index(1, n_spat_orb, 1, n_spat_orb, hermitian_)
            write(iunit, *) 0.0000000000000000E+00, 0, 0, 0, 0
            call write_2index(1, n_spat_orb, hermitian_)
            write(iunit, *) 0.0000000000000000E+00, 0, 0, 0, 0
            call write_2index(1, n_spat_orb, hermitian_)
            write(iunit, *) 0.0000000000000000E+00, 0, 0, 0, 0
            ! then would come the nuclear repulsion
        else ! .not. uhf_
            call write_4index(1, norb, 1, norb, hermitian_)
            call write_2index(1, n_spat_orb, hermitian_)
        endif

    contains
        subroutine write_4index(i_start, i_end, k_start, k_end, hermitian)
            ! i_end corresponds to electron 1, j_end to electron 2
            integer, intent(in) :: i_start, i_end, k_start, k_end
            logical, intent(in) :: hermitian
            integer :: k_start_
            do i = i_start, i_end
                ! j_end = i if hermitian, else i_end
                j_end = merge(i, i_end, hermitian)
                do j = 1, j_end
                    ! if the Hamiltonian *is* Hermitian, we may flip these indices
                    k_start_ = merge(i, k_start, hermitian)
                    do k = k_start_, k_end
                        l_end = merge(k, k_end, hermitian)
                        do l = 1, l_end
                            matel = sqrt(umatRand(i, j) * umatRand(k, l))
                            if (matel > eps) write(iunit, *) matel, i, j, k, l
                        end do
                    end do
                end do
            end do
        end subroutine write_4index

        subroutine write_2index(i_start, i_end, hermitian)
            integer, intent(in) :: i_start, i_end
            logical, intent(in) :: hermitian
            do i = i_start, i_end
                j_end = merge(i, i_end, hermitian)
                do j = i_start, j_end
                    r = genrand_real2_dSFMT()
                    if (r < sparseT) then
                        write(iunit, *) r, i, j, 0, 0
                    end if
                end do
            end do
        end subroutine write_2index

    end subroutine generate_random_integrals

    !------------------------------------------------------------------------------------------!
    subroutine generate_uniform_integrals

        use SystemData, only: nSpatOrbs, nel, lms

        integer :: i, j, k, l, iunit

        open (newunit=iunit, file="FCIDUMP")
        write(iunit, *) "&FCI NORB=", nSpatOrbs, ",NELEC=", nel, "MS2=", lms, ","
        write(iunit, "(A)", advance="no") "ORBSYM="
        do i = 1, nSpatOrbs
            write(iunit, "(A)", advance="no") "1,"
        end do
        write(iunit, *)
        write(iunit, *) "ISYM=1,"
        write(iunit, *) "&END"

        do i = 1, nSpatOrbs
            do j = 1, nSpatOrbs
                do l = 1, nSpatOrbs
                    do k = 1, nSpatOrbs
                        write(iunit, *) h_cast(1.0_dp), i, j, k, l
                    end do
                end do
            end do
        end do
        do i = 1, nSpatOrbs
            do j = i, nSpatOrbs
                write(iunit, *) h_cast(1.0_dp), i, j, 0, 0
            end do
        end do

        write(iunit, *) h_cast(0.0_dp), 0, 0, 0, 0

        close (iunit)

    end subroutine generate_uniform_integrals

    !------------------------------------------------------------------------------------------!

    ! set the reference to the determinant with the first nel orbitals occupied
    subroutine set_ref()
        integer :: i

        projEDet = reshape([(i + 2, i = 1, nel)], [nel, 1])
        if (allocated(ilutRef)) deallocate(ilutRef)
        allocate(ilutRef(0:NifTot, 1))
        call encodeBitDet(projEDet(:, 1), ilutRef(:, 1))
    end subroutine

    subroutine free_ref()
        deallocate(ilutRef)
        deallocate(projEDet)
    end subroutine free_ref

    subroutine delete_file(path)
        character(*), intent(in) :: path
        integer :: file_id

        open (newunit=file_id, file=path, status='old')
        close (file_id, status='delete')
    end subroutine

    subroutine RandomFcidumpWriter_t_write(this, iunit)
        class(RandomFcidumpWriter_t), intent(in) :: this
        integer, intent(in) :: iunit
        call generate_random_integrals(iunit, &
            this%n_el, this%n_spat_orb, this%sparse, this%sparseT, &
            this%total_ms, this%uhf, this%hermitian)
    end subroutine

    pure function construct_RandomFciDumpWriter_t(n_spat_orbs, nI, sparse, sparseT, filepath, uhf, hermitian) result(res)
        integer, intent(in) :: n_spat_orbs, nI(:)
        real(dp), intent(in) :: sparse, sparseT
        character(*), optional, intent(in) :: filepath
        logical, optional, intent(in) :: uhf, hermitian
        class(RandomFcidumpWriter_t), allocatable :: res

        character(len=:), allocatable :: filepath_
        logical :: uhf_, hermitian_
        def_default(uhf_, uhf, .false.)
        def_default(hermitian_, hermitian, .true.)
        def_default(filepath_, filepath, 'FCIDUMP')

        res = RandomFcidumpWriter_t( &
                    filepath=filepath_, &
                    n_El=size(nI), n_spat_orb=n_spat_orbs, &
                    sparse=sparse, sparseT=sparseT, total_ms=sum(calc_spin_raw(nI)), &
                    uhf=uhf_, hermitian=hermitian_&
                )
    end function

    pure function construct_GAS_RandomFciDumpWriter_t(GAS_spec, nI, sparse, sparseT, filepath, uhf, hermitian) result(res)
        class(GASSpec_t), intent(in) :: GAS_spec
        integer, intent(in) :: nI(:)
        real(dp), intent(in) :: sparse, sparseT
        character(*), optional, intent(in) :: filepath
        logical, optional, intent(in) :: uhf, hermitian
        class(RandomFcidumpWriter_t), allocatable :: res

        res = RandomFcidumpWriter_t( &
                    GAS_spec%n_spin_orbs() .div. 2, nI, &
                    sparse=sparse, sparseT=sparseT, &
                    filepath=filepath, &
                    uhf=uhf, hermitian=hermitian&
                )
    end function

    subroutine write(this)
        class(Writer_t), intent(in) :: this
        integer :: file_id
        open(newunit=file_id, file=this%filepath)
            call this%write_to_unit(file_id)
        close(file_id)
    end subroutine

end module unit_test_helper_excitgen
