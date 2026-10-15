CC ?= gcc
CFLAGS ?= -O2 -Wall -Wextra
LDFLAGS ?= -lm

REPO_ROOT := $(abspath $(dir $(lastword $(MAKEFILE_LIST)))/../..)
CROSS_CC ?= $(REPO_ROOT)/vendor/system/prebuilts/toolchains/mips-gcc720-glibc238/bin/mips-linux-gnu-gcc
CROSS_STRIP ?= $(REPO_ROOT)/vendor/system/prebuilts/toolchains/mips-gcc720-glibc238/bin/mips-linux-gnu-strip
CROSS_CFLAGS ?= -EL -static -O2 -Wall -Wextra
CROSS_LDFLAGS ?= -lm

TARGET = rosetteos-bootanim
OVERLAY_TARGET = $(REPO_ROOT)/scripts/build/overlay/usr/bin/$(TARGET)

all: $(TARGET)

$(TARGET): rosetteos-bootanim.c
	$(CC) $(CFLAGS) -o $@ $< $(LDFLAGS)

mips: rosetteos-bootanim.c
	@if [ -x "$(CROSS_CC)" ]; then \
		$(CROSS_CC) $(CROSS_CFLAGS) -o $(TARGET)-mips $< $(CROSS_LDFLAGS); \
		$(CROSS_STRIP) -s $(TARGET)-mips; \
		mkdir -p $(dir $(OVERLAY_TARGET)); \
		cp $(TARGET)-mips $(OVERLAY_TARGET); \
		chmod +x $(OVERLAY_TARGET); \
		echo "Built and installed $(OVERLAY_TARGET)"; \
	else \
		echo "Cross compiler $(CROSS_CC) not found"; \
		exit 1; \
	fi

clean:
	rm -f $(TARGET) $(TARGET)-mips

.PHONY: all mips clean
