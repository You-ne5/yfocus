SHELL := /bin/bash
PREFIX ?= /usr/local
BUN ?= bun

.PHONY: build test plugin-test validate fmt clean

build:
	./build.sh

install: build
	install -Dm755 bin/yfocus $(DESTDIR)$(PREFIX)/bin/yfocus

uninstall:
	rm -f $(DESTDIR)$(PREFIX)/bin/yfocus

test:
	$(BUN) test

plugin-test:
	omarchy plugin validate .
	qmllint -I "$(OMARCHY_PATH)/shell" BarWidget.qml FocusOverlay.qml || echo "qmllint not available"

validate: plugin-test

clean:
	rm -rf target
	rm -f bin/yfocus
