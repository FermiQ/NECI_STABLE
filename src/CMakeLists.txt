
# List the files that ought to be compiled

set( SRC_FILES

    adi_references.F90
    adi_initiators.F90
    adi_data.F90
    aliasSampling.F90
    blas_interface.F90
    Annihilation.F90
    bit_rep_data.F90
    BitReps.F90
    CalcData.F90
    Calc.F90
    calcrho.F90
    compiler_issues.txt
    cont_time_fcimc.F90
    cont_time_rates.F90
    core_space_util.F90
    CPMDData.F90
    cpmdinit.F90
    cpmdstub.F90
    davidson_neci.F90
    davidson_semistoch.F90
    default_sets.F90
    DetBitOps.F90
    DetCalcData.F90
    DetCalc.F90
    DeterminantData.F90
    Determinants.F90
    Determinants_impls.F90
    determ_proj.F90
    detham.F90
    direct_ci.F90
    enumerate_excitations.F90
    ErrorAnalysis.F90
    exact_diag.F90
    exact_spectrum.F90
    excit.F90
    excit_parity.F90
    fast_determ_hamil.F90
    FciMCData.F90
    fcimc_helper.F90
    fcimc_iter_utilities.F90
    FciMCLogging.F90
    fcimc_output.F90
    FciMCPar.F90
    fcimc_pointed_fns.F90
    fcoul.F90
    frsblk.F90
    ftlm_neci.F90
    gdata_io.F90
    gen_coul.F90
    gen_coul_ueg.F90
    global_utilities.F90
    gndts_blk.F90
    gndts.F90
    gndwork.F90
    hash.F90
    hamiltonian_linalg.F90
    hdf5_popsfile.F90
    hdiag.F90
    hdiag_from_excit.F90
    HElem.F90
    hfbasis.F90
    HFCalc.F90
    hilbert_space_size.F90
    hist_data.F90
    HPHFRandExcit.F90
    hubbard.F90
    impurity_models.F90
    index_rhash.F90
    init_coul2D.F90
    init_coul.F90
    initial_trial_states.F90
    initiator_space_procs.F90
    input_parser_mod.F90
    IntegralsData.F90
    Integrals_neci.F90
    kp_fciqmc_data.F90
    kp_fciqmc.F90
    kp_fciqmc_init.F90
    kp_fciqmc_procs.F90
    kp_fciqmc_proj_est.F90
    lanczos_general.F90
    lanczos_wrapper.F90
    legacy_data.F90
    lineup.F90
    LMat_calc.F90
    LMat_class.F90
    LMat_freeze.F90
    LMat_indexing.F90
    LMat_mod.F90
    load_balance_calcnodes.F90
    LoggingData.F90
    Logging.F90
    Makefile
    matel_getter.F90
    matmul.F90
    modifiedHub.F90
    molcas_interface.F90
    MolproPlugin.F90
    PluginGuest.cpp
    NatOrbs.F90
    NECICore.F90
    neci_intfce.F90
    OneEInts.F90
    orthogonalise.F90
    Orthonorm.F90
    MPI_wrapper.F90
    Parallel_Calc.F90
    parallel_workarounds.F90
    pchb_excitgen.F90
    perturbations.F90
    Popsfile.F90
    Popsfile_impls.F90
    proc_ptrs.F90
    ras_data.F90
    ras.F90
    rdm_data.F90
    rdm_data_utils.F90
    rdm_estimators.F90
    rdm_explicit.F90
    rdm_filling.F90
    rdm_finalising.F90
    rdm_hdf5.F90
    rdm_integral_fns.F90
    rdm_nat_orbs.F90
    rdm_reading.F90
    readdf.F90
    readinput.F90
    readint.F90
    read_psi.F90
    readri.F90
    replica_data.F90
    replica_estimates.F90
    rhodiag.F90
    RhoElement.F90
    RotateOrbsData.F90
    RotateOrbs.F90
    RPA.F90
    scrtransf.F90
    searching.F90
    semi_stoch_gen.F90
    semi_stoch_procs.F90
    shared_rhash.F90
    sparse_arrays.F90
    spectral_data.F90
    spectral_lanczos.F90
    SymData.F90
    symexcit2.F90
    symexcit3.F90
    symexcit4.F90
    symexcitData.F90
    symexcit.F90
    sym.F90
    sym_general.F90
    GenRandSymExcitNUMod.F90
    symrandexcit3.F90
    symrandexcit_Ex_Mag.F90
    excit_gens_int_weighted.F90
    excit_gen_5.F90
    symrandexcit_ueg.F90
    SystemData.F90
    System_neci.F90
    tau/tau_main.F90
    tau/tau_main_impls.F90
    tau/tau_search_conventional.F90
    tau/tau_search_hist.F90
    tc_three_body_data.F90
    tc_three_body_excitgen.F90
    trial_wf_gen.F90
    trial_ht_procs.F90
    UMatCache.F90
    tc_precomputed_excitgen.F90
    unit_test_helper_excitgen.F90
    vasp_init.F90
    vasp_interface.F90
    vasp_neci_interface_stub.F90
    double_occ.F90
    real_space_hubbard.F90
    back_spawn.F90
    back_spawn_excit_gen.F90
    guga_main.F90
    guga_bitRepOps.F90
    guga_data.F90
    guga_excitations.F90
    guga_init.F90
    guga_write_H_matrix.F90
    guga_matrixElements.F90
    guga_procedure_pointers.F90
    guga_types.F90
    guga_plugin.F90
    guga_pchb_class.F90
    guga_crude_approx.F90
    lattice_mod.F90
    tJ_model.F90
    k_space_hubbard.F90
    lattice_models_utils.F90
    analyse_wf_symmetry.F90
    guga_rdm.F90
    unit_test_helpers.F90
    real_time_data.F90
    cc_amplitudes.F90
    cepa_shifts.F90
    real_time.F90
    real_time_aux.F90
    real_time_init.F90
    real_time_procs.F90
    real_time_read_input.F90
    verlet_aux.F90
    guga_pchb_excitgen.F90
    local_spin.F90
    CAS_distribution_init.F90
    excitation_generators.F90
    exc_gen_class_wrappers.F90
    exc_gen_classes.F90

    lib/constants.F90
    lib/dSFMT.cpp
    lib/dSFMT_interface.F90
    lib/environment_report.F90
    lib/error_handling_neci.F90
    lib/error_handling_neci_impls.F90
    lib/hdf5_util.F90
    lib/MemoryManagement.F90
    lib/signals.F90
    lib/signals_helper.cpp
    lib/soft_exit.F90
    lib/timing.F90
    lib/util_mod_fmt.F90
    lib/fortran_strings.F90
    lib/matrix_util.F90
    lib/display_matrices.F90
    lib/binomial_lookup.F90
    )

