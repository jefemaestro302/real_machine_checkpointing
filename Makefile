# Makefile for checkpoint/restore PoC
# Context: gem5 SE mode, static binaries, x86-64, single-thread, no ASLR
#
# Targets:
#   all         - build everything
#   target_app  - the "Tailbench-like" app that dumps its state
#   loader      - the custom restorer (execv target)
#   run_demo    - full demo: dump + restore on real Linux
#   clean       - remove build artifacts

CC      := gcc
CFLAGS  := -O2 -g -Wall -Wextra -fno-stack-protector -mno-avx -mno-avx2 -mno-sse3 -mno-ssse3 -mno-sse4.1 -mno-sse4.2 -fno-builtin
LDFLAGS := -static

# -----------------------------------------------------------------------
# The loader MUST be linked at a VA that does NOT collide with the target.
# The default text segment for static x86-64 binaries is ~0x400000.
# We put the loader at 0x20000000 (512 MB) which is safely above any
# typical single-binary layout.
# Adjust this if your target binary uses a custom linker script.
# -----------------------------------------------------------------------
LOADER_LOAD_ADDR := 0x20000000

# Source files
TARGET_SRCS  := src/target_app.c src/dumper.c
LOADER_SRCS  := src/loader.c
LIBCKPT_SRCS := src/libckpt.c src/dumper.c

# Output directory
BUILD_DIR := build

.PHONY: all clean run_demo verify_dump disasm_target disasm_loader

all: $(BUILD_DIR)/target_app $(BUILD_DIR)/loader $(BUILD_DIR)/libckpt.so

$(BUILD_DIR):
	mkdir -p $(BUILD_DIR)

# --- Target application ---------------------------------------------------
# Linked at default address (0x400000).
# In a real gem5 scenario this is your Tailbench binary.
$(BUILD_DIR)/target_app: $(TARGET_SRCS) src/checkpoint.h src/dumper.h | $(BUILD_DIR)
	$(CC) $(CFLAGS) $(LDFLAGS) \
		-no-pie \
		-o $@ $(TARGET_SRCS)
	@echo "Built target_app at $@"
	@echo "Text segment:"
	@readelf -S $@ | grep " \.text"

# --- Custom Loader --------------------------------------------------------
# Linked at LOADER_LOAD_ADDR to avoid VA collision with the target app.
#
# CRITICAL FLAGS:
#  -no-pie            : we need a known load address
#  -Wl,-Ttext=...     : move .text to the high address
#  -static            : no dynamic linking (gem5 SE mode requirement)
#  -fno-stack-protector: no canary (would need its own TLS init)
$(BUILD_DIR)/loader: $(LOADER_SRCS) src/checkpoint.h | $(BUILD_DIR)
	$(CC) $(CFLAGS) $(LDFLAGS) \
		-no-pie \
		-Wl,-Ttext-segment=$(LOADER_LOAD_ADDR) \
		-o $@ $(LOADER_SRCS)
	@echo "Built loader at $@"
	@echo "Loader load address check:"
	@readelf -l $@ | grep LOAD | head -3

# --- Generic LD_PRELOAD checkpoint library ---------------------------------
# Shared library: requires -fPIC on all compiled objects.
# dumper.c is recompiled as PIC separately (dumper_pic.o).
$(BUILD_DIR)/dumper_pic.o: src/dumper.c src/checkpoint.h src/dumper.h | $(BUILD_DIR)
	$(CC) $(CFLAGS) -fPIC -c -o $@ src/dumper.c

$(BUILD_DIR)/libckpt.so: src/libckpt.c $(BUILD_DIR)/dumper_pic.o src/checkpoint.h | $(BUILD_DIR)
	$(CC) $(CFLAGS) -fPIC -shared \
		-o $@ src/libckpt.c $(BUILD_DIR)/dumper_pic.o \
		-ldl -lpthread
	@echo "Built libckpt.so at $@"
	@echo "Usage: CKPT_OUTPUT=dump.ckpt LD_PRELOAD=$@ ./your_app"
	@echo "       kill -SIGUSR1 <pid>  (or set CKPT_AFTER_NS=<nanoseconds>)"

# --- Demo: full round-trip ------------------------------------------------
DUMP_FILE := /tmp/test.ckpt

run_demo: $(BUILD_DIR)/target_app $(BUILD_DIR)/loader
	@echo ""
	@echo "============================================================"
	@echo "  STEP 1: Run target_app (init + checkpoint dump + ROI)"
	@echo "============================================================"
	$(BUILD_DIR)/target_app $(DUMP_FILE)
	@echo ""
	@echo "Dump file info:"
	@ls -lh $(DUMP_FILE)
	@echo ""
	@echo "============================================================"
	@echo "  STEP 2: Restore via loader (ROI only, no init)"
	@echo "============================================================"
	$(BUILD_DIR)/loader $(DUMP_FILE)

# --- Verify dump file consistency -----------------------------------------
verify_dump: $(BUILD_DIR)/target_app
	@echo "Generating dump for verification..."
	$(BUILD_DIR)/target_app $(DUMP_FILE)
	@echo ""
	@echo "Dump header (first 256 bytes as hex):"
	@xxd $(DUMP_FILE) | head -16

# --- Disassembly helpers --------------------------------------------------
disasm_target: $(BUILD_DIR)/target_app
	objdump -d $< | less

disasm_loader: $(BUILD_DIR)/loader
	objdump -d $< | less

# --- Show memory layout of both binaries ----------------------------------
show_layout: $(BUILD_DIR)/target_app $(BUILD_DIR)/loader
	@echo "=== target_app segments ==="
	readelf -l $(BUILD_DIR)/target_app | grep -A1 "LOAD"
	@echo ""
	@echo "=== loader segments ==="
	readelf -l $(BUILD_DIR)/loader | grep -A1 "LOAD"

clean:
	rm -rf $(BUILD_DIR)
	rm -f $(DUMP_FILE)
	@echo "Cleaned."
