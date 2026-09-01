#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOCKER_IMAGE="tailbench_noavx_glibc"
CKPT_NS=3000000000

echo "============================================================"
echo "  Generating Checkpoints for ALL Tailbench Apps (3s, 10M insts prep)"
echo "============================================================"

docker run -i --rm --privileged \
    -v "$SCRIPT_DIR":/workspace \
    "$DOCKER_IMAGE" /bin/bash << 'EOF'
set -euo pipefail

NOAVX_GLIBC='/opt/glibc-noavx'
CKPT_NS=3000000000
DATA_ROOT='/workspace/Tailbench/tailbench.inputs'
SCRATCH_DIR='/workspace/scratch'
mkdir -p $SCRATCH_DIR

# 1 thread for gem5 SE mode predictability
THREADS=1

apps=('masstree' 'moses' 'shore' 'silo' 'sphinx' 'xapian' 'img-dnn')

echo "============================================================"
echo "  Rebuilding libckpt.so"
echo "============================================================"
cd /workspace
gcc -O2 -g -Wall -fPIC -mno-avx -mno-avx2 -mno-avx512f -c src/dumper.c -o build/dumper_pic.o -Isrc
gcc -O2 -g -Wall -fPIC -shared -mno-avx -mno-avx2 -mno-avx512f -o build/libckpt.so src/libckpt.c build/dumper_pic.o -Isrc -ldl -lpthread

for APP in "${apps[@]}"; do
    echo ''
    echo '============================================================'
    echo "  [$APP] Generating Checkpoint"
    echo '============================================================'
    
    APP_DIR="/workspace/Tailbench/tailbench/$APP"
    cd $APP_DIR
    CKPT_FILE="${APP}_noavx_3s.ckpt"
    
    # Remove old checkpoint if exists
    rm -f $CKPT_FILE
    
    # Base library path with NO-AVX glibc overriding system glibc
    LIB_PATH="$NOAVX_GLIBC/lib:/lib/x86_64-linux-gnu:/usr/lib/x86_64-linux-gnu"
    
    # Enough requests to last well past the 3s warmup and the 10M inst ROI
    MAXREQS=10000000
    WARMUPREQS=100
    QPS=500
    
    # App specific configurations
    case "$APP" in
        'masstree')
            BIN='./mttest_integrated'
            ARGS="-j${THREADS} mycsba masstree"
            ;;
        'moses')
            BIN='./bin/moses_integrated'
            cp moses.ini.template moses.ini
            sed -i -e "s#@DATA_ROOT#$DATA_ROOT#g" moses.ini
            ARGS="-config ./moses.ini -input-file $DATA_ROOT/moses/testTerms -threads ${THREADS} -num-tasks 100000 -verbose 0"
            ;;
        'shore')
            BIN='shore-kits/shore_kits_integrated'
            rm -rf scratch log diskrw cmdfile db-tpcc-1 shore.conf
            TMP=$(mktemp -d --tmpdir=${SCRATCH_DIR})
            ln -s $TMP scratch
            mkdir scratch/log && ln -s scratch/log log
            mkdir scratch/diskrw && ln -s scratch/diskrw diskrw
            cp ${DATA_ROOT}/shore/db-tpcc-1 scratch/ && ln -s scratch/db-tpcc-1 db-tpcc-1
            chmod 644 scratch/db-tpcc-1
            cp shore-kits/run-templates/cmdfile.template cmdfile
            sed -i -e "s#@NTHREADS#${THREADS}#g" cmdfile
            sed -i -e "s#@REQS#1000000#g" cmdfile
            cp shore-kits/run-templates/shore.conf.template shore.conf
            sed -i -e "s#@NTHREADS#${THREADS}#g" shore.conf
            ARGS="-i cmdfile"
            ;;
        'silo')
            BIN='./out-perf.masstree/benchmarks/dbtest_integrated'
            ARGS="--bench tpcc --num-threads ${THREADS} --scale-factor 1 --retry-aborted-transactions --ops-per-worker 100000"
            LIB_PATH="$NOAVX_GLIBC/lib:$APP_DIR/third-party/lz4:/lib/x86_64-linux-gnu:/usr/lib/x86_64-linux-gnu"
            ;;
        'sphinx')
            BIN='./decoder_integrated'
            ARGS="-t ${THREADS}"
            export TBENCH_AN4_CORPUS=${DATA_ROOT}/sphinx
            export TBENCH_AUDIO_SAMPLES=audio_samples
            LIB_PATH="$NOAVX_GLIBC/lib:$APP_DIR/sphinx-install/lib:/lib/x86_64-linux-gnu:/usr/lib/x86_64-linux-gnu"
            ;;
        'xapian')
            BIN='./xapian_integrated'
            ARGS="-n ${THREADS} -d ${DATA_ROOT}/xapian/wiki -r 1000000000"
            export TBENCH_TERMS_FILE=${DATA_ROOT}/xapian/terms.in
            LIB_PATH="$NOAVX_GLIBC/lib:$APP_DIR/xapian-core-1.2.13/install/lib:/lib/x86_64-linux-gnu:/usr/lib/x86_64-linux-gnu"
            ;;
        'img-dnn')
            BIN='./img-dnn_integrated'
            ARGS="-r ${THREADS} -f ${DATA_ROOT}/img-dnn/models/model.xml -n 100000000"
            export TBENCH_MNIST_DIR=${DATA_ROOT}/img-dnn/mnist
            ;;
    esac

    echo "Launching $APP..."
    env \
        LD_PRELOAD="/workspace/build/libckpt.so" \
        TBENCH_QPS=$QPS \
        TBENCH_MAXREQS=$MAXREQS \
        TBENCH_WARMUPREQS=$WARMUPREQS \
        CKPT_OUTPUT="$APP_DIR/$CKPT_FILE" \
        CKPT_AFTER_NS="$CKPT_NS" \
    "$NOAVX_GLIBC/lib/ld-linux-x86-64.so.2" \
        --library-path "$LIB_PATH" \
        $BIN $ARGS 2>&1 | tail -60 || true
        
    if [[ -f "$CKPT_FILE" ]]; then
        chmod 644 "$CKPT_FILE" || true
        echo "[SUCCESS] Checkpoint generated for $APP"
        ls -lh "$CKPT_FILE"
    else
        echo "[ERROR] Checkpoint failed for $APP"
    fi