set( RELAX_WARNINGS_SRCS

    CalcData.F90
    Calc.F90
    cont_time_fcimc.F90
    cont_time_rates.F90
    core_space_util.F90
    CPMDData.F90
    davidson_neci.F90
    davidson_semistoch.F90
    default_sets.F90
    DetCalcData.F90
    DetCalc.F90
    determ_proj.F90
    direct_ci.F90
    enumerate_excitations.F90
    ErrorAnalysis.F90
    exact_diag.F90
    exact_spectrum.F90
    symexcit.F90
    excit.F90
    excit_parity.F90
    fast_determ_hamil.F90
    FciMCData.F90
    fcimc_helper.F90
    fcimc_iter_utilities.F90
    FciMCLogging.F90
    fcimc_output.F90
    FciMCPar.F90
    fcimc_pointed_fns.F90
    frsblk.F90
    ftlm_neci.F90
    gdata_io.F90
    gen_coul_ueg.F90
    global_utilities.F90
    gndts.F90
    gndwork.F90
    hash.F90
    hamiltonian_linalg.F90
    hdiag_from_excit.F90
    HElem.F90
    HFCalc.F90
    hilbert_space_size.F90
    hist_data.F90
    HPHFRandExcit.F90
    impurity_models.F90
    index_rhash.F90
    initial_trial_states.F90
    initiator_space_procs.F90
    IntegralsData.F90
    Integrals_neci.F90
    kp_fciqmc_data.F90
    kp_fciqmc.F90
    kp_fciqmc_init.F90
    kp_fciqmc_procs.F90
    kp_fciqmc_proj_est.F90
    lanczos_general.F90
    lanczos_wrapper.F90
    legacy_data.F90
    LMat_calc.F90
    LMat_class.F90
    LMat_freeze.F90
    LMat_indexing.F90
    LMat_mod.F90
    load_balance_calcnodes.F90
    LoggingData.F90
    Logging.F90
    modifiedHub.F90
    molcas_interface.F90
    MolproPlugin.F90
    NatOrbs.F90
    NECICore.F90
    neci_intfce.F90
    OneEInts.F90
    orthogonalise.F90
    Orthonorm.F90
    Parallel_Calc.F90
    parallel_workarounds.F90
    MPI_wrapper.F90
    pchb_excitgen.F90
    Popsfile.F90
    Popsfile_impls.F90
    proc_ptrs.F90
    ras_data.F90
    ras.F90
    rdm_data.F90
    rdm_data_utils.F90
    rdm_estimators.F90
    rdm_explicit.F90
    rdm_filling.F90
    rdm_finalising.F90
    rdm_integral_fns.F90
    rdm_nat_orbs.F90
    rdm_reading.F90
    readdf.F90
    readinput.F90
    readri.F90
    replica_data.F90
    replica_estimates.F90
    RhoElement.F90
    RotateOrbsData.F90
    RotateOrbs.F90
    RPA.F90
    scrtransf.F90
    searching.F90
    semi_stoch_procs.F90
    shared_rhash.F90
    sparse_arrays.F90
    spectral_data.F90
    spectral_lanczos.F90
    SymData.F90
    symexcit2.F90
    symexcit3.F90
    symexcit4.F90
    symexcitData.F90
    sym.F90
    sym_general.F90
    symrandexcit1.F
    GenRandSymExcitNUMod.F90
    symrandexcit3.F90
    symrandexcit_Ex_Mag.F90
    excit_gens_int_weighted.F90
    excit_gen_5.F90
    symrandexcit.F
    symrandexcit_ueg.F90
    SystemData.F90
    System_neci.F90
    tc_three_body_data.F90
    tc_three_body_excitgen.F90
    trial_wf_gen.F90
    trial_ht_procs.F90
    UMatCache.F90
    tc_precomputed_excitgen.F90
    unit_test_helper_excitgen.F90
    vasp_init.F90
    vasp_interface.F90
    vasp_neci_interface_stub.F90
    double_occ.F90
    analyse_wf_symmetry.F90
    guga_rdm.F90
    unit_test_helpers.F90
    real_time_data.F90
    cepa_shifts.F90
    real_time.F90
    real_time_aux.F90
    real_time_init.F90
    real_time_procs.F90
    real_time_read_input.F90
    verlet_aux.F90
    CAS_distribution_init.F90
    rdm_hdf5.F90

    # If this bug (https://gcc.gnu.org/bugzilla/show_bug.cgi?id=105594) in gfortran
    #  is resolved, we can have again stricter compilation options.
    tau/tau_main_impls.F90
    lib/error_handling_neci_impls.F90
    Determinants_impls.F90
)

