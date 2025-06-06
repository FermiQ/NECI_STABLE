#!/bin/sh

# This script provides the module configurations for the test machine on altest
#
# Usage:
#    auto_module.sh <config_file_name>

source /usr/share/Modules/3.2.10/init/sh
export MODULEPATH="${MODULEPATH}:/usr/local/fkf/modules"
module purge

echo "Loading modules for: $@"

if [ "ifort-debug" == "$@" ] || [ "ifort" == "$@" ]; then
    export HDF5_ROOT=/opt/hdf-1.12.2_ifort19_mpi
    export FI_PROVIDER=sockets
    module load ifort/19.1.1 mpi.intel/2019.7
elif [ "ifort18-debug" == "$@" ] || [ "ifort18" == "$@" ]; then
    export HDF5_ROOT=/opt/hdf-1.12.2_ifort18_mpi
    source /usr/local/server/IntelStudio_2018/parallel_studio_xe_2018.4.057/psxevars.sh intel64
elif [ "gfortran-debug" == "$@" ] || [ "gfortran-fastdebug" == "$@" ] || [ "gfortran" == "$@" ] || [ "gfortran-short-doc" == "$@" ] || [ "gfortran-doc" == "$@" ] || [ "gfortran-debug-integer8" == "$@" ]; then
    export HDF5_ROOT=/opt/hdf-1.12.2_gfort7_mpi
    module load gnu-openmpi/3.1.6
elif [ "gfortran-self_build_hdf5" == "$@" ] || [ "gfortran-debug-nohdf5" == "$@" ]; then
    module load gnu-openmpi/3.1.6
else
	echo "Module configuration not set"
fi
