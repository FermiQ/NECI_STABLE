#!/bin/bash

for f in *; do
    if [ -d "${f}" ]; then
        cd "${f}"

        rm -f test.*
        rm -f FCIMCStats*
        rm -f fciqmc_stats*
        rm -f INITIATORStats
        rm -f HAMIL
        rm -f TMAT
        rm -f UMAT
        rm -f NodeFile*
        rm -f Blocks_*
        rm -f ENERGIES
        rm -f MCPATHS
        rm -f RDM*
        rm -f Two*
        rm -f OneRDM
        rm -f spinfree_TwoRDM
        rm -f CLASS*
        rm -f InitPops*
        rm -f ORBOCC*
        rm -f hamil.*
        rm -f overlap.*
        rm -f lowdin.*
        rm -f gram_schmidt.*
        rm -f POPS_NORM
        rm -f DETS
        rm -f SpaceMCStats
        rm -f SPECTRAL_DATA
        rm -f FTLM_EIGV
        rm -f fciqmc_data*
        rm -f EIGV_DATA
        rm -f NO_*
	rm -f contribs_guga.*
	rm -f pgen_vs_matrixElements.*
	rm -f fort.*
	rm -f frequency_histog*
	rm -f double_occu*

        cd ..
    fi
done
