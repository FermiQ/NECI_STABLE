module adi_data

    use constants, only: dp, n_int
    use FciMCData, only: ll_node
    implicit none
    save

    ! Number of references for all-doubs-initiators and (important) number of references
    ! currently to check
    integer :: nRefs, nTZero, maxNRefs
    ! References for the purpose of the ADI scheme
    integer(n_int), allocatable :: ilutRefAdi(:, :)
    ! Store the signs and determinants separately, so they dont need to be
    ! reconstructed on each coherence check
    integer, allocatable :: nIRef(:, :), exLvlRef(:)
    real(dp), allocatable :: signsRef(:, :)
    integer :: nIncoherentDets, nCoherentDoubles, nConnection, AllConnection, &
               AllCoherentDoubles, AllIncoherentDets
    logical :: tReferenceChanged, tSetupSIs, tUseCaches
    ! Data for the update of nrefs
    logical :: tSingleSteps, tVariableNRef
    real(dp) :: lastAllNoatHF
    integer :: lastNRefs
    ! desired reference population and tolerance
    integer :: targetRefPop, targetRefPopTol, nRefUpdateInterval

    ! Flags for the alldoublesinitiators feature
    logical :: tAllDoubsInitiators, tDelayAllDoubsInits
    logical :: tSetDelayAllDoubsInits, tDelayGetRefs
    integer :: allDoubsInitsDelay, SIUpdateInterval
    integer :: SIUpdateOffset
    logical :: tAdiActive, tStrictCoherentDoubles, tWeakCoherentDoubles, tAvCoherentDoubles
    ! Thresholds for xi and populations
    real(dp) :: NoTypeN, coherenceThreshold, SIThreshold
    logical :: tReadRefs, ProductReferences, tAccessibleDoubles, tAccessibleSingles, tSuppressSIOutput

    integer :: nExCheckFails, nExChecks, allNExCheckFails, allNExChecks

    !Minimum number of connections to SI in order for the sign-coherence parameter to be valid
    integer :: minSIConnect
    logical :: tWeightedConnections

    ! if we use a signed average over replicas to determine superinitiators
    logical :: tSignedRepAv = .false.

end module adi_data
