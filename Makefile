# Main config
OPEN_API_URL = https://raw.githubusercontent.com/openfga/api/main/docs/openapiv2/apidocs.swagger.json
OPENAPI_GENERATOR_CLI_DOCKER_TAG = v6.0.0
NODE_DOCKER_TAG = 16-alpine
GO_DOCKER_TAG = 1
DOTNET_DOCKER_TAG = 6.0
GOLINT_DOCKER_TAG = v1.46
BUSYBOX_DOCKER_TAG = 1.34
# Other config
CONFIG_DIR = ${PWD}/config
CLIENTS_OUTPUT_DIR = ${PWD}/clients
DOCS_CACHE_DIR = ${PWD}/docs/openapi
TMP_DIR = $(shell mktemp -d "$${TMPDIR:-/tmp}/tmp.XXXXX")
dotnet_package_version = $(shell cat ./clients/fga-dotnet-sdk/VERSION.txt)

dotnet_publish_api_key=

all: test-all-clients

## Publishing
publish-client-dotnet: build-client-dotnet
	## See: https://docs.microsoft.com/en-us/nuget/quickstart/create-and-publish-a-package-using-the-dotnet-cli
	make run-in-docker sdk_language=dotnet image=mcr.microsoft.com/dotnet/sdk:${DOTNET_DOCKER_TAG} command="/bin/sh -c 'dotnet nuget push src/OpenFga.Sdk/bin/Release/OpenFga.Sdk.${dotnet_package_version}.nupkg --api-key ${dotnet_publish_api_key} --source https://api.nuget.org/v3/index.json'"

## Building and Testing
.PHONY: test
test: test-all-clients

.PHONY: build
build: build-all-clients

.PHONY: test-all-clients
test-all-clients: test-client-js test-client-go test-client-dotnet

.PHONY: build-all-clients
build-all-clients: build-client-js build-client-go build-client-dotnet

### JavaScript
.PHONY: tag-client-js
tag-client-js: test-client-js
	make utils-tag-client sdk_language=js

.PHONY: test-client-js
test-client-js: build-client-js
	make run-in-docker sdk_language=js image=node:${NODE_DOCKER_TAG} command="/bin/sh -c 'npm test ; npm audit ; npm run lint'"

