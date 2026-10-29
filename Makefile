ARCHS = arm64
TARGET = iphone:clang:latest:14.0
THEOS_DEVICE_IP = localhost
THEOS_DEVICE_PORT = 22222

SUBPROJECTS = XiaoCanAdBlock

.PHONY: all package clean $(SUBPROJECTS)

all: $(SUBPROJECTS)

$(SUBPROJECTS):
	$(MAKE) -C $@

package:
	@for d in $(SUBPROJECTS); do \
		echo ">>> Packaging $$d"; \
		$(MAKE) -C $$d package || exit $$?; \
	done
	@mkdir -p dist
	@cp -f */packages/*.deb dist/ 2>/dev/null || true
	@cp -f */.theos/_/Library/MobileSubstrate/DynamicLibraries/*.dylib dist/ 2>/dev/null || true
	@cp -f */.theos/_/Library/MobileSubstrate/DynamicLibraries/*.plist dist/ 2>/dev/null || true
	@echo ">>> dist/:"; ls -l dist/

clean:
	@for d in $(SUBPROJECTS); do \
		$(MAKE) -C $$d clean || exit $$?; \
	done
	@rm -rf dist packages
