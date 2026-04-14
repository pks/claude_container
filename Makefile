image:
	cp ~/exp/diffusemt/plan/PLAN.md .
	docker build \
		--build-arg USERNAME=$$(whoami) \
		--build-arg USER_UID=$$(id -u) \
		--build-arg USER_GID=$$(id -g) \
		-t claude-container .
	rm PLAN.md
