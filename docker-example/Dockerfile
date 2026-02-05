FROM debian:trixie-slim

RUN apt-get update \
	&& apt-get upgrade -y \
	&& apt-get install -y --no-install-recommends \
	# Things you can't live without
	git vim curl unzip ca-certificates ffmpeg less fd-find ripgrep shellcheck \
	&& rm -rf /var/lib/apt/lists/*

COPY --chmod=0755 ./bin/difft ./bin/diff-so-fancy /usr/local/bin/
COPY --chmod=0755 entrypoint.sh /usr/local/bin/

ENV SHELL=/usr/bin/bash
ENV LANG=C.UTF-8
ENV LC_ALL=C.UTF-8

ENTRYPOINT [ "/usr/local/bin/entrypoint.sh" ]
CMD [ "bash" ]
