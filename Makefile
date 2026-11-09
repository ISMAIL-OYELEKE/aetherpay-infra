# Local validation: everything CI runs, offline, no AWS account needed.
TF_DIRS   := terraform/bootstrap terraform/environments/staging terraform/environments/production
TEST_DIRS := terraform/modules/networking terraform/modules/workload-iam terraform/environments/staging terraform/environments/production

.PHONY: all fmt validate test lint security app check

all: check

fmt:
	terraform fmt -recursive terraform

validate:
	@for d in $(TF_DIRS); do echo "== $$d"; terraform -chdir=$$d init -backend=false -input=false >/dev/null && terraform -chdir=$$d validate || exit 1; done

test:
	@for d in $(TEST_DIRS); do echo "== $$d"; terraform -chdir=$$d init -backend=false -input=false >/dev/null && terraform -chdir=$$d test || exit 1; done

lint:
	terraform fmt -check -recursive terraform
	tflint --init --config=$(CURDIR)/.tflint.hcl
	tflint --chdir=terraform --recursive --config=$(CURDIR)/.tflint.hcl

security:
	checkov -d terraform --config-file .checkov.yaml

app:
	cd app && ruff check . && ruff format --check . && pytest -q

check: lint validate test security app
