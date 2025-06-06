#include "macros.h"

module DetBitOps

    ! A collection of useful operations to perform on the bit-representation
    ! of determinants.

    use Systemdata, only: nel, tOddS_HPHF, tHPHF
    use CalcData, only: tTruncInitiator, tSemiStochastic
    use bit_rep_data, only: NIfTot, NIfD, &
                            test_flag, extract_sign
    use constants, only: n_int, bits_n_int, end_n_int, dp, lenof_sign
    use error_handling_neci, only: stop_all

    implicit none

    private
    public :: MaskAlpha, MaskBeta, DetBitLt, Countbits, findbitexcitlevel, &
        count_open_orbs, DetBitEQ, return_ms, ilut_lt, ilut_gt, &
        count_set_bits, encodebitdet, return_hphf_sym_det, &
        tAccumEmptyDet, getbitexcitation, get_bit_excitmat, &
        spatial_bit_det, testclosedshelldet, findexcitbitdet, &
        isallowedhphf, calcopenorbs, get_single_parity, sign_lt, sign_gt, &
        spin_sym_ilut, findspatialbitexcitlevel, detbitzero, &
        Countbits_elemental

#ifdef INT64_
    ! 10101010 and 01010101 in binary respectively.
!    integer(n_int), parameter :: MaskBeta=Z'5555555555555555'
    integer(n_int), parameter :: MaskBeta = 6148914691236517205_n_int
    integer(n_int), parameter :: MaskAlpha = IShft(MaskBeta, 1)
#else
    integer(n_int), parameter :: MaskBeta = 1431655765_n_int
    integer(n_int), parameter :: MaskAlpha = -1431655766_n_int
#endif

    ! Which count-bits procedure do we use?
    ! http://gurmeetsingh.wordpress.com/2008/08/05/fast-bit-counting-routines/
    ! for a variety of interesting bit counters
    interface CountBits
        !module procedure CountBits_sparse
        !module procedure CountBits_nifty
        module procedure CountBits_elemental
    end interface

contains

    ! Using elemental routines rather than an explicit do-loop. Should be
    ! faster.
    pure function CountBits_elemental(iLut, nLast, nBitsMax) result(nbits)
        integer, intent(in), optional :: nBitsMax
        integer, intent(in) :: nLast
        integer(kind=n_int), intent(in) :: iLut(0:nLast)
        integer :: nbits, unused

        if (present(nBitsMax)) unused = nBitsMax

        nbits = sum(count_set_bits(iLut))

        !No advantage to test for this!
!        if (present(nBitsMax)) nbits = min(nBitsmax+1, nbits)
    end function

    ! An elemental routine which will count the number of bits set in one
    ! (32 bit) integer. We can do similar things for 8bit, 16bit and 64bit.
    ! This makes use of the same counting trick as CountBits_nifty. As nicely
    ! summarised by James:
    !
    ! The general idea is to use a divide and conquer approach.
    ! * Set each 2 bit field to be the sum of the set bits in the two single
    !   bits originally in that field.
    ! * Set each 4 bit field to be the sum of the set bits in the two 2 bit
    !   fields originally in the 4 bit field.
    ! * Set each 8 bit field to be the sum of the set bits in the two 4 bit
    !   fields it contains.
    ! * etc.
    ! Thus we obtain an algorithm like:
    !     x = ( x & 01010101...) + ( (x>>1) & 01010101...)
    !     x = ( x & 00110011...) + ( (x>>2) & 00110011...)
    !     x = ( x & 00001111...) + ( (x>>4) & 00001111...)
    ! etc., where & indicates AND and >> is the shift right operator.
    ! Further optimisations are:
    ! * Any & operations can be omitted where there is no danger that
    ! a field's sum will carry over into the next field.
    ! * The first line can be replaced by:
    !     x = x - ( (x>>1) & 01010101...)
    !   thanks to the population (number of set bits) in an integer
    !   containing p bits being given by:
    !     pop(x) = \sum_{i=0}^{p-1} x/2^i
    ! * Summing 8 bit fields together can be performed via a multiplication
    !   followed by a right shift.
    elemental function count_set_bits(a) result(nbits)
        integer(n_int), intent(in) :: a
        integer :: nbits
        integer(n_int) :: tmp

#ifdef INT64_
        integer(n_int), parameter :: m1 = 6148914691236517205_n_int  !Z'5555555555555555'
        integer(n_int), parameter :: m2 = 3689348814741910323_n_int  !Z'3333333333333333'
        integer(n_int), parameter :: m3 = 1085102592571150095_n_int  !Z'0f0f0f0f0f0f0f0f'
        integer(n_int), parameter :: m4 = 72340172838076673_n_int    !Z'0101010101010101'

        ! For 64 bit integers:
        tmp = a - iand(ishft(a, -1), m1)
        tmp = iand(tmp, m2) + iand(ishft(tmp, -2), m2)
        tmp = iand(tmp, m3) + iand(ishft(tmp, -4), m3)
        nbits = int(ishft(tmp * m4, -56))
