GPU_ARCH := $(shell nvidia-smi --query-gpu=compute_cap --format=csv,noheader | head -1 | awk -F. '{v=$$1*10+$$2; if(v>=100) print "blackwell"; else if(v>=80) print "ampere"; else print "turing"}')
CUDA_VERSION := cu130

IMAGE     ?= mtbench-container
STATE_DIR ?= $(CURDIR)/state
# PROFILE / GPU / THINKING default to empty so run.sh can fall through to
# $(STATE_DIR)/.config — set them on first `make run` for a fresh state-dir
# and they'll be remembered. Bare `make run` on a fresh dir picks "pi-azure"
# / "all" via run.sh's own fallback chain.
PROFILE   ?=
GPU       ?=
USERNAME  ?= ubuntu
THINKING  ?=

.PHONY: image seed reseed run smoke bench bench-stage

# Stage the bench task card into plan/ so `make seed` ships it to doc/PLAN.md
# (plan/ is gitignored — this is the per-deployment input the agent sees).
bench-stage:
	@mkdir -p plan
	@cp bench/TASKCARD.md plan/PLAN.md
	@echo "staged: bench/TASKCARD.md -> plan/PLAN.md"
	@echo "next: make seed && make bench PROFILE=pi-azure GPU=all"

# Launch a bench run: egress lock + compute-time budget + the agent. Preemption-
# aware (resumes via ops/host-resume if installed). See bench/README.md.
bench:
	IMAGE=$(IMAGE) STATE_DIR=$(STATE_DIR) USERNAME=$(USERNAME) THINKING=$(THINKING) \
	  ./ops/bench-egress.sh "$(PROFILE)" "$(GPU)"

image:
	@echo "Detected GPU_ARCH=$(GPU_ARCH) CUDA_VERSION=$(CUDA_VERSION)"
	docker build \
		--build-arg USERNAME=$(USERNAME) \
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
	@ws=0; hm=0; \
	[ -n "$$(ls -A $(STATE_DIR)/workspace 2>/dev/null)" ] && ws=1; \
	[ -n "$$(ls -A $(STATE_DIR)/home 2>/dev/null)" ] && hm=1; \
	if [ "$$ws" = 1 ] && [ "$$hm" = 1 ]; then \
	  echo "$(STATE_DIR) is already seeded — run 'make reseed' to wipe and redo"; \
	elif [ "$$ws" = 1 ] || [ "$$hm" = 1 ]; then \
	  echo "make seed: $(STATE_DIR) is partially seeded (workspace=$$ws, home=$$hm) — likely from an interrupted seed." >&2; \
	  echo "  Run 'make reseed' to wipe and redo." >&2; \
	  exit 1; \
	elif [ ! -f plan/PLAN.md ]; then \
	  echo "make seed: plan/PLAN.md is missing (plan/ is gitignored, so a clean clone won't have it)." >&2; \
	  echo "  Create plan/PLAN.md describing what the agent should carry out, then re-run 'make seed'." >&2; \
	  exit 1; \
	else \
	  echo "seeding $(STATE_DIR) from $(IMAGE)"; \
	  cid=$$(docker create $(IMAGE)) \
	    && docker cp $$cid:/workspace/. $(STATE_DIR)/workspace/ \
	    && docker cp $$cid:/home/$(USERNAME)/. $(STATE_DIR)/home/ \
	    && docker rm $$cid >/dev/null \
	    && cp plan/PLAN.md $(STATE_DIR)/workspace/doc/PLAN.md; \
	fi

reseed:
	rm -rf $(STATE_DIR)
	$(MAKE) seed

run:
	USERNAME=$(USERNAME) THINKING=$(THINKING) ./run.sh "$(PROFILE)" "$(GPU)"

# Smoke: build image (no-op if cached), seed if needed, run the `bash` profile
# non-interactively to verify entrypoint + mounts + uv env are all wired up.
# Exits 0 on success; non-zero on any breakage in the chain.
smoke: image
	@if [ ! -d "$(STATE_DIR)/workspace" ] || [ ! -d "$(STATE_DIR)/home" ]; then \
	  $(MAKE) seed; \
	fi
	@echo "==> smoke: bash profile, image=$(IMAGE)"
	@docker run --rm \
		-v "$(STATE_DIR)/workspace:/workspace" \
		-v "$(STATE_DIR)/home:/home/$(USERNAME)" \
		--entrypoint /usr/local/bin/entrypoint.sh \
		$(IMAGE) \
		bash -c 'set -e; echo "[smoke] pwd=$$(pwd)"; uv --version; node --version; pi --version >/dev/null && echo "[smoke] pi OK"; echo "[smoke] all OK"'
