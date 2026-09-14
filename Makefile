# The golden workflow.
#
# THIS FILE IS THE INTERFACE between a developer at a laptop and the forge. The
# build runner does not know how to build anything; it boots a microVM, runs
# `make all` in the source tree, and collects what lands in the output
# directory. So the same targets a developer types are literally the targets CI
# runs — not an approximation of them, not a second pipeline definition that
# drifts, the same file.
#
# Copy it to the root of a repository and adjust the scripts under scripts/.
#
#   make build     compile
#   make test      run the tests
#   make dist      stage artifacts for collection
#   make image     build the container image, if this repository has one
#   make sbom      describe what was built
#   make scan      check that description against known vulnerabilities
#   make all       all of the above, in that order   <- what the forge runs
#
# THERE IS NO `publish` TARGET, AND THERE MUST NEVER BE ONE.
#
# That applies to `image` exactly as it does to `dist`, and it is the reason
# `image` stages an OCI ARCHIVE rather than pushing to a registry. podman can
# push; this file must never ask it to. The archive is collected from the
# staging directory and pushed by a task holding a Nexus credential no
# developer has, and no build code has either.
#
# That is the load-bearing omission in this file. Artifacts are STAGED here and
# uploaded by a task the developer has no access to, holding an OAuth2 client
# the developer does not have. If publishing were a make target, then either a
# developer could push a locally built binary to the shared repository — bypassing
# review, CI, signing and provenance entirely — or the credential to do so would
# have to be reachable from build code, which in the forge means reachable from
# untrusted pull-request code. Both are the same failure. `dist` stages; the
# runner publishes; the boundary is that this file cannot express the difference.
#
# HERMETIC BY DEFAULT, WITH ONE NAMED EXCEPTION. Inside the forge these targets
# run in a BUILD MACHINE — either a microVM with NO NETWORK DEVICE AT ALL, or a
# container told in every way available not to use the one it has. Anything a
# target needs — modules, wheels, base images — is staged beforehand by a
# networked prestart task and handed over. A target that reaches for the network
# works on a laptop and, in the VM, hangs until the timeout kills it — which is
# the single most confusing way for this to fail. Keep them offline.
#
# The exception is `scan`, and it is an exception on purpose. It is the one
# target whose answer is not a function of its inputs: the same artifact scanned
# a month apart should report differently, because the vulnerability database
# moved and the artifact did not. It runs in its own stage, with a network, and
# refreshes that database immediately before reading it. Nothing else in this
# file may follow it.
#
# NOT EVERY MACHINE CAN RUN EVERY TARGET, AND THAT IS NOW THE NORMAL CASE.
# `build` and `test` need a toolchain; `image` needs podman and deliberately has
# no compiler beside it; `scan` needs a scanner and a network and has neither a
# toolchain nor podman. In the forge each runs on the image that has what it
# needs, in the order below, handing the staged artifacts along — see
# runner/CONTAINER-CONTRACT.md. On a laptop one environment has everything and
# `make all` behaves exactly as it always did.
#
# `machine` therefore selects the TOOLCHAIN and nothing else. It used to have to
# name `image` for a repository with a Containerfile, because one machine ran
# the whole workflow and only one machine had the image builder. Every repository now gets
# the image step if it has a Containerfile, whatever it compiles.

SHELL := /bin/sh

# Where artifacts are staged.
#
# /sfdout is the 9p export the guest writes to and the runner reads afterwards;
# it exists only inside the build VM. On a laptop there is no /sfdout, so the
# same targets stage into ./dist instead and a developer gets exactly what CI
# would collect, in a directory they can look at.
SFD_OUT ?= $(if $(wildcard /sfdout),/sfdout,$(CURDIR)/dist)
ARTIFACTS := $(SFD_OUT)/artifacts

export SFD_OUT
export ARTIFACTS

.PHONY: all deps build test dist image sbom scan clean help

all: build test dist image sbom scan ## The golden workflow, in order

