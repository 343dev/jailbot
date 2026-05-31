FROM debian:trixie-20260505@sha256:7e0ade45154451d0730a9818e9c4c8721ea4022e7c4dc1e42d44e99c5f4f1d04

RUN apt-get update \
	&& apt-get upgrade -y \
	&& apt-get install -y --no-install-recommends \
	# Things you can't live without
	git vim curl unzip ca-certificates ffmpeg less fd-find ripgrep shellcheck \
	python3 python3-pip build-essential pkg-config man-db openssh-client procps \
	bubblewrap \
	&& python3 -m pip install PyYAML --break-system-packages \
	&& rm -rf /var/lib/apt/lists/*

COPY --chmod=0755 entrypoint.sh /usr/local/bin/

ENV SHELL=/usr/bin/bash
ENV LANG=C.UTF-8
ENV LC_ALL=C.UTF-8

ENTRYPOINT [ "/usr/local/bin/entrypoint.sh" ]
CMD [ "bash" ]
