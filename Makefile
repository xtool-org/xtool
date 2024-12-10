SPEC_URL = https://developer.apple.com/sample-code/app-store-connect/app-store-connect-openapi-specification.zip

.PHONY: api update-api

api: openapi.json
	swift run swift-openapi-generator generate \
		openapi.json \
		--config Sources/DeveloperAPI/openapi-generator-config.yaml \
		--output-directory Sources/DeveloperAPI/Generated
	for file in Sources/DeveloperAPI/Generated/*.swift; do \
		sed -i '' -e 's/[[:<:]]Client[[:>:]]/DeveloperAPIClient/g' $$file; \
	done

update-api:
	@+$(MAKE) -B api

openapi.json:
	curl -fsSL "$(SPEC_URL)" | bsdtar -xOf- > openapi.json
