.DEFAULT_GOAL := dev

# Override when preparing a named release, for example:
#   make release VERSION=v0.1.0
VERSION ?= v$(shell git log -1 --format=%cd --date=format:%Y.%m.%d)

.PHONY: dev prod release

dev:
	Scripts/build-app.sh

prod:
	Scripts/notarize-app.sh "$(VERSION)"

release: prod
	gh auth status
	gh release create "$(VERSION)" \
		"Build/Release/MajorTom-$(VERSION)-macos.zip" \
		"Build/Release/MajorTom-$(VERSION)-macos.zip.sha256" \
		--target "$$(git rev-parse HEAD)" \
		--title "Major Tom $(VERSION)" \
		--generate-notes \
		--draft
