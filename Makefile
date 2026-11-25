# Demo in one command:   make demo      (build -> deploy to k8s -> wait -> tests)
# Tear it down:          make down
# Everything else:       make help
#
# Override anything on the command line, e.g.  make demo NODEPORT=31000

NS       ?= default
REL      ?= ollaya
NODEPORT ?= 30808
HOST     ?= localhost
API_KEY  ?=
LOCAL_IMG ?= ollaya:demo

URL  = http://$(HOST):$(NODEPORT)
AUTH = $(if $(API_KEY),-H 'Authorization: Bearer $(API_KEY)')
STATE   = I was charged twice on my invoice and need a refund today, this is urgent!
NOUL    = {"model":"laya","state":"$(STATE)","questions":{"wants_refund":{"type":"noul","instructions":"Does the customer ask for their money back?"}}}
SCORE   = {"model":"laya","state":"$(STATE)","questions":{"urgency":{"type":"score","instructions":"How urgent is the ticket?","criteria":["can wait","this week","today","right now"]}}}
CHOICE  = {"model":"laya","state":"$(STATE)","questions":{"team":{"type":"choice","instructions":"Which team should handle the ticket?","criteria":{"billing":"invoices, charges, refunds","engineering":"bugs, outages, errors","sales":"pricing, demos, upgrades","other":"anything else"}}}}
POST = curl -s -m 60 $(AUTH) -H 'Content-Type: application/json' -d

.DEFAULT_GOAL := help
.PHONY: progress help demo build up up-ghcr wait test test-alive test-noul test-score test-choice test-decisions test-models down status logs docker-demo docker-up docker-test docker-down

help: ## show this list
	@grep -E '^[a-z-]+:.*## ' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  make %-16s %s\n", $$1, $$2}'

demo: build up wait test ## EVERYTHING: build image, deploy to k8s, wait, run all tests

build: ## build the image locally (needs docker; k8s must use the docker runtime, e.g. colima)
	docker build -t $(LOCAL_IMG) .

up: ## deploy the local chart + local image to k8s on a NodePort (default 30808)
	helm upgrade --install $(REL) charts/ollaya -n $(NS) \
	  --set image.repository=$(firstword $(subst :, ,$(LOCAL_IMG))) \
	  --set image.tag=$(lastword $(subst :, ,$(LOCAL_IMG))) \
	  --set image.pullPolicy=Never \
	  --set persistence.size=3Gi \
	  --set service.type=NodePort --set service.nodePort=$(NODEPORT) \
	  $(if $(API_KEY),--set apiKey.value=$(API_KEY))

up-ghcr: ## deploy the PUBLISHED chart + image from GitHub (after you tagged a release)
	helm repo add ollaya https://teochenglim.github.io/ollaya --force-update
	helm repo update
	helm upgrade --install $(REL) ollaya/ollaya -n $(NS) \
	  --set persistence.size=3Gi \
	  --set service.type=NodePort --set service.nodePort=$(NODEPORT) \
	  $(if $(API_KEY),--set apiKey.value=$(API_KEY))

wait: ## wait until the pod is ready (first run downloads the ~850 MB laya model)
	kubectl -n $(NS) rollout status deploy/$(REL) --timeout=600s

test: test-alive test-noul test-score test-choice test-decisions test-models ## run ALL the tests below

test-alive: ## is the server up?  GET /
	@curl -s -m 5 $(URL)/; echo

test-noul: ## yes/no question  -> POST /v1/systemone  (answer: probability 0..1)
	@echo "--- noul";   $(POST) '$(NOUL)' $(URL)/v1/systemone; echo

test-score: ## rating question -> POST /v1/systemone  (answer: expected level)
	@echo "--- score";  $(POST) '$(SCORE)' $(URL)/v1/systemone; echo

test-choice: ## pick-one question -> POST /v1/systemone  (answer: option + probabilities)
	@echo "--- choice"; $(POST) '$(CHOICE)' $(URL)/v1/systemone; echo

test-decisions: ## same noul question on the alias endpoint POST /v1/decisions
	@echo "--- /v1/decisions"; $(POST) '$(NOUL)' $(URL)/v1/decisions; echo

test-models: ## list models on the server  GET /v1/models
	@echo "--- /v1/models"; curl -s -m 10 $(AUTH) $(URL)/v1/models; echo

progress: ## is it stuck? pod state + how many MB the model download has reached (re-run it)
	@kubectl -n $(NS) get pods -l app.kubernetes.io/instance=$(REL)
	@kubectl -n $(NS) exec deploy/$(REL) -c pull-models -- du -sm /home/ollaya/.ollaya 2>/dev/null | awk '{print "model volume: " $$1 " MB (laya = en + multilingual, ~1.5-2 GB total)"}' \
	  || echo "init container finished (or not started): see 'make status'"
	@kubectl -n $(NS) logs deploy/$(REL) -c pull-models --tail=3 2>/dev/null || true

status: ## pods, service, volume
	kubectl -n $(NS) get pods,svc,pvc

logs: ## follow server logs
	kubectl -n $(NS) logs deploy/$(REL) -f

down: ## remove the release AND its model volume (never touches the namespace)
	-helm uninstall $(REL) -n $(NS)
	-kubectl -n $(NS) delete pvc -l app.kubernetes.io/instance=$(REL)

# ---- no Kubernetes? plain docker, same tests ----------------------------------------------
docker-demo: build docker-up docker-test ## docker only: build, run, pull laya, tests

docker-up: ## run the container on port 30808 and pull the laya model
	-docker rm -f ollaya-demo
	docker run -d --name ollaya-demo -p $(NODEPORT):11435 -v ollaya-demo:/home/ollaya/.ollaya $(LOCAL_IMG)
	@until curl -sf -m 2 $(URL)/ >/dev/null; do sleep 1; done
	docker exec ollaya-demo ollaya pull laya

docker-test: test ## same tests

docker-down: ## stop + delete the container and its volume
	-docker rm -f ollaya-demo
	-docker volume rm ollaya-demo
