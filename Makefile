APP = build/Typestro.app
INSTALL_DIR = /Applications

.PHONY: build run install uninstall stop clean logs dist release probe test

build:
	./build.sh release

run: build stop
	open $(APP)

# Login items work best from /Applications; install puts it there and launches it.
install: build stop
	rm -rf $(INSTALL_DIR)/Typestro.app
	ditto $(APP) $(INSTALL_DIR)/Typestro.app
	open $(INSTALL_DIR)/Typestro.app

uninstall: stop
	rm -rf $(INSTALL_DIR)/Typestro.app

# Quits normally, so Typestro puts back any macOS autocorrect settings it switched off.
stop:
	-osascript -e 'tell application id "com.mattmoglia.typestro" to quit' 2>/dev/null || true
	-sleep 1

clean:
	rm -rf .build build

test:
	swift test

# Runs the prompts on sample sentences and prints what Claude changes, with timings.
probe:
	swift run typestro-probe

# Zip the app for sending to someone else.
dist: build
	mkdir -p dist
	rm -f dist/Typestro.zip
	ditto -c -k --keepParent $(APP) dist/Typestro.zip
	@echo "Wrote dist/Typestro.zip"

# Signed, notarized, published release: make release VERSION=1.1 NOTES="..."
release:
	./release.sh $(VERSION) "$(NOTES)"

# Live log stream from the app (what Console.app would show).
logs:
	/usr/bin/log stream --level info --style compact --predicate 'process == "Typestro"'
