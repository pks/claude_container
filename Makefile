GPU_ARCH := $(shell nvidia-smi --query-gpu=compute_cap --format=csv,noheader | head -1 | awk -F. '{v=$$1*10+$$2; if(v>=100) print "blackwell"; else if(v>=80) print "ampere"; else print "turing"}')
CUDA_VERSION := $(if $(filter blackwell,$(GPU_ARCH)),cu130,cu126)

IMAGE     ?= claude-container
STATE_DIR ?= $(CURDIR)/state
PROFILE   ?= claude
GPU       ?= all

.PHONY: image seed reseed run

image:
	@echo "Detected GPU_ARCH=$(GPU_ARCH) CUDA_VERSION=$(CUDA_VERSION)"
	docker build \
		--build-arg USERNAME=ubuntu \
		--build-arg USER_UID=$$(id -u) \
		--build-arg USER_GID=$$(id -g) \
		--build-arg GPU_ARCH=$(GPU_ARCH) \
		--build-arg CUDA_VERSION=$(CUDA_VERSION) \
		-t $(IMAGE) \
		.

# First-time seed: copy /workspace and /home/ubuntu out of the image into
# $(STATE_DIR) and drop in the host's plan/PLAN.md. Skipped if $(STATE_DIR)
# is already populated — use `make reseed` to wipe and redo (which you'll
# want after image rebuilds that touch /home/ubuntu).
seed: image
	@mkdir -p $(STATE_DIR)/workspace $(STATE_DIR)/home
	@if [ -n "$$(ls -A $(STATE_DIR)/workspace 2>/dev/null)" ] || [ -n "$$(ls -A $(STATE_DIR)/home 2>/dev/null)" ]; then \
	  echo "$(STATE_DIR) is already seeded — run 'make reseed' to wipe and redo"; \
	else \
	  echo "seeding $(STATE_DIR) from $(IMAGE)"; \
	  cid=$$(docker create $(IMAGE)) \
	    && docker cp $$cid:/workspace/. $(STATE_DIR)/workspace/ \
	    && docker cp $$cid:/home/ubuntu/. $(STATE_DIR)/home/ \
	    && docker rm $$cid >/dev/null \
	    && cp plan/PLAN.md $(STATE_DIR)/workspace/doc/PLAN.md; \
	fi

reseed:
	rm -rf $(STATE_DIR)
	$(MAKE) seed

run:
	./run.sh $(PROFILE) $(GPU)
