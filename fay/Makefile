# fay - Fast Archive Yielder
# Static build for LFS bootstrap

FC ?= gfortran
CC ?= gcc

# LFS_GENERIC_BUILD=1 for USB (portable), else native optimization
ifeq ($(LFS_GENERIC_BUILD),1)
    FFLAGS ?= -O3 -march=x86-64-v2 -mtune=generic -flto -static
    CFLAGS ?= -O3 -march=x86-64-v2 -mtune=generic -flto
else
    FFLAGS ?= -O3 -march=native -mtune=native -flto -static
    CFLAGS ?= -O3 -march=native -mtune=native -flto
endif

PREFIX ?= /usr
DESTDIR ?=

LIBARCHIVE_VERSION = 3.7.7
LIBARCHIVE_URL = https://github.com/libarchive/libarchive/releases/download/v$(LIBARCHIVE_VERSION)/libarchive-$(LIBARCHIVE_VERSION).tar.xz
LIBARCHIVE_DIR = libarchive-$(LIBARCHIVE_VERSION)
LIBARCHIVE_A = $(LIBARCHIVE_DIR)/.libs/libarchive.a

# Minimal libarchive for bootstrap (xz+zlib only)
LIBARCHIVE_CONF = --disable-shared --enable-static \
    --without-bz2lib --without-libb2 --without-iconv \
    --without-lz4 --without-zstd --without-lzma \
    --without-cng --without-nettle --without-openssl \
    --without-xml2 --without-expat \
    --disable-acl --disable-xattr --disable-posix-regex-lib

# Full libarchive (all compression)
LIBARCHIVE_CONF_FULL = --disable-shared --enable-static

.PHONY: all clean install bootstrap full

all: fay

# Bootstrap: minimal deps for early LFS
bootstrap: fay-bootstrap

# Full: all compression support
full: LIBARCHIVE_CONF := $(LIBARCHIVE_CONF_FULL)
full: fay

fay: fay.f90 $(LIBARCHIVE_A)
	$(FC) $(FFLAGS) -o $@ $< -I$(LIBARCHIVE_DIR)/libarchive \
		$(LIBARCHIVE_A) -lz -llzma -lpthread

fay-bootstrap: fay.f90 $(LIBARCHIVE_A)
	$(FC) $(FFLAGS) -o fay $< -I$(LIBARCHIVE_DIR)/libarchive \
		$(LIBARCHIVE_A) -lz -lpthread

$(LIBARCHIVE_A): $(LIBARCHIVE_DIR)/Makefile
	$(MAKE) -C $(LIBARCHIVE_DIR) -j$$(nproc)

$(LIBARCHIVE_DIR)/Makefile: $(LIBARCHIVE_DIR)/configure
	cd $(LIBARCHIVE_DIR) && ./configure $(LIBARCHIVE_CONF) \
		CFLAGS="$(CFLAGS)" CC="$(CC)"

$(LIBARCHIVE_DIR)/configure:
	@if [ ! -f libarchive-$(LIBARCHIVE_VERSION).tar.xz ]; then \
		curl -fLO $(LIBARCHIVE_URL); \
	fi
	tar xf libarchive-$(LIBARCHIVE_VERSION).tar.xz
	touch $@

install: fay
	install -Dm755 fay $(DESTDIR)$(PREFIX)/bin/fay
	install -dm755 $(DESTDIR)/var/lib/fay

clean:
	rm -rf fay $(LIBARCHIVE_DIR) libarchive-*.tar.xz

# Cross-compilation for LFS Stage 1
cross: FC = $(LFS_TGT)-gfortran
cross: CC = $(LFS_TGT)-gcc
cross: fay