#else
        integer(n_int), parameter :: m1 = 1431655765_n_int    !Z'55555555'
        integer(n_int), parameter :: m2 = 858993459_n_int     !Z'33333333'
        integer(n_int), parameter :: m3 = 252645135_n_int     !Z'0F0F0F0F'
        integer(n_int), parameter :: m4 = 16843009_n_int      !Z'01010101'

        ! For 32 bit integers:
        tmp = a - iand(ishft(a, -1), m1)
        tmp = iand(tmp, m2) + iand(ishft(tmp, -2), m2)
        tmp = iand((tmp + ishft(tmp, -4)), m3) * m4
        nbits = ishft(tmp, -24)
#endif

    end function count_set_bits

    pure integer function count_open_orbs(iLut)

        ! Returns the number of unpaired electrons in the determinant.
        !
        ! In:  iLut (0:NIfD) - Source bit det

        integer(kind=n_int), intent(in) :: iLut(0:NIfD)
        integer(kind=n_int), dimension(0:NIfD) :: alpha, beta

        alpha = iand(iLut, MaskAlpha)
        beta = iand(iLut, MaskBeta)
        alpha = ishft(alpha, -1)
        alpha = ieor(alpha, beta)

        count_open_orbs = CountBits(alpha, NIfD)
    end function

    pure function FindBitExcitLevel(iLutnI, iLutnJ, maxExLevel, t_hphf_ic) result(IC)

        ! Find the excitation level of one determinant relative to another
        ! given their bit strings (the number of orbitals they differ by)
        !
        ! In:  iLutnI, iLutnJ    - The bit representations
        !      maxExLevel        - An (optional) maximum ex level to consider
        !      t_hphf_ic         - An (optional) flag to determine the
        !                          minimum excitation level in an HPHF calculation to
        !                          both spin-coupled references if present
        ! Ret: FindBitExcitLevel - The number of orbitals i,j differ by

        integer(kind=n_int), intent(in) :: iLutnI(0:NIfD), iLutnJ(0:NIfD)
        integer, intent(in), optional :: maxExLevel
        logical, intent(in), optional :: t_hphf_ic
        integer(kind=n_int) :: tmp(0:NIfD)
        integer :: IC, unused

        ! Unused
        if (present(maxExLevel)) unused = maxExLevel

        if (present(t_hphf_ic)) then
            if (t_hphf_ic .and. tHPHF) then
                if (.not. (TestClosedShellDet(ilutnI) .and. TestClosedShellDet(iLutnJ))) then
                    ! make sure that we are calculating the correct excitation
                    ! level, which should be the minimum of the possible ones in
                    ! HPHF mode
                    ! if both are closed shell it is fine
                    ic = FindBitExcitLevel_hphf(ilutnI, ilutnJ)
                    return
                end if
            end if
        end if

        ! Obtain a bit string with only the excited orbitals one one det.
        tmp = ieor(iLutnI, iLutnJ)
        tmp = iand(iLutnI, tmp)

        IC = CountBits(tmp, NIfD)

    end function FindBitExcitLevel

    function FindSpatialBitExcitLevel(iLutI, iLutJ, maxExLevel) result(IC)

        ! Find the excitation level of one determinant relative to another
        ! given their bit strings, ignoring the spin components of orbitals.
        ! (i.e. the number of spatial orbitals they differ by)
        !
        ! In:  iLutI, iLutJ - The bit representations
        !      maxExLevel   - An (optional) maximum ex level to consider
        ! Ret: IC           - The numbero f orbitals i,j differ by

        integer(kind=n_int), intent(in) :: iLutI(0:NIfD), iLutJ(0:NIfD)
        integer, intent(in), optional :: maxExLevel
        integer :: IC
        integer(kind=n_int), dimension(0:NIfD, 2) :: alpha, beta, sing, doub, tmp

        ! Obtain the alphas and betas
        alpha(:, 1) = iand(ilutI, MaskAlpha)
        alpha(:, 2) = iand(ilutJ, MaskAlpha)
        beta(:, 1) = iand(ilutI, MaskBeta)
        beta(:, 2) = iand(ilutJ, MaskBeta)

        ! Bit strings separating doubles, and singles shifted to beta pos.
        doub = iand(beta, ishft(alpha, -1))
        doub = ior(doub, ishft(doub, +1))
        sing = ieor(beta, ishft(alpha, -1))

        ! Doubles and singles shifted to betas. Obtain unique orbitals ...
        tmp = ior(doub, sing)
        tmp(:, 1) = ieor(tmp(:, 1), tmp(:, 2))
        tmp(:, 1) = iand(tmp(:, 1), tmp(:, 2))

        ! ... and count them.
        if (present(maxExLevel)) then
            IC = CountBits(tmp(:, 1), NIfD, maxExLevel)
        else
            IC = CountBits(tmp(:, 1), NIfD)
        end if
    end function FindSpatialBitExcitLevel

    !WARNING - I think this *may* be buggy - use with caution - ghb24 8/6/10
    ! I fixed a bug (bits_n_int -> bits_n_int-1), but maybe there's more... - NSB 7/10/14
    ! [W.D.12.12.2017] so lets fix it then!
    ! there are now unit tests in the k_space_hubbard unit test suite for this
    ! routine. And i will also code up a version, which determines the sign
    ! based on the ilut representation! since this should be much faster
    ! than the nI based calculation! use Manu's paper!
    ! and this can be done way more effective with the new fortran 2008
    ! routines! todo: implement this more efficiently! and write unit tests!
    pure subroutine get_bit_excitmat(ilutI, iLutJ, ex, IC)

        ! Obatin the excitation matrix between two determinants from their bit
        ! representation without calculating tSign --> a bit quicker.
        !
        ! In:    iLutI, iLutJ - Bit representations of determinants I,J
        ! InOut: IC           - Specify max IC before bailing, and return
        !                       number of orbital I,J differ by
        ! Out:   ex           - Excitation matrix between I,J

        integer(n_int), intent(in) :: iLutI(0:NIfD), iLutJ(0:NIfD)
        integer, intent(inout)  :: IC
        integer, intent(out) :: ex(2, IC)

        integer(n_int) :: ilut(0:NIfD, 2)
        integer :: pos(2), max_ic, i, j, k

        ! Obtain bit representations of I,J containing only unique orbitals
        ilut(:, 1) = ieor(ilutI, ilutJ)
        ilut(:, 2) = iand(ilutJ, ilut(:, 1))
        ilut(:, 1) = iand(ilutI, ilut(:, 1))

        max_ic = IC
        pos = 0
        IC = 0
        do i = 0, NIfD
            do j = 0, bits_n_int - 1
                do k = 1, 2
                    if (pos(k) < max_ic) then
                        if (btest(ilut(i, k), j)) then
                            pos(k) = pos(k) + 1
                            IC = max(IC, pos(k))
                            ex(k, pos(k)) = bits_n_int * i + j + 1
                        end if
                    end if
                end do
                if (pos(1) >= max_ic .and. pos(2) >= max_ic) return
            end do
        end do

    end subroutine get_bit_excitmat

    ! This will return true if iLutI is identical to iLutJ and will return
    ! false otherwise.
    pure function DetBitEQ(iLutI, iLutJ, nLast, t_hphf_in) result(res)
        integer(kind=n_int), intent(in) :: iLutI(0:), iLutJ(0:)
        integer, intent(in), optional :: nLast
        logical, intent(in), optional :: t_hphf_in
        logical :: res, t_hphf
        integer :: i, lnLast
        integer(n_int) :: ilut_hphf(0:niftot)

        if (present(t_hphf_in)) then
            t_hphf = t_hphf_in
        else
            t_hphf = .false.
        end if

        if (t_hphf) then
            ilut_hphf = return_hphf_sym_det(ilutJ)

            if (present(nLast)) then
                lnLast = nLast
            else
                lnLast = nifd
            end if

            if (.not. (all(ilutI(0:lnLast) == ilutJ(0:lnLast)) .or. &
                       all(ilutI(0:lnLast) == ilut_hphf(0:lnLast)))) then

                res = .false.
                return
            end if
        else
            if (iLutI(0) /= iLutJ(0)) then
                res = .false.
                return
            else
                if (present(nLast)) then
                    lnLast = nLast
                else
                    lnLast = nifd
                end if

                do i = 1, lnLast
                    if (iLutI(i) /= iLutJ(i)) then
                        res = .false.
                        return
                    end if
                end do
            end if
        end if

        res = .true.

    end function DetBitEQ
