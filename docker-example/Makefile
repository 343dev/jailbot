.DEFAULT_GOAL := help

IMAGE ?= jailbot
TAG ?= latest
NO_CACHE ?= 0

.PHONY: help build clean update

help:
	@printf '%s\n' \
		'Commands:' \
		'  make help    - Show this help message' \
		'  make build   - Build the image using the cache' \
		'  make clean   - Remove the image; keep containers and volumes' \
		'  make update  - Remove the image, then build it' \
		'' \
		'Parameters: IMAGE (default: jailbot), TAG (default: latest), NO_CACHE (default: 0)' \
		'Example: make build IMAGE=my-image TAG=dev' \
		'Without cache: make build NO_CACHE=1'

# Disable the build cache only when NO_CACHE=1.
build:
	docker build $(if $(filter 1,$(NO_CACHE)),--no-cache) --tag "$(IMAGE):$(TAG)" .

# Remove only the selected image. Keep containers and volumes.
clean:
	docker image rm "$(IMAGE):$(TAG)"

# Remove the image before rebuilding, including with parallel make.
update:
	$(MAKE) clean
	$(MAKE) build
