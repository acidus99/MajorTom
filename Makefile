.DEFAULT_GOAL := dev

# Make treats words after "release" as additional goals. Accept exactly one
# version increment and reject other goals before executing any recipe.
ifneq ($(filter release,$(MAKECMDGOALS)),)
override RELEASE_BUMP := $(filter major minor patch,$(MAKECMDGOALS))
ifneq ($(words $(MAKECMDGOALS)),2)
$(error Usage: make release major|minor|patch)
endif
ifneq ($(words $(RELEASE_BUMP)),1)
$(error Usage: make release major|minor|patch)
endif
ifneq ($(strip $(VERSION)$(BUMP)),)
$(error Use make release major|minor|patch without VERSION or BUMP)
endif
endif
APP_VIDEOS := $(wildcard Assets/App/*.mov)
APP_VIDEO_RESOURCES := $(patsubst Assets/App/%.mov,Resources/%.mp4,$(APP_VIDEOS))

.PHONY: dev test videos release

dev:
	@python3 -B Scripts/develop.py dev

test:
	@python3 -B Scripts/develop.py test

videos: $(APP_VIDEO_RESOURCES)

Resources/%.mp4: Assets/App/%.mov
	@mkdir -p Resources
	ffmpeg -y -i "$<" \
		-an \
		-vf "fps=20" \
		-c:v libx265 \
		-preset slow \
		-crf 33 \
		-pix_fmt yuv420p \
		-tag:v hvc1 \
		-x265-params "keyint=40:min-keyint=20" \
		-movflags +faststart \
		"$@"

release:
	@python3 -B Scripts/release.py $(RELEASE_BUMP)

ifneq ($(filter release,$(MAKECMDGOALS)),)
.PHONY: major minor patch
major minor patch:
	@:
endif
