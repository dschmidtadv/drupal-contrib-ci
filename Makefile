MODULE ?= all
JOBS   ?=

# Jobs for `make ci`. phpunit is left out because its selenium service image has
# no arm64 build; run it with `make phpunit`.
CI_JOBS ?= composer phpcs phpstan cspell eslint stylelint

.PHONY: build ci fast phpunit list origins

build:
	docker compose build

# make ci                          every module, all jobs except phpunit
# make ci MODULE=cloudflare        one module
# make ci JOBS="phpcs phpstan"     chosen jobs
ci:
	docker compose run --rm ci $(MODULE) $(or $(JOBS),$(CI_JOBS))

# Quick static checks only, no PHPUnit.
fast:
	docker compose run --rm ci $(MODULE) phpcs phpstan cspell

# phpunit only, with job images pulled as linux/amd64 (runs under emulation, so it
# is slower, and its composer dependency reruns on amd64 too).
# make phpunit MODULE=cloudflare
phpunit:
	JOB_PLATFORM=linux/amd64 docker compose run --rm ci $(MODULE) phpunit

# make list MODULE=cloudflare
list:
	docker compose run --rm ci list $(MODULE)

origins:
	docker compose run --rm ci origins
