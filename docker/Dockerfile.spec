# =============================================================================
# Dockerfile.spec - Imagen gem5_noavx_env: toolchain para compilar SPEC CPU2017
# sin AVX con specs/config/gem5_noavx.cfg (gcc-11, g++-11, gfortran-11).
#
# Es la unica forma de compilar SPEC en este proyecto (siempre en local, nunca
# en el cluster). generate_all_spec_checkpoints.sh la construye si no existe:
#
#   docker build -f docker/Dockerfile.spec -t gem5_noavx_env:latest docker/
#
# Ubuntu 22.04 (glibc 2.35): los binarios SPEC son dinamicos y se ejecutan
# fuera del contenedor para generar los checkpoints, asi que el host necesita
# glibc >= 2.35 (Ubuntu 22.04 o posterior).
#
# SPEC trae sus propias herramientas (specperl, specmake...) en el arbol
# instalado; la imagen solo aporta los compiladores.
# =============================================================================
FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
        gcc-11 g++-11 gfortran-11 \
        make binutils libc6-dev \
        xz-utils bzip2 ca-certificates procps file \
    && rm -rf /var/lib/apt/lists/*

# Se ejecuta con --user del host (los ficheros de specs/ quedan del usuario):
# HOME escribible para las herramientas de SPEC
ENV HOME=/tmp
WORKDIR /spec2017
CMD ["/bin/bash"]
