# Basics
PROJECT_NAME 		:= trygg
SHELL 			:= /bin/bash

# Directory structure
DOCKER_DIR 		?= etc/docker
DOCKER_COMPOSE_FILE	?= $(DOCKER_DIR)/docker-compose.yml
RELEASE_DOCKERFILE 	?= $(DOCKER_DIR)/Dockerfile

# Versioning
VERSION_LONG 		:= $(shell git describe --first-parent --abbrev=10 --long --tags --dirty)
VERSION_SHORT 		:= $(shell echo $(VERSION_LONG) | cut -f 1 -d "-")
DATE_STRING 		:= $(shell date +'%m-%d-%Y')
GIT_HASH  		:= $(shell git rev-parse --verify HEAD)

# Formatting variables
BOLD 			:= $(shell tput bold)
RESET 			:= $(shell tput sgr0)
RED 			:= $(shell tput setaf 1)
GREEN 			:= $(shell tput setaf 2)
TEAL 			:= $(shell tput setaf 6)

export PGPASSWORD 		?= postgres
export DBNAME 			?= trygg_dev

.DEFAULT_GOAL := help

##
# ~~~ Dev Targets ~~~
##

.PHONY: dev
dev: ## Start the local dev server. HOST=<lan-ip> to expose avatar/media image URLs for mobile device testing
	@BOLD="$(BOLD)" RESET="$(RESET)" RED="$(RED)" GREEN="$(GREEN)" TEAL="$(TEAL)" \
		DOCKER_COMPOSE_FILE="$(DOCKER_COMPOSE_FILE)" \
		PGPASSWORD="$(PGPASSWORD)" DBNAME="$(DBNAME)" \
		./etc/scripts/check_dev_prerequisites.sh
		mix phx.server

.PHONY: dev-setup
dev-setup:  ## Set up local dev environment
	@echo "$(BOLD)Setting up development environment...$(RESET)"
	@docker compose -f $(DOCKER_COMPOSE_FILE) up -d
	@./etc/scripts/_wait_db_connection.sh
	@if [ "$($(reset-db))" = "true" ]; then $(MAKE) reset-db; fi
	@$(MAKE) setup-dev-db
	@echo "$(GREEN)Your local dev env is ready!$(RESET)"
	@echo "Run $(BOLD)make dev$(RESET) to start the server and then visit $(BOLD)http://localhost:4000/$(RESET)"

# I always write this wrong. I'm too lazy to fix it so lets alias it to dev-setup.
.PHONY: setup-dev
setup-dev: dev-setup

.PHONY: dev-services
dev-services:  ## Start Docker services (postgres, minio, etc.)
	@echo "$(BOLD)Starting Docker services...$(RESET)"
	@docker compose -f $(DOCKER_COMPOSE_FILE) up -d
	@./etc/scripts/_wait_db_connection.sh
	@echo "$(GREEN)Docker services are running!$(RESET)"

.PHONY: setup
setup: dev-setup

.PHONY: shell
shell:  ## Open a shell in the dev container
	@iex -S mix

.PHONY: reset-db
reset-db:  ## Drop the local dev db
	@mix ecto.drop

.PHONY: setup-dev-db
setup-dev-db:  ## Create, migrate and seed the local dev database
	@mix ecto.create
	@mix ecto.migrate
	@mix run priv/repo/seeds.exs || true
	@mix run priv/repo/dev_seeds.exs || true

.PHONY: tests
tests:  ## Run the test suite (starts postgres if needed)
	@echo "$(BOLD)Ensuring PostgreSQL is running...$(RESET)"
	@docker compose -f $(DOCKER_COMPOSE_FILE) up -d postgres || true
	@DBNAME=postgres ./etc/scripts/_wait_db_connection.sh true
	@echo "$(BOLD)Running test suite...$(RESET)"
	@MIX_ENV=test mix test --cover

.PHONY: test
test: tests

.PHONY: tests-failed
tests-failed: test-failed

.PHONY: test-failed
test-failed:  ## Run the test suite for failed tests from previous run
	@MIX_ENV=test mix test --trace --failed

# Shell scripts to lint/format (respects all .gitignore files)
SHELL_SCRIPTS := $(shell ./etc/scripts/list_lintable_shell_scripts.sh)

.PHONY: format
format:  ## Format the code (Elixir, shell scripts, and JSON/YAML/TOML)
	@mix format
	@if command -v shfmt >/dev/null 2>&1 && [ -n "$(SHELL_SCRIPTS)" ]; then \
		shfmt -w -i 2 -ci $(SHELL_SCRIPTS); \
	fi
	@if command -v dprint >/dev/null 2>&1; then \
		dprint fmt; \
	fi

.PHONY: config-format-check
config-format-check:  ## Check JSON/YAML/TOML formatting with dprint
	@command -v dprint >/dev/null 2>&1 || { echo "Install dprint: brew install dprint"; exit 1; }
	@dprint check

.PHONY: shell-lint
shell-lint:  ## Lint shell scripts with ShellCheck
	@command -v shellcheck >/dev/null 2>&1 || { echo "Install ShellCheck: brew install shellcheck"; exit 1; }
	@if [ -n "$(SHELL_SCRIPTS)" ]; then shellcheck $(SHELL_SCRIPTS); fi