done
EOF

echo "============================================================"
echo "  All checkpoints generated."
echo "  Syncing to azha and launching gem5 tests..."
echo "============================================================"

# Sync to remote
rsync -avz --progress \
    --exclude '.git/' \
    --exclude 'm5out/' \
    ./ azha:proyectos_personales/checkpoint_maquina_real/real_machine_checkpoint/

echo ""
echo "Creating remote script to run all tests..."
ssh azha "cat > proyectos_personales/checkpoint_maquina_real/real_machine_checkpoint/run_all_gem5.sh << 'EOF'
#!/bin/bash
apps=(\"masstree\" \"moses\" \"shore\" \"silo\" \"sphinx\" \"xapian\" \"img-dnn\")
cd proyectos_personales/checkpoint_maquina_real/real_machine_checkpoint

for APP in \"\${apps[@]}\"; do
    CKPT=\"Tailbench/tailbench/\$APP/\${APP}_noavx_3s.ckpt\"
    if [[ -f \"\$CKPT\" ]]; then
        echo \"============================================================\"
        echo \"  Running gem5 for \$APP (10M insts)\"
        echo \"============================================================\"
        ./run_gem5.sh \"\$CKPT\" --cpu o3 --maxinsts 10000000 > m5out/\${APP}_run.log 2>&1
        echo \"Done \$APP. Stats:\"
        grep -E 'simInsts|simSeconds|system.cpu.cpi|system.cpu.ipc' m5out/stats.txt || true
        cp m5out/stats.txt m5out/\${APP}_stats.txt
    else
        echo \"Skipping \$APP (checkpoint not found)\"
    fi
done
EOF
chmod +x proyectos_personales/checkpoint_maquina_real/real_machine_checkpoint/run_all_gem5.sh
"

echo "============================================================"
echo "  Ready! You can now run the remote script on azha:"
echo "  ssh azha 'cd proyectos_personales/checkpoint_maquina_real/real_machine_checkpoint && ./run_all_gem5.sh'"
echo "============================================================"