!
    pure function return_hphf_sym_det(ilut_in) result(ilut_out)
        ! to avoid circular dependencies and due to the strange implementation
        ! to find the symmetry conjugated determinant of an HPHF pair
        ! create a new routine to return a open-shell determinant where the
        ! last single occupied spatial orbital is an alpha spin
        ! this is the convention in the storage of the hphfs
        ! this can easily be tested by checking if the bit-encoded determinant
        ! has an higher integer value!
        ! different to the original implementation of this routine
        ! standardyl we only return the determinant which should be stored
        ! in the CurrentDets. so if ilut_in is already this determinant
        ! ilut_out will be == ilut_in
        ! and it also deals with closed-shell dets, where it will just
        ! return the same determinant
        integer(n_int), intent(in) :: ilut_in(0:niftot)
        integer(n_int) :: ilut_out(0:niftot)
        INTEGER(n_int) :: iLutAlpha(0:NIfTot), iLutBeta(0:NIfTot)
        INTEGER :: i

        if (TestClosedShellDet(ilut_in)) then
            ilut_out = ilut_in
            return
        end if

        ilut_out(:) = 0_n_int
        iLutAlpha(:) = 0_n_int
        iLutBeta(:) = 0_n_int

        ! this is taken from HPHFRandExcitMod
        do i = 0, nifd
            !Seperate the alpha and beta bit strings
            iLutAlpha(i) = IAND(ilut_in(i), MaskAlpha)
            iLutBeta(i) = IAND(ilut_in(i), MaskBeta)

            !Shift all alpha bits to the left by one.
            iLutAlpha(i) = ISHFT(iLutAlpha(i), -1)
            !Shift all beta bits to the right by one.
            iLutBeta(i) = ISHFT(iLutBeta(i), 1)
            !Combine the bit strings to give the final bit representation.
            ilut_out(i) = IOR(iLutAlpha(i), iLutBeta(i))
        end do

        i = DetBitLT(ilut_in, ilut_out)

        ! i == 1 indicated that ilut_in is "less" than the symmetric
        ! so ilut_out is the to be stored one
        if (i == -1) then
            ilut_out = ilut_in
        end if

    end function return_hphf_sym_det

    pure function sign_lt(ilutI, ilutJ) result(bLt)

        ! This is a comparison function between two bit strings of length
        ! 0:NIfTot, and will return true if absolute value of the sign of
        ! ilutI is less than ilutJ

        integer(n_int), intent(in) :: iLutI(0:), iLutJ(0:)
        logical :: bLt
        real(dp) :: SignI(lenof_sign), SignJ(lenof_sign)
        real(dp) :: WeightI, WeightJ

        call extract_sign(ilutI, SignI)
        call extract_sign(ilutJ, SignJ)

        if (lenof_sign == 1) then
            bLt = abs(SignI(1)) < abs(SignJ(1))
        else
            WeightI = sqrt(real(SignI(1), dp)**2 + &
                           real(SignI(lenof_sign), dp)**2)
            WeightJ = sqrt(real(SignJ(1), dp)**2 + &
                           real(SignJ(lenof_sign), dp)**2)

            bLt = WeightI < WeightJ
        end if
    end function sign_lt

    pure function sign_gt(ilutI, ilutJ) result(bGt)

        ! This is a comparison function between two bit strings of length
        ! 0:NIfTot, and will return true if the abs sign of ilutI is greater
        ! than ilutJ

        integer(n_int), intent(in) :: iLutI(0:), iLutJ(0:)
        logical :: bGt
        real(dp) :: SignI(lenof_sign), SignJ(lenof_sign)
        real(dp) :: WeightI, WeightJ

        call extract_sign(ilutI, SignI)
        call extract_sign(ilutJ, SignJ)

        if (lenof_sign == 1) then
            bGt = abs(SignI(1)) > abs(SignJ(1))
        else
            WeightI = sqrt(real(SignI(1), dp)**2 + &
                           real(SignI(lenof_sign), dp)**2)
            WeightJ = sqrt(real(SignJ(1), dp)**2 + &
                           real(SignJ(lenof_sign), dp)**2)

            bGt = WeightI > WeightJ
        end if
    end function sign_gt

    pure function ilut_lt(ilutI, ilutJ) result(bLt)

        ! This sorting function returns true if iLutI is less than iLutJ,
        ! else it returns false. For non-semi-stochastic simulations, this is
        ! decided by comparing the integers that the bitstring represent.

        integer(n_int), intent(in) :: iLutI(0:), iLutJ(0:)
        integer :: i
        logical :: bLt

        do i = 0, nifd
            if (iLutI(i) /= iLutJ(i)) exit
        end do

        if (i > nifd) then
            bLt = .false.
        else
            bLt = ilutI(i) < ilutJ(i)
        end if

    end function

    pure function ilut_gt(iLutI, iLutJ) result(bGt)

        ! This sorting function returns true if iLutI is greater than iLutJ,
        ! else it returns false. For non-semi-stochastic simulations, this is
        ! decided by comparing the integers that the bitstring represent.

        integer(n_int), intent(in) :: iLutI(0:), iLutJ(0:)
        integer :: i
        logical :: bGt

        do i = 0, nifd
            if (ilutI(i) /= iLutJ(i)) exit
        end do

        if (i > nifd) then
            bGt = .false.
        else
            bGt = ilutI(i) > ilutJ(i)
        end if

    end function

    ! This will return true if the determinant has been set to zero, and
    ! false otherwise.
    pure logical function DetBitZero(iLutI, nLast)
        integer, intent(in), optional :: nLast
        integer(kind=n_int), intent(in) :: iLutI(0:NIfTot)
        integer :: i, lnLast
        if (iLutI(0) /= 0) then
            DetBitZero = .false.
            return
        else
            if (present(nLast)) then
                lnLast = nLast
            else
                lnLast = NIftot
            end if
            do i = 1, lnLast
                if (iLutI(i) /= 0) then
                    DetBitZero = .false.
                    return
                end if
            end do
        end if
        DetBitZero = .true.
    end function DetBitZero

    ! This will return 1 if iLutI is "less" than iLutJ, 0 if the determinants
    ! are identical, or -1 if iLutI is "more" than iLutJ
    pure integer function DetBitLT(iLutI, iLutJ, nLast)
        integer, intent(in), optional :: nLast
        integer(kind=n_int), intent(in) :: iLutI(0:NIfTot), iLutJ(0:NIfTot)
        integer :: i, lnLast

        !First, compare first integers
        IF (iLutI(0) < iLutJ(0)) THEN
            DetBitLT = 1
        else if (iLutI(0) == iLutJ(0)) THEN
            ! If the integers are the same, then cycle through the rest of
            ! the integers until we find a difference.
            ! If we don't want to consider all the integers, specify nLast
            if (present(nLast)) then
                lnLast = nLast
            else
                lnLast = nifd
            end if
            do i = 1, lnLast
                IF (iLutI(i) < iLutJ(i)) THEN
                    DetBitLT = 1
                    RETURN
                else if (iLutI(i) > iLutJ(i)) THEN
                    DetBitLT = -1
                    RETURN
                end if
            end do

            DetBitLT = 0
        ELSE
            DetBitLT = -1
        end if

    END FUNCTION DetBitLT


    ! This is a routine to encode a determinant as natural ordered integers
    ! (nI) as a bit string (iLut(0:NIfTot)) where NIfD=INT(nBasis/32)
    ! If this is a csf, the csf is contained afterwards.
    pure subroutine EncodeBitDet(nI, iLut)
        integer, intent(in) :: nI(:)
        integer(kind=n_int), intent(out) :: iLut(0:NIfTot)
        integer :: i, pos

        iLut(:) = 0_n_int

        !Decode determinant
        do i = 1, size(nI)
            pos = (nI(i) - 1) / bits_n_int
            iLut(pos) = ibset(iLut(pos), mod(nI(i) - 1, bits_n_int))
        end do

    end subroutine EncodeBitDet

    pure function spatial_bit_det(ilut) result(ilut_s)

        ! Convert the spin orbital representation in ilut_s into a spatial
        ! orbital representation, with all singly occupied orbitals in the
        ! 'beta' position.
        !
        ! In:  ilut   - Spin orbital, bit representation
        ! Out: ilut_s - Spatial orbital, bit representation. Loses all sign
        !               etc. info (i.e. for ints > NIfD --> 0)

        integer(n_int), intent(in) :: ilut(0:NIfTot)
        integer(n_int) :: ilut_s(0:NIfTot)
        integer(n_int), dimension(0:NIfD) :: alpha, beta, a_sft, b_sft

        ! Obtain alpha/beta orbital representations
        alpha = iand(ilut(0:NIfD), MaskAlpha)
        beta = iand(ilut(0:NIfD), MaskBeta)

        ! Shift alphas to beta pos and vice-versa
        a_sft = ishft(alpha, -1)
        b_sft = ishft(beta, +1)

        ! Obtain representation with all singly occupied orbitals in the beta
        ! position, and doubly occupied orbitals doubly occupied
        ilut_s(NIfD + 1:NIfTot) = 0
        ilut_s(0:NIfD) = ior(beta, ior(a_sft, iand(b_sft, alpha)))

    end function

    subroutine FindExcitBitDet(iLutnI, iLutnJ, IC, ExcitMat)

        ! This routine will find the bit-representation of an excitation by
        ! constructing the new ilut from the old one and the excitation matrix
        !
        ! In:  iLutnI (0:NIfD) - source bit det
        !      IC              - Excitation level
        !      ExcitMat(2,2)   - Excitation Matrix
        ! Out: iLutnJ (0:NIfD) - New bit det

        integer, intent(in) :: IC
        integer, intent(in) :: ExcitMat(2, ic)
        integer(kind=n_int), intent(in) :: iLutnI(0:NIfTot)
        integer(kind=n_int), intent(inout) :: iLutnJ(0:NIfTot)
        integer :: pos(2, ic), bit(2, ic), i, ic_tmp
