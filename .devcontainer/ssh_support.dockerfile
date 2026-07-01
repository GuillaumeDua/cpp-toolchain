ARG BASE_IMAGE=cpp-toolchain-dev
FROM ${BASE_IMAGE} as ssh-support

RUN apt-get update && apt-get install -qqy \
    openssh-server  \
    rsync
RUN mkdir /var/run/sshd

# Remote user (opt-in)
ARG USER_NAME
ARG USER_PASSWORD=default
RUN ([ -z "${USER_NAME}" ] || [ -z "${USER_PASSWORD}" ]) && echo "[ARG] USER_NAME and/or USER_PASSWORD is empty, no user will be created." \
    || (                                                        \
        echo "Adding user [${USER_NAME}] ..."                   \
        && useradd -m ${USER_NAME}                              \
        && echo "${USER_NAME}:${USER_PASSWORD}" | chpasswd      \
        && adduser ${USER_NAME} sudo                            \
        && echo "${USER_NAME} ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers \
        && sed -i 's/#PermitRootLogin prohibit-password/PermitRootLogin yes/' /etc/ssh/sshd_config \
        && sed -i 's/#PasswordAuthentication yes/PasswordAuthentication yes/' /etc/ssh/sshd_config \
        && echo "AllowUsers ${USER_NAME}" >> /etc/ssh/sshd_config \
    )

EXPOSE 22
CMD ["/usr/sbin/sshd", "-D"]

# Notes
#   Skip password on host side:
#   $ sudo apt-get install sshpass
#   $ sshpass -p your_password ssh user@hostname
