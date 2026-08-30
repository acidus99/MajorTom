.DEFAULT_GOAL := dev

# Override when preparing a named release, for example:
#   make release VERSION=v0.1.0
VERSION ?= v$(shell git log -1 --format=%cd --date=format:%Y.%m.%d)
BRANCH := $(shell git branch --show-current)
RELEASE_ARCHIVE := Build/Release/MajorTom-$(VERSION)-macos.zip
RELEASE_CHECKSUM := $(RELEASE_ARCHIVE).sha256

.PHONY: dev test prod check-release release

dev:
	@$(MAKE) test
	Scripts/build-app.sh

test:
	swift test

prod:
	@$(MAKE) test
	Scripts/notarize-app.sh "$(VERSION)"

check-release:
	@test -n "$(BRANCH)" || { echo "Release from a named branch, not a detached HEAD." >&2; exit 1; }
	@git diff --quiet || { echo "Commit or stash tracked changes before releasing." >&2; exit 1; }
	@git diff --cached --quiet || { echo "Commit or unstage staged changes before releasing." >&2; exit 1; }
	@test -z "$$(git ls-files --others --exclude-standard)" || { echo "Commit, ignore, or remove untracked files before releasing." >&2; exit 1; }
	@if git rev-parse --verify --quiet "refs/tags/$(VERSION)" >/dev/null; then \
		echo "Tag $(VERSION) already exists locally." >&2; exit 1; \
	fi
	@if git ls-remote --exit-code --tags origin "refs/tags/$(VERSION)" >/dev/null 2>&1; then \
		echo "Tag $(VERSION) already exists on origin." >&2; exit 1; \
	fi
	@gh auth status

release:
	@$(MAKE) check-release VERSION="$(VERSION)"
	@$(MAKE) prod VERSION="$(VERSION)"
	git tag -a "$(VERSION)" -m "Major Tom $(VERSION)"
	git push origin HEAD:refs/heads/$(BRANCH)
	git push origin "$(VERSION)"
	gh release create "$(VERSION)" \
		"$(RELEASE_ARCHIVE)" \
		"$(RELEASE_CHECKSUM)" \
		--title "Major Tom $(VERSION)" \
		--generate-notes \
		--draft \
		--verify-tag
