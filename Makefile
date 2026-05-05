GPU_ARCH := $(shell nvidia-smi --query-gpu=compute_cap --format=csv,noheader | head -1 | awk -F. '{v=$$1*10+$$2; if(v>=100) print "blackwell"; else if(v>=80) print "ampere"; else print "turing"}')
CUDA_VERSION := $(if $(filter blackwell,$(GPU_ARCH)),cu130,cu126)

# Content hash of all files baked into the image. run.sh stores this in
# state/.image-version on first seed and warns on subsequent runs if the
# current image's version differs (i.e. the state is stale w.r.t. the image).
IMAGE_VERSION := $(shell find Dockerfile ops models.json pi-extensions plan/PLAN.md -type f -print0 | sort -z | xargs -0 sha256sum | sha256sum | cut -c1-12)

image:
	@echo "Detected GPU_ARCH=$(GPU_ARCH) CUDA_VERSION=$(CUDA_VERSION) IMAGE_VERSION=$(IMAGE_VERSION)"
	docker build \
		--build-arg USERNAME=ubuntu \
		--build-arg USER_UID=$$(id -u) \
		--build-arg USER_GID=$$(id -g) \
		--build-arg GPU_ARCH=$(GPU_ARCH) \
		--build-arg CUDA_VERSION=$(CUDA_VERSION) \
		--build-arg IMAGE_VERSION=$(IMAGE_VERSION) \
		-t claude-container:$(IMAGE_VERSION) \
		-t claude-container \
		.

version:
	@echo $(IMAGE_VERSION)
