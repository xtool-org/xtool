# Note: We use 20.04 since AppImage recommends building on the
# oldest configuration that you support

FROM ubuntu:focal AS limd-build

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
    ca-certificates \
    build-essential \
    checkinstall \
    git \
    autoconf \
    automake \
    libtool-bin \
    libssl-dev \
    pkg-config \
    libcurl4-openssl-dev \
    && rm -rf /var/lib/apt/lists/*

RUN mkdir /prefix

RUN git clone https://github.com/libimobiledevice/libplist.git \
    && cd libplist \
    && ./autogen.sh --prefix /usr --without-cython \
    && make \
    && make install \
    && make install DESTDIR=/prefix \
    && cd .. \
    && rm -rf libplist

RUN git clone https://github.com/libimobiledevice/libimobiledevice-glue.git \
    && cd libimobiledevice-glue \
    && ./autogen.sh --prefix /usr \
    && make \
    && make install \
    && make install DESTDIR=/prefix \
    && cd .. \
    && rm -rf libimobiledevice-glue

RUN git clone https://github.com/libimobiledevice/libusbmuxd.git \
    && cd libusbmuxd \
    && ./autogen.sh --prefix /usr \
    && make \
    && make install \
    && make install DESTDIR=/prefix \
    && cd .. \
    && rm -rf libusbmuxd

RUN git clone https://github.com/libimobiledevice/libtatsu.git \
    && cd libtatsu \
    && ./autogen.sh --prefix /usr \
    && make \
    && make install \
    && make install DESTDIR=/prefix \
    && cd .. \
    && rm -rf libtatsu

RUN git clone https://github.com/libimobiledevice/libimobiledevice.git \
    && cd libimobiledevice \
    && ./autogen.sh --prefix /usr --without-cython --enable-debug \
    && make \
    && make install \
    && make install DESTDIR=/prefix \
    && cd .. \
    && rm -rf libimobiledevice


FROM swift:6.0-focal

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
    curl \
    libssl-dev \
    ca-certificates \
    zip unzip \
    && rm -rf /var/lib/apt/lists/*


COPY --from=limd-build /prefix/usr /usr

# Docker doesn't support FUSE
ENV APPIMAGE_EXTRACT_AND_RUN=1

# Use the host's usbmuxd.
# You probably want to use socat on the host to forward this port to /var/run/usbmuxd:
# socat -dd TCP-LISTEN:27015,range=127.0.0.1/32,reuseaddr,fork UNIX-CLIENT:/var/run/usbmuxd
ENV USBMUXD_SOCKET_ADDRESS=host.docker.internal:27015

WORKDIR /Supersign

ENTRYPOINT [ "/bin/bash" ]
