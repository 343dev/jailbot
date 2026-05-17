FROM debian:trixie-20260505@sha256:7e0ade45154451d0730a9818e9c4c8721ea4022e7c4dc1e42d44e99c5f4f1d04

RUN apt-get update \
	&& apt-get upgrade -y \
	&& apt-get install -y --no-install-recommends \
	# Things you can't live without
	git vim curl unzip ca-certificates ffmpeg less fd-find ripgrep shellcheck \
	python3 python3-pip build-essential pkg-config man-db openssh-client procps \
	# Chromium dependencies, required for MCP Playwright to function
	# libasound2t64 libatk-bridge2.0-0t64 libatk1.0-0t64 libatspi2.0-0t64 \
	# libcairo2 libcups2t64 libdbus-1-3 libdrm2 libfontconfig1 libfontenc1 \
	# libfreetype6 libgbm1 libglib2.0-0t64 libice6 libnspr4 libnss3 libpango-1.0-0 \
	# libsm6 libunwind8 libx11-6 libxaw7 libxcb1 libxcomposite1 libxdamage1 \
	# libxext6 libxfixes3 libxfont2 libxkbcommon0 libxkbfile1 libxmu6 libxpm4 \
	# libxrandr2 libxt6t64 x11-xkb-utils xfonts-encodings xfonts-utils xserver-common \
	&& python3 -m pip install PyYAML --break-system-packages \
	&& rm -rf /var/lib/apt/lists/*

COPY --chmod=0755 ./bin/difft ./bin/diff-so-fancy /usr/local/bin/
COPY --chmod=0755 entrypoint.sh /usr/local/bin/

ENV SHELL=/usr/bin/bash
ENV LANG=C.UTF-8
ENV LC_ALL=C.UTF-8

ENTRYPOINT [ "/usr/local/bin/entrypoint.sh" ]
CMD [ "bash" ]