# DELIBERATELY NOT IN `all`, and the omission is the design.
#
# `deps` is the only target that reaches the network, and the only one that runs
# BEFORE the workflow rather than as part of it. In the forge it runs in a
# prestart task, on the same toolchain machine that later compiles — networked
# there, hermetic here — so the caches every other target consumes are populated
# by the same Go, the same bun and the same uv that will read them.
#
# That is not a tidiness argument. The caches used to be populated by a separate
# Debian image pinning its own versions, under a written rule that they "must
# track the build machines", and they drifted: go 1.25.3 against the machine's
# go1.26.4, and before that grype 0.87.0 against 0.115.0 — which passed `sbom`
# and failed `scan`, because grype ties its database schema to the client.
#
# On a laptop a developer already has their dependencies and `make all` behaves
# exactly as it always did. Run `make deps` by hand to see precisely what CI
# stages, in ./deps.
deps: ## Fetch dependencies so every later step can run offline (NETWORKED)
	@sh scripts/deps.sh

# THE PREREQUISITES HOLD ON ONE MACHINE AND CANNOT HOLD ON FOUR.
#
# `image' needing `dist' needing `build' is exactly right when a single machine
# carries every toolchain: it says an image is built from binaries this workflow
# produced and tested, never from a second compile inside the Containerfile.
#
# Since the build machines were split by toolchain that chain is unsatisfiable.
# The image machine has no Go compiler, deliberately, so `make image' there
# walks back to `build' and dies with `go: command not found' -- a message about
# a missing compiler on a machine that was never meant to have one.
#
# SFD_NO_REBUILD says: consume what is already staged, do not regenerate it. The
# stages share one allocation and one artifact directory, so by the time `image'
# runs, the binary `dist' would have produced is already sitting in $(ARTIFACTS)
# -- put there by a machine that HAD the compiler, and carried forward with its
# digest recorded in the manifest.
#
# It is DERIVED, never passed: the build agent sets it whenever it was asked for
# anything other than `all', so a jobspec cannot request a stage and forget the
# flag. The two can never disagree because there is only one of them.
#
# Unset -- a laptop, or any single environment that has every tool -- and every
# prerequisite below applies exactly as before. `make all' is unchanged.
ifndef SFD_NO_REBUILD
image: dist
sbom:  image
scan:  sbom
dist:  build test
endif

build: ## Compile
	@sh scripts/build.sh

test: ## Run the tests
	@sh scripts/test.sh

# AFTER dist, and that ordering is the whole reason `dist` moved up this file.
#
# An image needs the binaries to put IN it, and `dist` is the only step that
# produces them at a known path — `build` compiles and keeps nothing. So a
# Containerfile here says
#
#     COPY dist/artifacts/<binary> /<binary>
#
# and that same line works on a laptop, where $(ARTIFACTS) already IS
# ./dist/artifacts, and inside a build machine, where scripts/image.sh mirrors
# the staging directory to that path before building. One line, one meaning,
# both places.
#
# Building the binary a second time inside the Containerfile is the obvious
# alternative and the wrong one: it needs a toolchain base image and a module
# cache inside a build with no network, and it would ship a binary that no step
# of this workflow tested.
image: ## Build the container image and STAGE it as an OCI archive
	@sh scripts/image.sh

# AFTER image, on purpose: an SBOM is a description of what was produced, and
# one generated from the source tree alone would omit both whatever the compiler
# actually linked and everything the base image brought in. When an image was
# staged this step writes a second document describing it, and `scan` checks
# both.
sbom: ## Describe what was built (CycloneDX)
	@sh scripts/sbom.sh

# Reads the SBOMs rather than re-scanning the tree, so the thing checked for
# vulnerabilities is the same document that ships beside the artifact. Scanning
# the tree separately would let the two disagree, and the SBOM is what anyone
# auditing this later will read. Every document `sbom` wrote is scanned, so
# turning on the gate covers the image as well as the tree without a second
# policy to keep in step.
scan: ## Check the SBOM against known vulnerabilities
	@sh scripts/scan.sh

# FIRST of the staging steps, not last. It used to run last so that it could
# count the SBOM and the vulnerability report on its way out; now `image` needs
# what it stages, so it runs before them and counts only what it put there
# itself. The runner collects the whole directory afterwards either way.
dist: ## Stage artifacts for collection (does NOT publish)
	@sh scripts/dist.sh

clean:
	@rm -rf $(CURDIR)/dist

help:
	@grep -hE '^[a-z-]+:.*##' $(MAKEFILE_LIST) | sort | \
	  awk 'BEGIN {FS = ":.*##"}; {printf "  \033[36m%-10s\033[0m %s\n", $$1, $$2}'
	@echo ""
	@echo "  artifacts stage to: $(ARTIFACTS)"
	@echo "  there is no publish target, deliberately — see the header"