.PHONY: shell-format-check
shell-format-check:  ## Check shell script formatting with shfmt
	@command -v shfmt >/dev/null 2>&1 || { echo "Install shfmt: brew install shfmt"; exit 1; }
	@if [ -n "$(SHELL_SCRIPTS)" ]; then shfmt -d -i 2 -ci $(SHELL_SCRIPTS); fi

.PHONY: dialyzer
dialyzer:  ## Run Dialyzer type checker (builds PLT on first run, cached after)
	@mix dialyzer

.PHONY: lint
lint:  ## Run the lint suite
	@mix format --check-formatted
	@mix sobelow --exit --quiet --skip --ignore Config.HTTPS
	@$(MAKE) shell-lint shell-format-check config-format-check

.PHONY: preflight
preflight:  ## Run CI checks locally (compile, format, sobelow, audit, tests)
	@BOLD="$(BOLD)" RESET="$(RESET)" RED="$(RED)" GREEN="$(GREEN)" TEAL="$(TEAL)" \
		DOCKER_COMPOSE_FILE="$(DOCKER_COMPOSE_FILE)" \
		./etc/scripts/preflight.sh

.PHONY: clean-compose
clean-compose:  ## Remove docker containers and volumes
	@docker compose -f $(DOCKER_COMPOSE_FILE) down -v --remove-orphans

.PHONY: clean-docker
clean-docker: clean-compose  ## Delete docker images, volumes and networks
	@echo "$(BOLD)** Cleaning up Docker resources...$(RESET)"
	@docker compose -f $(DOCKER_COMPOSE_FILE) rm -f -s -v

.PHONY: clean-elixir
clean-elixir:  ## Clean up Elixir and Phoenix files
	@echo "$(BOLD)** Cleaning up Elixir files...$(RESET)"
	@mix clean
	@rm -rf _build/ deps/
	@rm -f priv/static/assets/*.gz priv/static/assets/*.br priv/static/assets/*.zst

.PHONY: clean
clean: clean-elixir clean-docker  ## Clean docker and elixir

##
# ~~~ Release Targets ~~~
##

.PHONY: version
version:  ## Print the current version
	@echo $(VERSION_LONG)

.PHONY: release-tag
release-tag:  ## Create a new release (update version in mix.exs, create git tag, commit and push). Use TAG=v1.0.0 to pass version
	@./etc/scripts/release.sh $(TAG)

.PHONY: release
release:  ## Build and tag a docker image for release
	@DOCKER_BUILDKIT=1 docker build -f $(RELEASE_DOCKERFILE) -t $(PROJECT_NAME):$(VERSION_LONG) .
	@docker tag $(PROJECT_NAME):$(VERSION_LONG) $(PROJECT_NAME):$(VERSION_SHORT)
	@docker tag $(PROJECT_NAME):$(VERSION_LONG) $(PROJECT_NAME):latest

##
# Fly.io (single app: trygg, config at fly.toml)
##

FLY_APP ?= $(PROJECT_NAME)
FLY_CONFIG ?= fly.toml

.PHONY: fly-verify-prod
fly-verify-prod:  ## Confirm Fly credentials can access the app (FLY_API_TOKEN or fly auth login)
	@"$(CURDIR)/etc/scripts/fly_verify_app_access.sh" $(FLY_APP)

.PHONY: deploy-prod
deploy-prod: fly-verify-prod  ## Deploy to Fly with a local Docker build
	@echo "$(BOLD)Deploying $(FLY_APP) to Fly.io...$(RESET)"
	@echo "$(BOLD)Version: $(VERSION_LONG)$(RESET)"
	@fly deploy \
	  --dockerfile $(RELEASE_DOCKERFILE) \
	  -a $(FLY_APP) \
	  -c $(FLY_CONFIG) \
	  --local-only \
	  --build-arg BUILD_VERSION=$(VERSION_LONG) \
	  --image-label $(VERSION_LONG)

.PHONY: shell-prod
shell-prod: fly-verify-prod  ## Open an IEx shell on Fly.io
	@echo "$(BOLD)Opening IEx console on Fly.io...$(RESET)"
	@fly ssh console -a $(FLY_APP) -C "/app/bin/$(PROJECT_NAME) remote"

##
# ~~~ Make Helpers ~~~
##

.PHONY: help
help:  ## Print this make target help message
	@awk 'BEGIN {FS = ":.*##"; printf "\nUsage: make $(TEAL)<target>$(RESET)\n\n"} /^[a-zA-Z_-]+:.*?##/ { printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2 } /^##@/ { printf "\n$(TEAL)%s$(RESET)\n", substr($$0, 5) } ' $(MAKEFILE_LIST)
	@printf "\n"

.PHONY: arg-%
arg-%: ARG  # Checks if param is present: make key=value
	@if [ "$($(*))" = "" ]; then \
		echo "$(RED)Missing param: $(BOLD)$(*)$(RESET)$(RED). Use '$(BOLD)make $(MAKECMDGOALS) $(*)=value$(RESET)$(RED)'$(RESET)" && exit 1; \
	fi

.PHONY: guard-%
guard-%: GUARD  ## Check if required environment variables are set
	@if [ -z "${${*}}" ]; then \
		echo "$(RED)Required environment variable $(BOLD)$*$(RESET)$(RED) not set.$(RESET)" && exit 1; \
	fi

.PHONY: GUARD ARG
GUARD:
ARG:
