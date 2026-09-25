# Operator convenience targets for the Proxmox deploy kit.
# Secrets and site inventory stay outside Git (.env, inventory.json).

.PHONY: help validate test cert server isos rotate-token shellcheck clean

help:
	@echo "Common targets:"
	@echo "  make validate     - validate inventory.json"
	@echo "  make test         - run unit tests"
	@echo "  make cert HOST=ip - generate TLS cert for answer server"
	@echo "  make server       - start answer server (uses .env)"
	@echo "  make isos PVE=... PBS=... - build automated ISOs"
	@echo "  make rotate-token - regenerate ANSWER_TOKEN in .env"
	@echo "  make shellcheck   - bash -n on all scripts"
	@echo "  make clean        - remove generated ISOs, checksums, rendered answers"

validate:
	python3 scripts/validate_inventory.py inventory.json

test:
	python3 -m unittest discover -s tests -v

cert:
	@test -n "$(HOST)" || (echo "Usage: make cert HOST=10.10.20.50" >&2; exit 2)
	scripts/generate_tls_certificate.sh $(HOST) tls

server:
	scripts/run_answer_server.sh --listen 0.0.0.0 --port 8080

isos:
	@test -n "$(PVE)" && test -n "$(PBS)" || (echo "Usage: make isos PVE=/path/pve.iso PBS=/path/pbs.iso" >&2; exit 2)
	scripts/build_isos.sh $(PVE) $(PBS)

rotate-token:
	scripts/rotate_answer_token.sh

shellcheck:
	bash -n scripts/*.sh first-boot/*.sh post-deploy/*.sh remote-access/*.sh

# Remove build artifacts only: generated automated ISOs, their SHA256SUMS,
# and rendered answer files. Never touches source files, inventory.json,
# .env, or tls/ (names are pinned to what build_isos.sh generates).
clean:
	rm -rf output/answers output/proxmox-ve-auto.iso output/proxmox-backup-server-auto.iso output/SHA256SUMS
	@echo "Removed generated ISOs, checksums, and rendered answers from output/"
