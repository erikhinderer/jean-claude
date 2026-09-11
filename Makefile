SHELL := /bin/bash
.DEFAULT_GOAL := help

help: ## Show targets
	@grep -E '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-12s\033[0m %s\n",$$1,$$2}'

setup: ## Create .env (secrets, GPU groups, auto-select backend)
	@./scripts/setup.sh

backend: ## Switch backend: make backend B=vulkan|rocm|cpu|native
	@test -n "$(B)" || (echo "usage: make backend B=vulkan|rocm|cpu|native" && exit 1)
	@./scripts/setup.sh --backend $(B)
	@echo "Now run: make up"

tune: ## Linux host tuning for the 890M (sudo; then reboot)
	@sudo ./scripts/host-tune-linux.sh

up: ## Start Jean Claude (downloads the model on first run)
	@test -f .env || ./scripts/setup.sh
	docker compose up -d --remove-orphans
	@echo "Open WebUI: http://localhost:$$(grep -E '^WEBUI_PORT=' .env | cut -d= -f2)  (model setup: make logs-init)"

down: ## Stop everything (keeps models and chats)
	docker compose down

restart: ## Restart the stack
	docker compose down && docker compose up -d

model: ## Rebuild the jean-claude model (after editing ollama/Modelfile.tmpl or .env)
	docker compose run --rm model-init

update: ## Pull newer images, re-pull base GGUF, rebuild model
	docker compose pull
	JC_UPDATE_BASE=1 docker compose run --rm model-init
	docker compose up -d

logs: ## Tail all logs
	docker compose logs -f --tail=100

logs-init: ## Follow the model download / build
	docker compose logs -f model-init

ps: ## Container status + what's loaded where
	@docker compose ps
	@docker compose exec -T ollama ollama ps 2>/dev/null || true

chat: ## Quick terminal chat with the model
	docker compose exec ollama ollama run $$(grep -E '^JC_MODEL_NAME=' .env | cut -d= -f2)

doctor: ## Diagnose GPU placement, memory limits, endpoints
	@./scripts/doctor.sh

bench: ## Benchmark current backend
	@./scripts/bench.sh

bench-all: ## Benchmark vulkan, rocm and cpu back to back
	@./scripts/bench.sh --all

image: ## Build the erikhinderer/jean-claude image locally
	@./scripts/publish-image.sh --local

publish: ## Build + push erikhinderer/jean-claude to Docker Hub (docker login first)
	@./scripts/publish-image.sh

clean: ## Remove containers AND volumes (deletes model + chats)
	@read -p "Delete model (~22 GB) and all chats? [y/N] " a && [ "$$a" = y ] && docker compose down -v || echo aborted

.PHONY: help setup backend tune up down restart model update logs logs-init ps chat doctor bench bench-all image publish clean
