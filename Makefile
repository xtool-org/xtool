ifeq ($(shell uname -s),Darwin)

IS_MAC = 1

ifneq ($(VERBOSE),1)
ifeq ($(shell type -p xcbeautify &>/dev/null && echo 1),1)
XC_FORMAT = | xcbeautify
endif
endif

endif

ifeq ($(RELEASE),1)
INTERNAL_SWIFTFLAGS = -c release
INTERNAL_XCFLAGS = -configuration Release
else
INTERNAL_SWIFTFLAGS = -c debug
INTERNAL_XCFLAGS = -configuration Debug
endif

ALL_SWIFTFLAGS = $(INTERNAL_SWIFTFLAGS) $(SWIFTFLAGS)
ALL_XCFLAGS = $(INTERNAL_XCFLAGS) $(XCFLAGS)

TEAM_CONFIG = macOS/Support/Private-Team.xcconfig

.PHONY: all
# dev build for the current platform
all:
ifeq ($(IS_MAC),1)
	@+$(MAKE) mac
else
	@+$(MAKE) linux
endif

.PHONY: clean
# clean build artifacts
clean:
ifeq ($(IS_MAC),1)
	@+$(MAKE) mac-clean
else
	@+$(MAKE) linux-clean
endif

.PHONY: linux
# dev build for Linux
linux:
	swift build --product xtool $(ALL_SWIFTFLAGS)

.PHONY: linux-clean
# clean build artifacts for Linux
linux-clean:
	rm -rf .build

.PHONY: linux-dist
# dist build for Linux
linux-dist:
	docker compose run --build --rm xtool Linux/build.sh

.PHONY: mac
# dev build for macOS
mac: project
	@rm -rf macOS/Build/XcodeInstall
	@set -o pipefail && cd macOS && \
	  xcodebuild install \
	  -skipMacroValidation -skipPackagePluginValidation \
	  -scheme XToolMac -destination generic/platform=macOS \
	  -derivedDataPath Build/DerivedData \
	  DSTROOT="$$PWD"/Build/XcodeInstall INSTALL_PATH=/ \
	  $(ALL_XCFLAGS) $(XC_FORMAT)
	@ln -fs XcodeInstall/xtool.app/Contents/Resources/bin/xtool macOS/Build/xtool
	@echo "Output: ./macOS/Build/xtool"

.PHONY: mac-clean
# clean build artifacts for macOS
mac-clean:
	rm -rf macOS/Build

.PHONY: mac-dist
# dist build for macOS
# requires a few secrets in the env (see .github/workflows/release.yml)
mac-dist:
	@echo "bundle exec fastlane package"
	@cd macOS && bundle exec fastlane package

.PHONY: reload
# update Xcode project and restart Xcode
reload:
	killall Xcode || :
	@+$(MAKE) project
	xed macOS/XToolMac.xcodeproj

.PHONY: project
# update Xcode project
project: $(TEAM_CONFIG)
	@echo "xcodegen"
	@cd macOS && xcodegen

.PHONY: team
# update development team
team:
	@+$(MAKE) -B $(TEAM_CONFIG)

# update development team if needed.
#
# will prompt interactively if there are multiple valid options.
# set DEVELOPMENT_TEAM=... to force a specific value.
$(TEAM_CONFIG):
ifeq ($(DEVELOPMENT_TEAM),)
	@mkdir -p macOS/Support
	@team=$$(./scripts/select-identity.sh); \
	  echo "echo \"DEVELOPMENT_TEAM = $$team\" > $@"; \
	  echo "DEVELOPMENT_TEAM = $$team" > $@
else
	@mkdir -p macOS/Support
	echo "DEVELOPMENT_TEAM = $(DEVELOPMENT_TEAM)" > $@
.PHONY: $(TEAM_CONFIG)
endif

.PHONY: docs
# build documentation
docs:
	./Documentation/build.sh

.PHONY: docs-preview
# preview documentation
docs-preview:
	./Documentation/build.sh preview

SWIFTLINT_VERSION = $(shell head -1 .swiftlint.yml | cut -d' ' -f2)
SWIFTLINT_BIN = .tmp/swiftlint/swiftlint-$(SWIFTLINT_VERSION)
SWIFTLINT_URL = https://github.com/realm/SwiftLint/releases/download/$(SWIFTLINT_VERSION)/$(if $(IS_MAC),portable_swiftlint,swiftlint_linux).zip

.PHONY: lint
lint: $(SWIFTLINT_BIN)
	$(SWIFTLINT_BIN) $(SWIFTLINT_FLAGS)

$(SWIFTLINT_BIN):
	@rm -rf .tmp/swiftlint
	@mkdir -p .tmp/swiftlint
	curl -fSL $(SWIFTLINT_URL) -o .tmp/swiftlint/swiftlint.zip
	unzip -q .tmp/swiftlint/swiftlint.zip swiftlint -d .tmp/swiftlint
	@rm -f .tmp/swiftlint/swiftlint.zip
	@mv .tmp/swiftlint/swiftlint $@
	@ln -s swiftlint-$(SWIFTLINT_VERSION) .tmp/swiftlint/swiftlint

SPEC_STRING := $(shell cat Sources/DeveloperAPI/spec-version.txt)
SPEC_COMMIT = $(word 1,$(SPEC_STRING))
SPEC_VERSION = $(word 2,$(SPEC_STRING))
SPEC_URL_BASE = https://raw.githubusercontent.com/EvanBacon/App-Store-Connect-OpenAPI-Spec
SPEC_URL = $(SPEC_URL_BASE)/$(SPEC_COMMIT)/specs/$(SPEC_VERSION).json
SPEC_BASE = openapi/base-$(SPEC_VERSION).json

.PHONY: api
# Regenerate the OpenAPI client code
api: openapi/openapi.json
	swift run swift-openapi-generator generate \
		openapi/openapi.json \
		--config Sources/DeveloperAPI/openapi-generator-config.yaml \
		--output-directory Sources/DeveloperAPI/Generated
	for file in Sources/DeveloperAPI/Generated/*.swift; do \
		sed -i '' -e 's/[[:<:]]Client[[:>:]]/DeveloperAPIClient/g' $$file; \
	done

.PHONY: update-api
# Update OpenAPI spec and regenerate the client code
update-api:
	@+$(MAKE) update-api-version
	@+$(MAKE) api

.PHONY: update-api-version
# Just update the OpenAPI spec version
update-api-version:
	latest_commit=$$(curl -fsSL \
		'https://api.github.com/repos/EvanBacon/App-Store-Connect-OpenAPI-Spec/commits?per_page=1' \
		| jq -r '.[0].sha'); \
	echo "$$latest_commit" > Sources/DeveloperAPI/spec-version.txt; \
	curl -fsSL "$(SPEC_URL_BASE)/$$latest_commit/specs/latest.json" \
		| jq -r '.info.version' >> Sources/DeveloperAPI/spec-version.txt

openapi/openapi.json: $(SPEC_BASE) Sources/DeveloperAPI/patch.js
	node Sources/DeveloperAPI/patch.js < $(SPEC_BASE) > openapi/openapi.json

$(SPEC_BASE):
	@mkdir -p openapi
	@rm -f openapi/base*.json
	curl -fsSL "$(SPEC_URL)" -o "$@"
