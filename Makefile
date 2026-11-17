# Thin wrapper around docker compose. Every step runs in a throwaway pqc-hsm-lab container (--rm).
RUN := docker compose run --rm pqc-hsm-lab

.PHONY: help build all step1 step2 step3 step4 step5 bench shell clean

help:
	@echo "make build   build the pqc-hsm-lab image"
	@echo "make all     run steps 1-5 in order"
	@echo "make stepN   run a single step (1-5); steps 3 and 4 need step 2"
	@echo "make bench   speed comparison OpenSSL 4.1 vs 3.5, 5 runs (~10 min; RUNS=n to change)"
	@echo "make shell   interactive shell in the container"
	@echo "make clean   delete out/ and the image"

build:
	docker compose build

all: step1 step2 step3 step4 step5

step1:
	$(RUN) scripts/01-keys-bench.sh
step2:
	$(RUN) scripts/02-ca.sh
step3:
	$(RUN) scripts/03-tls.sh
step4:
	$(RUN) scripts/04-hsm.sh
step5:
	$(RUN) scripts/05-composite.sh

bench:
	scripts/bench.sh $(or $(RUNS),5)

shell:
	$(RUN) bash

clean:
	rm -rf out
	docker compose --profile baseline down --rmi local
