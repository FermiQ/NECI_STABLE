# Special defines for Intel fortran compiler

# set( Tailored_Warnings "-warn nounused -warn all")
set( ${PROJECT_NAME}_Fortran_FLAGS "-fPIC -g")
set( ${PROJECT_NAME}_Fortran_FLAGS_DEBUG "-O0 -check all,noarg_temp_created -traceback -fpe0 -init=arrays,snan" )
set( ${PROJECT_NAME}_Fortran_FLAGS_FASTDEBUG "${${PROJECT_NAME}_Fortran_FLAGS_DEBUG}" )
set( ${PROJECT_NAME}_Fortran_FLAGS_RELEASE "-O3 -xHost -align array64byte" )
set( ${PROJECT_NAME}_Fortran_FLAGS_CLUSTER "-ipo" )

# Warning flags ...

# It would be nice to be able to check intrfaces, but there are too many instances where they are wrong
# in NECI, and not adding this causes compilation failures
set( ${PROJECT_NAME}_Fortran_WARNING_FLAGS "-warn all -diag-disable=remark" )
set( ${PROJECT_NAME}_Fortran_relaxed_WARNING_FLAGS "-warn nointerfaces,nounused,notruncated_source" )

# Treat errors as warnings
set( ${PROJECT_NAME}_Fortran_WARN_ERROR_FLAG "-warn errors")

# Linker flags

set( ${PROJECT_NAME}_Fortran_LINKER_FLAGS_CLUSTER "-ipo" )

# A particular ifort fix (I can't find any other reference to this CMake variable...)

# -i_dynamic is incorrectly added in CMake ifort configuration
set(CMAKE_SHARED_LIBRARY_LINK_Fortran_FLAGS "")

# Treat 32bit/64bit compilation differently

set( ${PROJECT_NAME}_32BIT_Fortran_FLAGS "-m32" )

set( ${PROJECT_NAME}_64BIT_Fortran_FLAGS "-m64" )
