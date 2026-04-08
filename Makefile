image:
	cp ~/exp/diffusemt/plan/PLAN.md .
	docker build -t claude-container .
	rm PLAN.md
