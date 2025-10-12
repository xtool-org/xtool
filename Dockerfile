# Note: We use 22.04 since AppImage recommends building on the
# oldest configuration that you support

FROM swift:6.2-jammy AS build-base

RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    ca-certificates \
    build-essential \
    checkinstall \
    git \
    autoconf \
    automake \
    libtool-bin \
    libssl-dev \
    pkg-config \
    libxml2 \
    curl libcurl4-openssl-dev \
    zip unzip \
    liblzma-dev zlib1g-dev \
    && rm -rf /var/lib/apt/lists/*


FROM build-base AS build-limd

RUN mkdir -p /prefix

ADD --keep-git-dir=true https://github.com/libimobiledevice/libplist.git#2.6.0 /libplist

RUN cd libplist \
    && ./autogen.sh --prefix /usr --without-cython \
    && make \
    && make install \
    && make install DESTDIR=/prefix

ADD --keep-git-dir=true https://github.com/libimobiledevice/libimobiledevice-glue.git#1.3.1 /libimobiledevice-glue

RUN cd libimobiledevice-glue \
    && ./autogen.sh --prefix /usr \
    && make \
    && make install \
    && make install DESTDIR=/prefix

ADD --keep-git-dir=true https://github.com/libimobiledevice/libusbmuxd.git#2.1.0 /libusbmuxd

RUN cd libusbmuxd \
    && ./autogen.sh --prefix /usr \
    && make \
    && make install \
    && make install DESTDIR=/prefix

ADD --keep-git-dir=true https://github.com/libimobiledevice/libtatsu.git#1.0.4 /libtatsu

RUN cd libtatsu \
    && ./autogen.sh --prefix /usr \
    && make \
    && make install \
    && make install DESTDIR=/prefix

ADD --keep-git-dir=true https://github.com/libimobiledevice/libimobiledevice.git#master /libimobiledevice

RUN cd libimobiledevice \
    && ./autogen.sh --prefix /usr --without-cython \
    && make \
    && make install \
    && make install DESTDIR=/prefix


FROM build-base AS build-xadi

RUN mkdir -p /prefix/usr/lib

RUN curl -fsS https://dlang.org/install.sh | bash -s ldc

ADD https://github.com/xtool-org/xadi.git#main /xadi

RUN cd xadi \
    && /bin/bash -c 'source $(/root/dlang/install.sh ldc -a) && dub build --build=release' \
    && cp -r bin/libxadi.so /prefix/usr/lib/libxadi.so


FROM build-base

COPY --from=build-limd /prefix/usr /usr
COPY --from=build-xadi /prefix/usr /usr

# Docker doesn't support FUSE
ENV APPIMAGE_EXTRACT_AND_RUN=1

# Use the host's usbmuxd.
# You probably want to use socat on the host to forward this port to /var/run/usbmuxd:
# socat -dd TCP-LISTEN:27015,range=127.0.0.1/32,reuseaddr,fork UNIX-CLIENT:/var/run/usbmuxd
ENV USBMUXD_SOCKET_ADDRESS=host.docker.internal:27015

WORKDIR /xtool

CMD [ "/bin/bash" ]
