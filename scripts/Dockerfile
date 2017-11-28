FROM alpine:edge
MAINTAINER Marek Vavrusa <marek.vavrusa@nic.cz>

# Environment
ENV BUILD_PKGS build-base automake autoconf libtool pkgconfig git luajit-dev libuv-dev gnutls-dev jansson-dev userspace-rcu-dev curl vim
ENV RUN_PKGS luajit libuv gnutls jansson bash
ENV BUILD_IGNORE gmp nettle jansson gnutls lua libuv cmocka
ENV PKG_CONFIG_PATH /usr/local/lib/pkgconfig
ENV CFLAGS -O2 -ftree-vectorize -fstack-protector -g
ENV LDFLAGS -Wl,--as-needed

# Expose port
EXPOSE 53

# Select entrypoint
WORKDIR /data
CMD ["/usr/local/sbin/kresd"]

# Install dependencies and sources
RUN apk --update add ${RUN_PKGS}
RUN apk add --virtual build-dep ${BUILD_PKGS}
RUN git clone --depth 1 --recurse-submodules --branch docker-fix https://gitlab.labs.nic.cz/knot/knot-resolver.git /tmp/build
WORKDIR /tmp/build
RUN ./scripts/bootstrap-depends.sh /usr/local
RUN make -j4 install
WORKDIR /
RUN apk del --purge build-dep
RUN rm -rf /var/cache/apk/* /tmp/build
