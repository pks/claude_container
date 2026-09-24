GPU_ARCH := $(shell nvidia-smi --query-gpu=compute_cap --format=csv,noheader | head -1 | awk -F. '{v=$$1*10+$$2; if(v>=100) print "blackwell"; else if(v>=80) print "ampere"; else print "turing"}')
CUDA_VERSION := cu130

IMAGE     ?= mtbench-container
STATE_DIR ?= $(CURDIR)/state
# Task definitions live in the study repo, not here (this repo is task-agnostic).
# Defaults assume it is checked out as the parent of this directory.
BENCH_DIR  ?= $(CURDIR)/../bench
COLLAB_DIR ?= $(CURDIR)/../collab
# PROFILE / GPU / THINKING default to empty so run.sh can fall through to
# $(STATE_DIR)/.config — set them on first `make run` for a fresh state-dir
# and they'll be remembered. Bare `make run` on a fresh dir picks "pi-azure"
# / "all" via run.sh's own fallback chain.
PROFILE   ?=
GPU       ?=
USERNAME  ?= ubuntu
THINKING  ?=

.PHONY: image seed reseed run smoke bench bench-stage wiki

# Human view of the collab notes wiki: clone/refresh the bare repo and render a
# self-contained static site. COLLAB_BARE / WIKI_OUT override the defaults.
COLLAB_BARE ?= $(HOME)/exp/diffusemt_meta/collab_v0.git
WIKI_OUT    ?= $(CURDIR)/wiki-site
wiki:
	@if [ -d $(CURDIR)/.wiki-clone ]; then \
	   git -C $(CURDIR)/.wiki-clone remote set-url origin "$(COLLAB_BARE)"; \
	 else \
	   git clone -q "$(COLLAB_BARE)" $(CURDIR)/.wiki-clone; \
	 fi
	@git -C $(CURDIR)/.wiki-clone pull -q --rebase --autostash origin main
	@COLLAB_DIR=$(CURDIR)/.wiki-clone ./ops/collab/collab-wiki html $(WIKI_OUT) --no-pull
	@echo "open: file://$(WIKI_OUT)/index.html"

# Stage the bench task card into plan/ so `make seed` ships it to doc/PLAN.md
# (plan/ is gitignored — this is the per-deployment input the agent sees).
# The benchmark definition is not in this repo: it lives in the study repo's
# bench/. Override BENCH_DIR if it isn't checked out beside this one.
bench-stage:
	@if [ ! -f "$(BENCH_DIR)/TASKCARD.md" ]; then \
	  echo "make bench-stage: $(BENCH_DIR)/TASKCARD.md not found." >&2; \
	  echo "  The bench definition lives in the study repo (diffusemt_meta/bench)." >&2; \
	  echo "  Point at it with: make bench-stage BENCH_DIR=/path/to/diffusemt_meta/bench" >&2; \
	  exit 1; \
	fi
	@mkdir -p plan
	@cp $(BENCH_DIR)/TASKCARD.md plan/PLAN.md
	@echo "staged: $(BENCH_DIR)/TASKCARD.md -> plan/PLAN.md"
	@echo "next: make seed && make bench PROFILE=pi-azure GPU=all"

# Launch a bench run: egress lock + compute-time budget + the agent. Preemption-
# aware (resumes via ops/host-resume if installed). See the study repo's bench/README.md.
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
	    && cp plan/PLAN.md $(STATE_DIR)/workspace/doc/PLAN.md \
	    && if [ -f plan/HOST.md ]; then cp plan/HOST.md $(STATE_DIR)/workspace/doc/HOST.md; fi; \
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