.PHONY: build-client-js
build-client-js:
	make build-client sdk_language=js tmpdir=${TMP_DIR}
	sed -i -e "s|_this|this|g" ${CLIENTS_OUTPUT_DIR}/fga-js-sdk/*.ts
	sed -i -e "s|_this|this|g" ${CLIENTS_OUTPUT_DIR}/fga-js-sdk/*.md
	rm -rf  ${CLIENTS_OUTPUT_DIR}/fga-js-sdk/*-e
	make run-in-docker sdk_language=js image=node:${NODE_DOCKER_TAG} command="/bin/sh -c 'npm i; npm run lint:fix -- --quiet'"
	make run-in-docker sdk_language=js image=busybox:${BUSYBOX_DOCKER_TAG} command="/bin/sh -c 'patch -p1 /module/api.ts /config/clients/js/patches/add-missing-first-param.patch'"
	make run-in-docker sdk_language=js image=node:${NODE_DOCKER_TAG} command="/bin/sh -c 'npm run lint:fix; npm run build;'"

### Go
.PHONY: tag-client-go
tag-client-go: test-client-go
	make utils-tag-client sdk_language=go

.PHONY: test-client-go
test-client-go: build-client-go
	make run-in-docker sdk_language=go image=golang:${GO_DOCKER_TAG} command="/bin/sh -c 'go test'"
	make run-in-docker sdk_language=go image=golangci/golangci-lint:${GOLINT_DOCKER_TAG} command="golangci-lint run -v --skip-files=oauth2/"

.PHONY: build-client-go
build-client-go:
	make build-client sdk_language=go tmpdir=${TMP_DIR}
	make run-in-docker sdk_language=go image=busybox:${BUSYBOX_DOCKER_TAG} command="/bin/sh -c 'patch -p1 /module/api_open_fga.go /config/clients/go/patches/add-missing-first-param.patch'"
	make run-in-docker sdk_language=go image=golang:${GO_DOCKER_TAG} command="/bin/sh -c 'go mod tidy ; go fmt'"

### .NET
.PHONY: tag-client-dotnet
tag-client-dotnet: test-client-dotnet
	make utils-tag-client sdk_language=dotnet

.PHONY: test-client-dotnet
test-client-dotnet: build-client-dotnet
	make run-in-docker sdk_language=dotnet image=mcr.microsoft.com/dotnet/sdk:${DOTNET_DOCKER_TAG} command="/bin/sh -c 'dotnet test'"

.PHONY: build-client-dotnet
build-client-dotnet:
	rm -rf ${CLIENTS_OUTPUT_DIR}/fga-dotnet-sdk/src/OpenFga.Sdk.Test
	make build-client sdk_language=dotnet tmpdir=${TMP_DIR}
	make run-in-docker sdk_language=dotnet image=busybox:${BUSYBOX_DOCKER_TAG} command="/bin/sh -c 'patch -p1 /module/src/OpenFga.Sdk/Api/OpenFgaApi.cs /config/clients/dotnet/patches/add-missing-first-param.patch'"

	make run-in-docker sdk_language=dotnet image=mcr.microsoft.com/dotnet/sdk:${DOTNET_DOCKER_TAG} command="/bin/sh -c 'dotnet build --configuration Release'"
	# For some reason the first round of formatting fails with an error - running it again produces the correct result
	make run-in-docker sdk_language=dotnet image=mcr.microsoft.com/dotnet/sdk:${DOTNET_DOCKER_TAG} command="/bin/sh -c 'dotnet format ./OpenFga.Sdk.sln'" || true
	make run-in-docker sdk_language=dotnet image=mcr.microsoft.com/dotnet/sdk:${DOTNET_DOCKER_TAG} command="/bin/sh -c 'dotnet format ./OpenFga.Sdk.sln'"

.PHONY: run-in-docker
run-in-docker:
	docker run --rm \
		-v "${CLIENTS_OUTPUT_DIR}/fga-${sdk_language}-sdk":/module \
		-v ${CONFIG_DIR}:/config \
		-w /module \
		${image} \
		${command}

.PHONY: build-client
build-client: build-openapi
	# Build a config from common + overrides
	jq -rs 'reduce .[] as $$item ({}; . * $$item)' "${CONFIG_DIR}/common/config.base.json" "${CONFIG_DIR}/clients/${sdk_language}/config.overrides.json" > "${tmpdir}/config.json"

	mkdir -p "${CLIENTS_OUTPUT_DIR}/fga-${sdk_language}-sdk"

	# Initialize the temporary template directory
	mkdir "${tmpdir}/template"

	# Copy the shared files into temp template
	cp -r "${CONFIG_DIR}/common/files/." "${tmpdir}/template/"

	# Copy the template files into temp template
	cp -r "${CONFIG_DIR}/clients/${sdk_language}/template/." "${tmpdir}/template/"

	# Copy the CHANGELOG.md file into temp template
	cp "${CONFIG_DIR}/clients/${sdk_language}/CHANGELOG.md.mustache" "${tmpdir}/template/"

	# Clear existing directory
	cd "${CLIENTS_OUTPUT_DIR}/fga-${sdk_language}-sdk" && ls -A | grep -Ev '.git|node_modules|.idea' | xargs rm -r && cd -

	# Copy the generator ignore file into target directory (we need to do this before build otherwise openapi-generator ignores it)
	cp "${CONFIG_DIR}/clients/${sdk_language}/.openapi-generator-ignore" "${CLIENTS_OUTPUT_DIR}/fga-${sdk_language}-sdk/"

	# Generate the SDK
	docker run --rm \
		-v ${PWD}/docs:/docs \
		-v ${CLIENTS_OUTPUT_DIR}:/clients \
		-v ${tmpdir}:/config \
		--name openapi-generator \
		openapitools/openapi-generator-cli:${OPENAPI_GENERATOR_CLI_DOCKER_TAG} generate \
		-i /docs/openapi/openfga.openapiv2.json \
		--http-user-agent='openfga-sdk (${sdk_language}) {packageVersion}' \
		-o /clients/fga-${sdk_language}-sdk \
		-c /config/config.json \
		-g `cat ./config/clients/${sdk_language}/generator.txt`

.PHONY: build-openapi
build-openapi: init get-openapi-doc
	cat "${DOCS_CACHE_DIR}/openfga.openapiv2.raw.json" | \
		docker run --rm -i stedolan/jq \
		 '(.. | .tags? | select(.)) |= ["OpenFga"] | (.tags? | select(.)) |= [{"name":"OpenFga"}] | del(.definitions.ReadTuplesParams, .definitions.ReadTuplesResponse, .paths."/stores/{store_id}/read-tuples")' > \
		${DOCS_CACHE_DIR}/openfga.openapiv2.json
	sed -i -e 's/v1.//g' ${DOCS_CACHE_DIR}/openfga.openapiv2.json

.PHONY: get-openapi-doc
get-openapi-doc:
	mkdir -p "${DOCS_CACHE_DIR}"
	curl "${OPEN_API_URL}" \
	     -o "${DOCS_CACHE_DIR}/openfga.openapiv2.raw.json"

.PHONY: utils-tag-client
utils-tag-client:
	cd clients/fga-${sdk_language}-sdk && \
		git tag -a -s v`cat VERSION.txt`
	# now run: cd clients/fga-${sdk_language}-sdk && git push origin tag vA.B.C

.PHONY: init
init: ensure-dirs

.PHONY: ensure-dirs
ensure-dirs:
	mkdir -p "${DOCS_CACHE_DIR}/" "${CLIENTS_OUTPUT_DIR}/"

.PHONY: shellcheck
shellcheck:
	docker run --rm -v "${PWD}:/mnt" koalaman/shellcheck:stable scripts/*

.PHONY: setup-new-sdk
setup-new-sdk:
	./scripts/setup_new_sdk.sh