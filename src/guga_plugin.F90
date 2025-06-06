#include "macros.h"
module guga_plugin
    use dSFMT_interface, only: dSFMT_init
    use constants, only: dp, n_int, int64
    use bit_rep_data, only: NIfTot
    use SystemData, only: nEl, tReadInt, eCore, lms, &
        nBasis, nSpatOrbs, nbasismax, stot, &
        tgen_guga_weighted, tgen_sym_guga_mol, &
        tGUGA, tReadFreeFormat, tStoreSpinOrbs
    use FCimcData, only: tFillingStochRDMOnFly
    use read_fci, only: readfciint, fcidump_name, initfromfcid, &
        UMatEps
    use guga_data, only: ExcitationInformation_t
    use guga_init, only: init_guga
    use guga_bitRepOps, only: CSF_Info_t
    use DetBitOps, only: EncodeBitDet
    use guga_matrixElements, only: calcDiagMatEleGuga_nI, calc_guga_matrix_element
    use OneEInts, only: TMat2d
    use UMatCache, only: tTransGTID, GetUMatSize, tumat2d, umat2d, tdeferred_umat2d
    use Calc, only: SetCalcDefaults, CalcInit, CalcCleanup
    use System, only: SetSysDefaults, SysInit, SysCleanup
    use OneEInts, only: TMat2d
    use shared_memory_mpi, only: shared_allocate_mpi, shared_deallocate_mpi
    use IntegralsData, only: umat_win, umat
    use DetCalc, only: DetCalcInit
    use LoggingData, only: tRDMonfly, tExplicitAllRDM
    use shared_memory_mpi, only: shared_allocate_mpi
    use IntegralsData, only: umat_win, umat
    use Parallel_neci, only: MPIInit, clean_parallel
    use LoggingData, only: tRDMonfly, tExplicitAllRDM
    use Integrals_neci, only: get_umat_el_normal
    use procedure_pointers, only: get_umat_el
    use Determinants, only: DetPreFreezeInit, DetInit, DetCleanup
    use unit_test_helper_excitgen, only: generate_uniform_integrals
    use bit_reps, only: init_bit_rep
    implicit none
    private
    public :: init_guga_plugin, finalize_guga_plugin, guga_matel

contains

    subroutine init_guga_plugin(fcidump_path, stot_, t_testmode_, nel_, nbasis_, &
        nSpatOrbs_)
        character(*), intent(in) :: fcidump_path
        integer, intent(in), optional :: stot_
        logical, intent(in), optional :: t_testmode_
        integer, intent(in), optional :: nel_
        integer, intent(in), optional :: nbasis_
        integer, intent(in), optional :: nSpatOrbs_
        logical :: t_testmode
        integer(int64) :: umatsize
        def_default(t_testmode, t_testmode_, .false.)
        def_default(nel, nel_, -1)
        def_default(nbasis, nbasis_, 0)
        def_default(nSpatOrbs, nSpatOrbs_, 0)
        def_default(stot, stot_, 0)

        umatsize = 0
        lms = 0
        tGUGA = .true.

        tRDMonfly = .true.
        tFillingStochRDMOnFly = .true.
        call init_bit_rep()

        tGen_sym_guga_mol = .true.
        tgen_guga_weighted = .true.
        tdeferred_umat2d = .true.
        tumat2d = .false.
        ! set this to false before the init to setup all the ilut variables
        tExplicitAllRDM = .false.

        fcidump_name = fcidump_path
        UMatEps = 1.0e-8
        tStoreSpinOrbs = .false.
        tTransGTID = .false.
        tReadFreeFormat = .true.

        call MPIInit(.false.)

        call dSFMT_init(8)

        call SetCalcDefaults()
        call SetSysDefaults()
        tReadInt = .true.

        if(t_testmode) call generate_uniform_integrals()

        get_umat_el => get_umat_el_normal

        call initfromfcid(nel,nbasismax,nBasis,lms,.false.)

        call GetUMatSize(nBasis, umatsize)

        allocate(TMat2d(nBasis, nBasis))

        call shared_allocate_mpi(umat_win, umat, (/umatsize/))
        UMat = 0.0_dp
        call SysInit()
        call readfciint(UMat,umat_win,nBasis,ecore)
        ! required: set up the spin info

        call DetInit()
        call DetCalcInit()
        ! call SpinOrbSymSetup()

        call DetPreFreezeInit()

        call CalcInit()

        call init_guga()

    end subroutine init_guga_plugin

    subroutine finalize_guga_plugin()
        call shared_deallocate_mpi(umat_win, umat)
        if(associated(TMat2d)) deallocate(TMat2d)
        call CalcCleanup()
        call DetCleanup()
        call SysCleanup()
        call clean_parallel()
    end subroutine finalize_guga_plugin

    function guga_matel(nI, nJ) result(matel)
        integer, intent(in) :: nI(nel), nJ(nel)
        HElement_t(dp) :: matel
        integer(n_int) :: ilutI(0:NIfTot), ilutJ(0:NIfTot)
        type(ExcitationInformation_t) :: excitInfo

        if(all(nI == nJ)) then
            matel = calcDiagMatEleGuga_nI(nI)
        else
            call EncodeBitDet(nI, ilutI)
            call EncodeBitDet(nJ, ilutJ)
            call calc_guga_matrix_element(&
                ilutI, CSF_Info_t(ilutI), ilutJ, CSF_Info_t(ilutJ), &
                excitInfo, matel, .true.)
        end if

    end function guga_matel

end module guga_plugin
