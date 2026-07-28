# SPDX-License-Identifier: BSD-2-Clause-Views

ifneq ($(KERNELRELEASE),)

MQNIC_DIR ?= $(src)/../mqnic
SSR_SRC_DIR ?= $(src)/../..

KBUILD_EXTRA_SYMBOLS := $(MQNIC_DIR)/Module.symvers

ccflags-y += -I$(MQNIC_DIR)
ccflags-y += -I$(SSR_INCLUDE_DIR)

obj-m += mqnic_app_ssr.o

else

ifneq ($(KERNEL_SRC),)
KDIR ?= $(KERNEL_SRC)
endif

KDIR ?= /lib/modules/$(shell uname -r)/build
PWD := $(shell pwd)

PROJECT_ROOT := $(abspath $(PWD)/../..)
CORUNDUM_MQNIC_DIR := $(PROJECT_ROOT)/corundum/modules/mqnic

BUILD_DIR := $(PWD)/build
MQNIC_DIR := $(BUILD_DIR)/mqnic
SSR_BUILD_DIR := $(BUILD_DIR)/mqnic_app_ssr
PATCH_DIR := $(PWD)/patches

.PHONY: all prepare-mqnic patch-mqnic mqnic prepare-ssr modules clean clean-ssr clean-mqnic distclean help

all: modules

prepare-mqnic:
	mkdir -p $(BUILD_DIR)
	rsync -a --delete $(CORUNDUM_MQNIC_DIR)/ $(MQNIC_DIR)/

patch-mqnic: prepare-mqnic
	@if [ -d "$(PATCH_DIR)" ]; then \
		for p in $(PATCH_DIR)/*.patch; do \
			if [ -f "$$p" ]; then \
				echo "Applying patch $$p"; \
				patch -d $(MQNIC_DIR) -p0 -N < "$$p" || true; \
			fi; \
		done; \
	fi

mqnic: patch-mqnic
	$(MAKE) -C $(MQNIC_DIR) KDIR=$(KDIR)

prepare-ssr:
	mkdir -p $(SSR_BUILD_DIR)
	ln -sf $(PWD)/mqnic_app_ssr.c $(SSR_BUILD_DIR)/mqnic_app_ssr.c
	ln -sf $(PWD)/Makefile $(SSR_BUILD_DIR)/Makefile

modules: mqnic prepare-ssr
	$(MAKE) -C $(KDIR) M=$(SSR_BUILD_DIR) modules

clean-ssr:
	@if [ -d "$(SSR_BUILD_DIR)" ]; then \
		$(MAKE) -C $(KDIR) M=$(SSR_BUILD_DIR) clean; \
	fi

clean-mqnic:
	@if [ -d "$(MQNIC_DIR)" ]; then \
		$(MAKE) -C $(MQNIC_DIR) KDIR=$(KDIR) clean; \
	fi

clean: clean-ssr

distclean:
	rm -rf $(BUILD_DIR)

help:
	$(MAKE) -C $(KDIR) M=$(SSR_BUILD_DIR) help

endif
