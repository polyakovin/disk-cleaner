.PHONY: verify
verify:
	python3 scripts/commercial-project.py check .
	python3 -m unittest discover -s scripts/tests -v
	swift test --package-path DiskLens
	swift build --package-path DiskLens -c release