#ifdef DEBUG_
        character(*), parameter :: this_routine = "FindExcitBitDet"
#endif
        if (ic == 0) return

        ASSERT(ic > 0 .and. ic <= 3)

        iLutnJ = iLutnI
        ! Which integer and bit in ilut represent each element?
        pos = (excitmat - 1) / bits_n_int
        bit = mod(excitmat - 1, bits_n_int)

        ! [W.D.12.12.2017]:
        ! why is this changed back to single excitations for ic=3?
        ! has this to do with simons CSFs? i can't really find a reason..
        ! try to change it and then lets see what happens!
        ic_tmp = ic

        ! Clear bits for excitation source, and set bits for target
        do i = 1, ic_tmp
            iLutnJ(pos(1, i)) = ibclr(iLutnJ(pos(1, i)), bit(1, i))
            iLutnJ(pos(2, i)) = ibset(iLutnJ(pos(2, i)), bit(2, i))
        end do

    end subroutine FindExcitBitDet

    pure function return_ms(ilut, n_el) result(ms_local)

        ! Return the Ms value for the input ilut.

        ! **WARNING** This function assumes that the number of electrons in the
        ! determinant (the number of set bits in ilut) is equal to nel.

        integer(n_int), intent(in) :: ilut(0:NIfTot)
        integer, intent(in), optional :: n_el

        integer(n_int) :: ilut_alpha(0:NIfD)
        integer :: nup
        integer :: ms_local
        integer :: n_el_
        def_default(n_el_, n_el, nel)

        ilut_alpha = iand(ilut(0:NIfD), MaskAlpha)
        nup = sum(count_set_bits(ilut_alpha))
        ! *Assuming ndown = nel - nup*
        ms_local = 2 * nup - n_el_

    end function return_ms

    pure function TestClosedShellDet(ilut) result(tClosed)

        ! Is the determinant closed shell?

        integer(n_int), intent(in) :: iLut(0:NIfTot)
        integer(n_int) :: alpha(0:NIfD), beta(0:NIfD)
        logical :: tClosed

        ! Separate alphas and betas
        alpha = iand(ilut(0:NIfD), MaskAlpha)
        beta = iand(ilut(0:NIfD), MaskBeta)

        ! Shift and XOR to eliminate paired electrons
        alpha = ieor(beta, ishft(alpha, -1))

        ! Are there any remaining unpaired electrons?
        tClosed = all(alpha == 0)

    end function TestClosedShellDet

    ! Routine to count number of open *SPATIAL* orbitals in a bit-string
    ! representation of a determinant.
    ! ************************
    ! NOTE: This function name is misleading
    !       It counts the number of unpaired Beta electrons (ignores Alpha)
    !       --> Returns nopen/2 <==> Ms=0
    ! ************************
    pure SUBROUTINE CalcOpenOrbs(iLut, OpenOrbs)
        INTEGER(kind=n_int) :: iLutAlpha(0:NIfD), iLutBeta(0:NIfD)
        integer(n_int), intent(in) :: ilut(0:NIfD)
        integer, intent(out) :: OpenOrbs

        iLutAlpha(:) = 0
        iLutBeta(:) = 0

        iLutAlpha(:) = IAND(iLut(:), MaskAlpha)    !Seperate the alpha and beta bit strings
        iLutBeta(:) = IAND(iLut(:), MaskBeta)
        iLutAlpha(:) = ISHFT(iLutAlpha(:), -1)     !Shift all alpha bits to the left by one.

        iLutAlpha(:) = NOT(iLutAlpha(:))              ! This NOT means that set bits are now represented by 0s, not 1s
        iLutAlpha(:) = IAND(iLutAlpha(:), iLutBeta(:)) ! Now, only the 1s in the beta string will be counted.

        OpenOrbs = CountBits(iLutAlpha, NIfD, NEl)
    END SUBROUTINE CalcOpenOrbs

    function IsAllowedHPHF(ilut, sym_ilut) result(bAllowed)

        ! Is the specified determinant an 'allowed' HPHF function (i.e. can
        ! it be found in the determinant list, or is it the symmetry paired
        ! one?

        integer(n_int), intent(in) :: ilut(0:NIfD)
        integer(n_int) :: ilut_tmp(0:NIfD)
        integer(n_int), intent(out), optional :: sym_ilut(0:NIfD)
        logical :: bAllowed, tCS

        tCS = TestClosedShellDet(ilut)

        if (tCS .and. (.not. tOddS_HPHF)) then
            bAllowed = .true.
        else if (tCS .and. tOddS_HPHF) then
            bAllowed = .false.
        else
            call spin_sym_ilut(ilut, ilut_tmp)
            if (DetBitLt(ilut, ilut_tmp, NIfD) > 0) then
                bAllowed = .false.
            else
                bAllowed = .true.
            end if

            if (present(sym_ilut)) sym_ilut = ilut_tmp
        end if

    end function

    pure subroutine spin_sym_ilut(ilutI, ilutJ)

        ! Generate the spin-coupled determinant of ilutI in ilutJ. Performs
        ! the same operation as FindDetSpinSym rather more concisely.

        integer(n_int), intent(in) :: ilutI(0:NIfD)
        integer(n_int), intent(out) :: ilutJ(0:NIfD)
        integer(n_int) :: ilut_tmp(0:NIfD)

        ilut_tmp = ishft(iand(ilutI, MaskAlpha), -1)
        ilutJ = ishft(iand(ilutI, MaskBeta), +1)
        ilutJ = ior(ilutJ, ilut_tmp)

    end subroutine

    ! [W.D. 12.12.2017]
    ! why are those routines not used more often??
    pure function get_single_parity(ilut, src, tgt) result(par)

        ! Find the relative parity of two determinants, where one is ilut
        ! and the other is a single excitation of ilut where orbital src is
        ! swapped with orbital tgt.

        integer, intent(in) :: src, tgt
        integer(n_int), intent(in) :: ilut(0:NIfTot)

        integer(n_int) :: mask(0:NIfD)
        integer :: min_orb, max_orb, par, min_int, max_int, cnt
        integer :: min_in_int, max_in_int

        ! We just want to count the orbitals between these two limits.
        min_orb = (min(src, tgt) + 1) - 1
        max_orb = (max(src, tgt) - 1)

        ! Which integers of the bit representation are involved?
        min_int = int(min_orb / bits_n_int)
        max_int = int(max_orb / bits_n_int)

        ! Where in the integer do the revelant bits sit?
        min_in_int = mod(min_orb, bits_n_int)
        max_in_int = mod(max_orb, bits_n_int)

        ! Generate a mask so as to only count the occupied orbitals
        ! between where we started and the end.
        mask(0:min_int - 1) = 0
        mask(min_int:max_int) = not(0_n_int)
        mask(max_int + 1:NIfD) = 0
        mask(min_int) = &
            iand(mask(min_int), ishft(not(0_n_int), min_in_int))
        mask(max_int) = &
            iand(mask(max_int), not(ishft(not(0_n_int), max_in_int)))

        ! Count the number of occupied orbitals between the source and tgt
        ! orbitals.
        cnt = CountBits(iand(mask, ilut(0:NIfD)), NIfD)

        ! Get the parity from this information.
        if (btest(cnt, 0)) then
            par = -1
        else
            par = 1
        end if

    end function

    pure function tAccumEmptyDet(ilut) result(tAccum)
        use FciMCData, only: iLutHF
        use bit_rep_data, only: test_flag, NIfD, flag_removed
        use LoggingData, only: tAccumPopsActive, iAccumPopsMaxEx

        ! Whether we should keep a determinant in CurrentDets even if it
        ! is unoccupied

        integer(kind=n_int), intent(in) :: iLut(0:NIfD)
        logical :: tAccum
        integer :: ExcitLevel

        tAccum = .false.

        ! If the determinant has already been removed, skip accumlating its
        ! population
        if (test_flag(ilut, flag_removed)) return

        if (tAccumPopsActive) then

            ! If we are accumlating populations, we keep all empty dets up to
            ! excitation level iAccumPopsMaxEx.
            if (iAccumPopsMaxEx > 0) then
                ExcitLevel = FindBitExcitLevel(iLutHF, ilut)
                if (ExcitLevel > iAccumPopsMaxEx) return
            end if

            tAccum = .true.
        end if
    end function

    pure function FindBitExcitLevel_hphf(ilutnI, iLutnJ) result(ic)
        integer(n_int), intent(in) :: ilutnI(0:nifd), ilutnJ(0:nifd)
        integer :: ic
        integer(n_int) :: ilutsI(0:nifd, 2), ilutsJ(0:nifd, 2), tmp(0:nifd)
        integer :: ic_tmp(4), i, j, k

        ilutsI(:, 1) = ilutnI
        call spin_sym_ilut(ilutnI, ilutsI(:, 2))
!         ilutsI(:,2) = spin_flip(ilutnI)

        ilutsJ(:, 1) = ilutnJ
        call spin_sym_ilut(ilutnJ, ilutsJ(:, 2))
!         ilutsJ(:,2) = spin_flip(ilutnJ)

        i = 1
        ic_tmp = 9999

        do j = 1, 2
            do k = 1, 2
                tmp = ieor(ilutsI(:, j), ilutsJ(:, k))
                tmp = iand(ilutsI(:, j), tmp)

                ic_tmp(i) = CountBits(tmp, nifd)
                i = i + 1
            end do
        end do

        ic = minval(ic_tmp)

    end function FindBitExcitLevel_hphf

    pure subroutine GetBitExcitation(iLutnI, iLutnJ, Ex, tSign)

        ! A port from hfq. The first of many...
        ! JSS.

        ! In:
        !    iLutnI(basis_length): bit string representation of the Slater
        !        determinant.
        !    iLutnJ(basis_length): bit string representation of the Slater
        !        determinant.
        !    Ex(1,1): contains the maximum excitation level, max_excit, to be
        !        considered.
        ! Out:
        !    Ex(2,max_excit): contains the excitation connected iLutnI to
        !        iLutnJ.  Ex(1,i) is the i-th orbital excited from and Ex(2,i)
        !        is the corresponding orbital excited to.
        !    tSign:
        !        True if an odd number of permutations is required to line up
        !        the determinants.

        use bit_rep_data, only: NIfD
!         use DetBitOps, only: count_set_bits
        use constants, only: n_int, bits_n_int, end_n_int
        integer(kind=n_int), intent(in) :: iLutnI(0:NIfD), iLutnJ(0:NIfD)
        integer, intent(inout) :: Ex(2, *)
        logical, intent(out) :: tSign
        integer :: i, j, iexcit1, iexcit2, perm, iel1, iel2, max_excit
        integer :: set_bits
        logical :: testI, testJ

        tSign = .true.
        max_excit = Ex(1, 1)
        Ex(:, 1:max_excit) = 0

        if (max_excit > 0) then

            iexcit1 = 0
            iexcit2 = 0
            iel1 = 0
            iel2 = 0
            perm = 0

            ! Finding the permutation to align the determinants is non-trivial.
            ! It turns out to be quite easy with bit operations.
            ! The idea is to do a "dumb" permutation where the determinants are
            ! expressed in two sections: orbitals not involved in the excitation
            ! and those that are.  Each section is stored in ascending index
            ! order.
            ! To obtain such ordering requires (for each orbital that is
            ! involved in the excitation) a total of
            ! nel - iel - max_excit + iexcit
            ! where nel is the number of electrons, iel is the position of the
            ! orbital within the list of occupied states in the determinant,
            ! max_excit is the total number of excitations and iexcit is the number
            ! of the "current" orbital involved in excitations.
            ! e.g. Consider (1, 2, 3, 4, 5) -> (1, 3, 5, 6, 7).
            ! (1, 2, 3, 4) goes to (1, 3, 2, 4).
            ! 2 is the first (iexcit=1) orbital found involved in the excitation
            ! and so requires 5 - 2 - 2 + 1 = 2 permutation to shift it to the
            ! first "slot" in the excitation "block" in the list of states.
            ! 4 is the second orbital found and requires 5 - 4 - 2 + 2 = 1
            ! permutation to shift it the end (last "slot" in the excitation
            ! block).
            ! Whilst the resultant number of permutations isn't necessarily the
            ! minimal number for the determinants to align, this is irrelevant
            ! as the Slater--Condon rules only care about whether the number of
            ! permutations are odd or even.

            ! n.b. We don't need to include shift or iexcit in the perm
            !      calculation, as is it symmetric as iexcit reaches the same
            !      maximum value for both src and target iluts
            !shift = nel - max_excit

            do i = 0, NIfD
                ! If this integer will make no difference to the overall counts,
                ! then minimise effort...
                if (ilutnI(i) == ilutnJ(i)) then
                    if (iexcit1 /= iexcit2) then
                        set_bits = count_set_bits(ilutnI(i))
                        iel1 = iel1 + set_bits
                        iel2 = iel2 + set_bits
                    end if
                end if
                if (iLutnI(i) == iLutnJ(i)) cycle
                do j = 0, end_n_int

                    testI = btest(iLutnI(i), j)
                    testJ = btest(iLutnJ(i), j)

                    if (testJ) iel2 = iel2 + 1

                    if (testI) then
                        iel1 = iel1 + 1
                        if (.not. testJ) then
                            ! occupied in iLutnI but not in iLutnJ
                            iexcit1 = iexcit1 + 1
                            Ex(1, iexcit1) = i * bits_n_int + j + 1
                            !perm = perm + (shift - iel1 + iexcit1)
                            perm = perm + iel1
                        end if
                    else
                        if (testJ) then
                            ! occupied in iLutnI but not in iLutnJ
                            iexcit2 = iexcit2 + 1
                            Ex(2, iexcit2) = i * bits_n_int + j + 1
                            !perm = perm + (shift - iel2 + iexcit2)
                            perm = perm + iel2
                        end if
                    end if
                    if (iexcit1 == max_excit .and. iexcit2 == max_excit) exit
                end do
                if (iexcit1 == max_excit .and. iexcit2 == max_excit) exit
            end do

            ! It seems that this test is faster than btest(perm,0)!
            tSign = mod(perm, 2) == 1

            if (iexcit1 < max_excit) then
                Ex(:, iexcit1 + 1) = 0 ! Indicate we've ended the excitation.
            end if

        end if

    end subroutine GetBitExcitation

end module

!This routine will find the largest bit set in a bit-string (i.e. the highest value orbital)
SUBROUTINE LargestBitSet(iLut, NIfD, LargestOrb)
    use constants, only: bits_n_int, end_n_int, n_int
    use error_handling_neci, only: stop_all
    IMPLICIT NONE
    INTEGER :: LargestOrb, NIfD, i, j
    INTEGER(KIND=n_int) :: iLut(0:NIfD)

#ifdef DEBUG_
    character(*), parameter :: this_routine = 'LargestBitSet'
#endif

!        do i=NIfD,0,-1
!!Count down through the integers in the bit string.
!!The largest set bit is equal to INT(log_2 (N))
!            IF(iLut(i).ne.0) THEN
!                LargestOrb=NINT(LOG(REAL(iLut(i)+1))*1.4426950408889634)
!                EXIT
!            end if
!        end do
!        LargestOrb=LargestOrb+(i*32)

    ! Initialise with invalid value (in case being erroniously called on empty bit-string).
    ASSERT(.not. all(ilut == 0))
    LargestOrb = 99999

    do i = NIfD, 0, -1
        do j = end_n_int, 0, -1
            if (btest(iLut(i), j)) then
                LargestOrb = (i * bits_n_int) + j + 1
                return
            end if
        end do
    end do

END SUBROUTINE LargestBitSet
