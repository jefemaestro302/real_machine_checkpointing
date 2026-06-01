#!/bin/bash
# This script helps you use the Docker container to compile Tailbench

CONTAINER_NAME="tailbench_compiler"

# Build the image (asegúrate de haber añadido libssl-dev al Dockerfile antes)
docker build -t ${CONTAINER_NAME} .

# Run the compilation using a Heredoc
docker run --rm -i \
    -v $(pwd)/../Repos/Tailbench:/tailbench \
    ${CONTAINER_NAME} \
    /bin/bash << 'EOF'

echo "Configurando entorno Tailbench..."
REAL_JDK=$(dirname $(dirname $(readlink -f /usr/bin/javac)))
echo "JDK_PATH=$REAL_JDK" > /tailbench/tailbench/Makefile.config
echo "DOCKER_CXXFLAGS=-O3 -g -msse2 -mno-avx -mno-avx2 -mno-avx512f -fpermissive" >> /tailbench/tailbench/Makefile.config
echo "DOCKER_LDFLAGS=-static-libgcc -static-libstdc++" >> /tailbench/tailbench/Makefile.config

echo "Arreglando configuración global de Xapian..."
find /tailbench/tailbench -name "xapian-config" -exec sed -i 's|/home/tailbench/Tailbench/tailbench|/tailbench/tailbench|g' {} +

echo "Configurando Sphinx a prueba de bombas..."
# 1. Reescribimos la variable 'prefix' dentro de los .pc de Sphinx para apuntar a la ruta exacta actual.
find /tailbench/tailbench/sphinx -name "*.pc" -exec sed -i -E 's|^prefix=.*|prefix=/tailbench/tailbench/sphinx/sphinx-install|g' {} +

# 2. Copiamos todos los .pc de TailBench a la ruta del sistema.
# De esta forma, pkg-config los encontrará SIEMPRE, sin importar qué haga el Makefile.
mkdir -p /usr/lib/pkgconfig /usr/share/pkgconfig
find /tailbench/tailbench -name "*.pc" -exec cp {} /usr/lib/pkgconfig/ \;

echo "Parcheando macros C++11 en Xapian..."
cd /tailbench/tailbench/xapian/xapian-core-1.2.13
find queryparser/ -type f -exec sed -i 's/"OP_TXT"/" OP_TXT "/g' {} +

echo "Pre-compilando Xapian Core..."
./configure --prefix=/tailbench/tailbench/xapian/xapian-core-1.2.13/install --disable-shared --enable-static
make && make install

echo "Limpiando compilaciones previas..."
cd /tailbench/tailbench && ./clean.sh

echo "Ejecutando build.sh principal de TailBench..."
cd /tailbench/tailbench && ./build.sh
EOF
