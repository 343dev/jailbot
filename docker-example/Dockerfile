FROM debian:stable

ENV USERNAME=jailbot

# Install system and Python packages, then remove package manager metadata.
RUN apt-get update \
	&& apt-get upgrade -y \
	&& apt-get install -y --no-install-recommends \
	# Things you can't live without
	git vim curl unzip ca-certificates less fd-find ripgrep shellcheck sudo file \
	python3 python3-pip python-is-python3 build-essential pkg-config man-db openssh-client procps \
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