set( FYPP_SRC_FILES
    growing_buffers.fpp
    fcimc_initialisation.fpp
    HPHFIntegrals.fpp
    sltcnd.fpp
    gasci.fpp
    gasci_discarding.fpp
    gasci_disconnected.fpp
    gasci_on_the_fly_heat_bath.fpp
    gasci_pchb_main.fpp
    gasci_singles_main.fpp
    gasci_singles_pc_weighted.fpp
    gasci_pchb_doubles_main.fpp
    gasci_pchb_doubles_select_particles.fpp
    gasci_pchb_doubles_spatorb_fastweighted.fpp
    gasci_pchb_doubles_spinorb_fullyweighted.fpp
    gasci_pchb_doubles_spinorb_fastweighted.fpp
    gasci_supergroup_index.fpp
    gasci_util.fpp
    CDF_sampling.fpp
    orb_idx.fpp
    excitation_types.fpp
    shared_array.fpp
    load_balancer.fpp
    global_det_data.fpp
    rdm_general.fpp
    hist.fpp
    lib/parallel_hdf5_utils.fpp
    lib/util_mod.fpp
    lib/basic_float_math.fpp
    sets_mod.fpp
    shared_ragged_array.fpp
    SD_spin_purification.fpp
    sdt_amplitudes.fpp
)

