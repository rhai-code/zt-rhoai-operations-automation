SLUG        ?= rhoai-operations
NAMESPACE   ?= showroom-$(SLUG)
RELEASE     ?= showroom
VALUES      ?= values-$(SLUG).yaml
# Published chart ref; override CHART=~/git/zt-showroom-deployer for local source.
CHART_REPO_NAME ?= eformat
CHART_REPO  ?= https://eformat.github.io/helm-charts
CHART       ?= $(CHART_REPO_NAME)/showroom-deployer

.PHONY: repo template deploy status uninstall

repo:
	helm repo add $(CHART_REPO_NAME) $(CHART_REPO) || true
	helm repo update $(CHART_REPO_NAME)

template:
	helm template $(RELEASE) $(CHART) -n $(NAMESPACE) -f $(VALUES)

deploy:
	helm upgrade --install $(RELEASE) $(CHART) \
	  -n $(NAMESPACE) --create-namespace -f $(VALUES)

status:
	helm status $(RELEASE) -n $(NAMESPACE)

uninstall:
	helm uninstall $(RELEASE) -n $(NAMESPACE)
