GPU_ARCH := $(shell nvidia-smi --query-gpu=compute_cap --format=csv,noheader | head -1 | awk -F. '{v=$$1$$2; if(v>=100) print "blackwell"; else if(v>=80) print "ampere"; else print "turing"}')
CUDA_VERSION := $(if $(filter blackwell,$(GPU_ARCH)),cu130,cu126)

image:
	@echo "Detected GPU_ARCH=$(GPU_ARCH) CUDA_VERSION=$(CUDA_VERSION)"
	cp ~/exp/diffusemt/plan/PLAN.md .
	docker build \
		--build-arg USERNAME=$$(whoami) \
		--build-arg USER_UID=$$(id -u) \
		--build-arg USER_GID=$$(id -g) \
		--build-arg GPU_ARCH=$(GPU_ARCH) \
		--build-arg CUDA_VERSION=$(CUDA_VERSION) \
		-t claude-container .
	rm PLAN.md