set( TEMPLATED_SRC_FILES

    BinSearch.F90.template
    Parallel.F90.template
    shared_memory_mpi.F90.template
    scalar_shared_memory_mpi.F90.template
    lib/quicksort.F90.template
    lib/util_mod_comparisons.F90.template
    lib/util_mod_cpts.F90.template
    lib/util_mod_numerical.F90.template
)


# ---------------------------------------------------------------------------------

# Don't use generator expressions for including libraries, as this causes problems when there are list
# expansions.
set( _conditional_libraries "" )
if (HAVE_FFTW)
    list(APPEND _conditional_libraries ${FFTW_LIBRARIES} )
endif()
if (HAVE_HDF5)
    list(APPEND _conditional_libraries ${HDF5_NECI_LIBRARIES} )
endif()
if (HAVE_TCHINT)
    list(APPEND _conditional_libraries ${TCHINT_NECI_LIBRARIES})
endif()

# ---------------------------------------------------------------------------------

set( _library_link_libs
    "${LAPACK_LIBRARIES}"
    "${LIBRT_LIBRARIES}"
    "${_conditional_libraries}"
    "${MPI_LIBRARIES}"
    "${MPI_Fortran_LIBRARIES}")

if( HAVE_SHARED )
    set( _link_type SHARED )
    set( _exe_link_libs "" )
else()
    set( _link_type STATIC )
    set( _exe_link_libs "${_library_link_libs}" )
endif()

# ---------------------------------------------------------------------------------
# Build the main parts as static libraries
# --> They don't need to be recompiled to be included in unit tests/python/...

foreach(_config ${${PROJECT_NAME}_CONFIGURATIONS})

    message(DEBUG "Adding library for configuration ${_config}")
    message(DEBUG "Library definitions: ${${PROJECT_NAME}_${_config}_DEFINITIONS}")
    neci_add_library(

        TARGET lib${_config}
        TYPE ${_link_type}
        OUTPUT_NAME ${_config}
        SOURCES ${SRC_FILES}
        RELAX_WARNINGS ${RELAX_WARNINGS_SRCS}
        TEMPLATED_SOURCES ${TEMPLATED_SRC_FILES}
        FYPP_SOURCES ${FYPP_SRC_FILES}
        LINKER_LANGUAGE Fortran

        PRIVATE_INCLUDES
            "${MPI_Fortran_INCLUDE_PATH}"
            "${HDF5_NECI_INCLUDE_PATH}"

        DEFINITIONS
            "${NECI_GLOBAL_DEFINES}"
            "${${PROJECT_NAME}_${_config}_DEFINITIONS}"
            "${HDF5_NECI_DEFINITIONS}"
            "${TCHINT_NECI_DEFINITIONS}"

        LIBS "${_library_link_libs}"
        WARNERR ${${PROJECT_NAME}_${_config}_WARNERR}
    )

    message(DEBUG "Adding executable for configuration ${_config}")
    neci_add_executable(
        TARGET ${_config}
        SOURCES necimain.F90
        LIBS
            lib${_config}
            "${_exe_link_libs}"

        LINKER_LANGUAGE Fortran
    )

endforeach()
