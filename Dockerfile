# Note: We use 22.04 since AppImage recommends building on the
# oldest configuration that you support

ARG SWIFT_VERSION=6.3.2
FROM swift:${SWIFT_VERSION}-jammy AS build-base

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


FROM build-base AS build-xtool-base

COPY --from=build-limd /prefix/usr /usr
COPY --from=build-xadi /prefix/usr /usr

WORKDIR /xtool

FROM build-xtool-base AS dev

# Docker doesn't support FUSE
ENV APPIMAGE_EXTRACT_AND_RUN=1

# Use the host's usbmuxd.
# You probably want to use socat on the host to forward this port to /var/run/usbmuxd:
# socat -dd TCP-LISTEN:27015,range=127.0.0.1/32,reuseaddr,fork UNIX-CLIENT:/var/run/usbmuxd
ENV USBMUXD_SOCKET_ADDRESS=host.docker.internal:27015

CMD [ "/bin/bash" ]

FROM build-base AS dev-android

ARG SWIFT_VERSION
ARG NDK_VERSION=27c

ENV ANDROID_NDK_HOME=/opt/android-ndk-r${NDK_VERSION}
ENV ANDROID_SWIFT_SDK=/root/.swiftpm/swift-sdks/swift-${SWIFT_VERSION}-RELEASE_android.artifactbundle
ENV ANDROID_NATIVE_PREFIX=/opt/android-native

RUN curl -fSL --retry 3 -o /tmp/ndk.zip "https://dl.google.com/android/repository/android-ndk-r${NDK_VERSION}-linux.zip" \
    && unzip -q /tmp/ndk.zip -d /opt \
    && rm /tmp/ndk.zip

RUN curl -fSL --retry 3 -o /tmp/swift-android-sdk.tar.gz "https://download.swift.org/swift-${SWIFT_VERSION}-release/android-sdk/swift-${SWIFT_VERSION}-RELEASE/swift-${SWIFT_VERSION}-RELEASE_android.artifactbundle.tar.gz" \
    && swift sdk install /tmp/swift-android-sdk.tar.gz \
    && rm /tmp/swift-android-sdk.tar.gz \
    && "$ANDROID_SWIFT_SDK/swift-android/scripts/setup-android-sdk.sh"

COPY Android/build-native-libs.sh /tmp/build-native-libs.sh
RUN /tmp/build-native-libs.sh "$ANDROID_SWIFT_SDK/swift-android" "$ANDROID_NATIVE_PREFIX" \
    && rm /tmp/build-native-libs.sh

# Keep SwiftPM's systemLibrary targets from finding host libraries.
ENV PKG_CONFIG_PATH=${ANDROID_NATIVE_PREFIX}/lib/pkgconfig
ENV PKG_CONFIG_LIBDIR=${ANDROID_NATIVE_PREFIX}/lib/pkgconfig

WORKDIR /xtool
CMD [ "/bin/bash" ]

FROM build-xtool-base AS build-xtool

ADD Package.swift Package.resolved /xtool/
RUN swift package resolve

ADD . /xtool
RUN ./Linux/build.sh

FROM swift:6.3 AS xtool

COPY --from=build-xtool /xtool/Linux/packages/xtool-*.AppImage /xtool/xtool.AppImage
RUN (cd /xtool && ./xtool.AppImage --appimage-extract) \
    && mv /xtool/squashfs-root /usr/local/xtool \
    && rm -rf /xtool \
    && ln -s /usr/local/xtool/AppRun /usr/local/bin/xtool
