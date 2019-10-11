current_dir = $(shell pwd)

PROJECT = identity_matching
COMMANDS = cmd/match-identities

PKG_OS = darwin linux

DOCKERFILES = Dockerfile:$(PROJECT)
DOCKER_ORG = srcd

# Including ci Makefile
CI_REPOSITORY ?= https://github.com/src-d/ci.git
CI_BRANCH ?= v1
CI_PATH ?= .ci
MAKEFILE := $(CI_PATH)/Makefile.main
$(MAKEFILE):
	git clone --quiet --depth 1 -b $(CI_BRANCH) $(CI_REPOSITORY) $(CI_PATH);
-include $(MAKEFILE)
ifdef TRAVIS_PULL_REQUEST
ifneq ($(TRAVIS_PULL_REQUEST), false)
GOTEST += -tags cipr
$(info Pull Request test mode: $(GOTEST))
endif
endif

fix-style:
	gofmt -s -w .
	goimports -w .

.ONESHELL:
.POSIX:
check-style:
	golint -set_exit_status ./...
	# Run `make fix-style` to fix style errors
	test -z "$$(gofmt -s -d .)"
	test -z "$$(goimports -d .)"
	go vet
	pycodestyle --max-line-length=99 $(current_dir)/research $(current_dir)/parquet2sql

check-generate:
	# -modtime flag is required to make `make check-generate` work.
	# Otherwise, the regenerated file has a different modtime value.
	# `1562752805` corresponds to 2019-07-10 12:00:05 CEST.
	esc -pkg idmatch -prefix blacklists -modtime 1562752805 blacklists | \
		diff --ignore-matching-lines="\/\/ Code generated by \".*\"; DO NOT EDIT\." blacklists.go - \
 		# Run `go generate` to update autogenerated files

install-dev-deps:
	pip3 install --user pycodestyle==2.5.0
	go get -v golang.org/x/lint/golint github.com/mjibson/esc golang.org/x/tools/cmd/goimports

docker-build:
	docker build -t identity_matching .

docker-test: docker-build
	docker-compose up -d
	while ! docker exec im_gitbase sh -c 'mysql -u root --password="" < /tests/test_commits.sql'; do sleep 1; done
	while ! docker exec -it im_postgres psql -U superset -c "\dt"; do sleep 1; done
	(sleep 120 && killall make) &
	while ! docker run --network identity_matching_default \
    -e IDENTITY_MATCHING_OUTPUT="identities" \
    -e IDENTITY_MATCHING_GITBASE_HOST="im_gitbase" \
    -e IDENTITY_MATCHING_GITBASE_PORT="3306" \
    -e IDENTITY_MATCHING_GITBASE_USER="root" \
    -e IDENTITY_MATCHING_GITBASE_PASSWORD="" \
    -e IDENTITY_MATCHING_POSTGRES_DB="superset"\
    -e IDENTITY_MATCHING_POSTGRES_USER="superset" \
    -e IDENTITY_MATCHING_POSTGRES_PASSWORD="superset" \
    -e IDENTITY_MATCHING_POSTGRES_HOST="im_postgres" \
    -e IDENTITY_MATCHING_POSTGRES_PORT="5432" \
    -e IDENTITY_MATCHING_POSTGRES_ALIASES_TABLE="aliases" \
    -e IDENTITY_MATCHING_POSTGRES_IDENTITIES_TABLE="identities" \
    -e IDENTITY_MATCHING_MAX_IDENTITIES="20" \
    -e IDENTITY_MATCHING_MONTHS="12" \
    -e IDENTITY_MATCHING_MIN_COUNT="5" \
	identity_matching; do sleep 1; done
	docker exec -it im_postgres psql -U superset -c "SELECT * FROM identities ORDER BY id" > identities.txt
	docker exec -it im_postgres psql -U superset -c "SELECT * FROM aliases ORDER BY id, name, repo" > aliases.txt
	diff identities.txt tests/test_identities.txt && rm identities.txt
	diff aliases.txt tests/test_aliases.txt && rm aliases.txt
	docker-compose down

.PHONY: check-style check-generate install-dev-deps fix-style docker-build docker-compose-build
