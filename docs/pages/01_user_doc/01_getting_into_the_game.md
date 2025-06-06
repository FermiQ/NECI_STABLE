---
title: Installation
---


## Getting the Code


There are two git repositories for NECI. The stable release is available publicly on github, [here](https://github.com/ghb24/NECI_STABLE).
The developer version is on a private repository on bitbucket, for which you need to be invited to see.
The Github version is not updated as frequently, so if you wish to use the latest methods, contact the developers.

### BitBucket Repository Access

To gain access, contact one of the repository administrators [Oskar Weser
([o.weser@fkf.mpg.de](mailto:o.weser@fkf.mpg.de)) and Werner Dobrautz
([w.dobrautz@fkf.mpg.de](mailto:w.dobrautz@fkf.mpg.de))] who will invite you. If you
already have a bitbucket account let the repository administrators know
the email address associated with your account.

You will receive an invitation email. Please accept this invitation, and
create a bitbucket account as prompted if necessary.

To gain access to the NECI repository, an ssh key is required. This can
be generated on any linux machine using the command\footnote{`ssh-keygen` can also generate DSA keys. Some ssh clients and servers will reject DSA keys longer than 1024 bits, and 1024 bits is	currently on the margin of being crackable. As such 2048 bit RSA keys are preferred. Top secret this code is. Probably. Apart from the master branch which hosted for all on github. And in molpro.	And anyone that wants it obviously.}
<!-- todo is this sassy footnote really necessary? :D -->

```bash
ssh-keygen -t rsa -b 2048
```

This will create a private (`~/.ssh/id_rsa`) and a public key file
(`~/.ssh/id_rsa.pub`).

The private key must be kept private. On the bitbucket homepage, go to
account settings (accessible from the top-right of the main page), and
navigate to “SSH keys”. Click “Add key” and add the contents of the
public key. This will give you access to the repository.

You can now clone the code into a new directory using the command

```bash
git clone git@bitbucket.org:neci_developers/neci.git [target_dir]
```

## NECI Installation

Installation of NECI requires\footnote{If you are on a cluster, you may need to run a command similar to `module load ifort mpi.intel`.}

-   git,
-   cmake 3.12 or newer,
-   BLAS/LAPACK,
-   MPI 3,
-   a Fortran compiler supporting Fortran 2003 features, and
-   HDF5 (is optional, but strongly recommended and has to be explicitly switched off).

To get started, we must first clone the repository, with
```bash
git clone https://github.com/ghb24/NECI_STABLE.git
```
for the public release, or
```bash
git clone https://<username>@bitbucket.org/neci_developers/neci.git
```
for the developer release (replace `<username>` with your bitbucket username).
The directory of this repository will be referred to as "`your_code_directory`".

Next, create a directory (let's call it "`your_build_directory`"), then run cmake and then make:
```bash
mkdir build
cd build
cmake -DENABLE_HDF5=ON -DENABLE_BUILD_HDF5=ON ${your_code_directory}
make -j
```
@note
If you are making without HDF5, then set the option `-DENABLE_HDF5=OFF` instead.
@endnote

Sometimes it is necessary to pass in the desired MPI compilers.
In particular if several MPI implementations are availabe on the system, then `cmake` might pick up the wrong ones.
To explicitly select the correct MPI pass
```bash
-DCMAKE_Fortran_COMPILER=... -DCMAKE_C_COMPILER=... -DCMAKE_CXX_COMPILER=...
```
with appropiate paths to `cmake`.
In the case of GNU compilers that are already in your path it would look like this:
```bash
-DCMAKE_Fortran_COMPILER=`which mpifort` \
-DCMAKE_C_COMPILER=`which mpicc` \
-DCMAKE_CXX_COMPILER=`which mpicxx`
```

If you want to link against an existing HDF5 library instead of rebuilding it everytime,
then follow the instructions in the next section on how to correctly compile HDF5 with parallel support
and set `HDF5_ROOT` as environment variable pointing to the installation directory of HDF5.
A full command would look like this:

```bash
HDF5_ROOT=~/lib/hdf5-1.8.20_gfort_mpi \
cmake -DENABLE_HDF5=ON \
-DCMAKE_Fortran_COMPILER=mpifort \
-DCMAKE_C_COMPILER=mpicc \
-DCMAKE_CXX_COMPILER=mpicxx ~/code/neci
```


## HDF5

You may also need to build HDF5 yourself as a shared library,
which speeds up the compilation process, since HDF5 does not have to be rebuilt for every new project.
@note
HDF5 should be built with the same set of compilers as NECI.
@endnote

In this case, download and extract the program from the HDF5 group website ([download link for v1.12](https://support.hdfgroup.org/ftp/HDF5/releases/hdf5-1.12/hdf5-1.12.2/src/hdf5-1.12.2.tar.gz)),
then build with parallel IO and Fortran Support enabled.
You may replace the compilers if you wish, for example use GNU `mpifort` or Intel `mpiifort`.

The `cmake` command is:
```bash
cd your_build_directory
HDF5_SRC= # The HDF5 source
HDF5_ROOT= # Where it should be installed

cmake \
    -DCMAKE_INSTALL_PREFIX:PATH=${HDF5_ROOT} \
    -DHDF5_ENABLE_PARALLEL:BOOL=ON  \
    -DHDF5_BUILD_FORTRAN:BOOL=ON
    -DCMAKE_Fortran_COMPILER:PATH=`which mpifort` \
    -DCMAKE_C_COMPILER:PATH=`which mpicc` \
    ${HDF5_SRC}
make -j
make install
```
The `configure` command for older HDF5 versions is:
```bash
cd your_build_directory
cd your_build_directory
HDF5_SRC= # The HDF5 source
HDF5_ROOT= # Where it should be installed

FC=mpifort F9X=mpifort CC=mpicc ${HDF5_SRC}/configure \
    --prefix=${HDF5_ROOT} --enable-fortran --enable-fortran2003 --enable-parallel
make
make install
```
where you define `HDF5_SRC` and `HDF5_ROOT` appropriately. Then, before running `cmake` for NECI, run

```bash
export HDF5_ROOT= # where HDF5 was installed in the previous step
```

and proceed with the NECI installation as before,
```bash
mkdir build
cd build
cmake -DENABLE_HDF5=ON ${your_code_directory}
make -j
```

## Documentation

If you wish to generate documentation for NECI, based on [Ford](https://github.com/Fortran-FOSS-Programmers/ford),
then when you build with CMake, you must also include the flag `-DENABLE_DOC=ON`, for example
```
mkdir build
cd build
cmake -DENABLE_DOC=ON ${your_code_directory}
make -j doc
```

Requirements to produce the docs are:

- pandoc,
- latexmk,
- pdflatex,
- biber, and
- a working internet connection (only for the first time, in order to get a custom-build of Ford).

This will not only generate this documentation in the form of a PDF, but also as a website,
having in addition to the information in the PDF also automatically generated documentation from comments in the source files.

<!-- todo ? should we include brief descriptions of all (important) build options? -->
