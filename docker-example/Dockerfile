FROM debian:stable

ENV USERNAME=jailbot

# Install system and Python packages, then remove package manager metadata.
RUN apt-get update \
	&& apt-get upgrade -y \
	&& apt-get install -y --no-install-recommends \
	# Things you can't live without
	git vim curl unzip ca-certificates less fd-find ripgrep shellcheck sudo file \
	python3 python3-pip python-is-python3 build-essential pkg-config man-db openssh-client procps \
	# Chromium deps
	fonts-noto-color-emoji fonts-liberation libfontconfig1 libfreetype6 \
	libasound2t64 libatk-bridge2.0-0t64 libatk1.0-0t64 libatspi2.0-0t64 libcairo2 \
	libcups2t64 libdbus-1-3 libdrm2 libgbm1 libglib2.0-0t64 libnspr4 libnss3 \
	libpango-1.0-0 libx11-6 libxcb1 libxcomposite1 libxdamage1 libxext6 libxfixes3 \
	libxkbcommon0 libxrandr2 \
  && python3 -m pip install PyYAML --break-system-packages \
	&& rm -rf /var/lib/apt/lists/*

# Create the non-root user and allow passwordless sudo.
RUN useradd --create-home --shell /bin/bash "${USERNAME}" \
	&& echo "${USERNAME} ALL=(ALL:ALL) NOPASSWD: ALL" > "/etc/sudoers.d/${USERNAME}" \
	&& chmod 0440 "/etc/sudoers.d/${USERNAME}"

COPY --chmod=0755 entrypoint.sh /usr/local/bin/

ENV SHELL=/usr/bin/bash
ENV LANG=C.UTF-8
ENV LC_ALL=C.UTF-8
ENV HOME=/home/${USERNAME}

WORKDIR ${HOME}
USER ${USERNAME}

ENTRYPOINT [ "/usr/local/bin/entrypoint.sh" ]
CMD [ "bash" ]
