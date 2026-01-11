FROM nvidia/cuda:13.2.1-base-ubuntu24.04

ARG DEBIAN_FRONTEND=noninteractive

ENV NVIDIA_DRIVER_CAPABILITIES=all
ENV NVIDIA_VISIBLE_DEVICES=all
ENV DISPLAY=:0
ENV HOME=/root
ENV GTK_A11Y=none
ENV NO_AT_BRIDGE=1
ENV LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8

# Common tools + i386 arch so we can install 32-bit deps Steam client
# (and the gbe_fork stub, which is 64-bit only but its siblings may be 32-bit)
# need.
RUN apt-get update && apt-get install -y --no-install-recommends \
      software-properties-common \
      ca-certificates curl wget jq tini gosu vim less procps strace \
      bzip2 unzip p7zip-full binutils file xz-utils \
      locales \
    && add-apt-repository -y multiverse \
    && add-apt-repository -y universe \
    && dpkg --add-architecture i386 \
    && apt-get update

# X server + WM + dbus + zenity
RUN apt-get install -y --no-install-recommends \
      xserver-xorg-core xserver-xorg-legacy xserver-xorg-video-dummy \
      xinit x11-xserver-utils xauth xdotool wmctrl x11-utils \
      openbox dbus dbus-x11 zenity

# GPU userspace (NVIDIA runtime injects the actual driver libs)
RUN apt-get install -y --no-install-recommends \
      libgl1 libglx-mesa0 libegl1 libgles2 \
      libvulkan1 mesa-vulkan-drivers mesa-utils vulkan-tools \
      libasound2t64 libpulse0 pulseaudio-utils

# CS2 runtime text/UI deps
RUN apt-get install -y --no-install-recommends \
      libpango-1.0-0 libpangoft2-1.0-0 libpangocairo-1.0-0 libpango1.0-dev \
      libfontconfig1 libfreetype6 libfreetype-dev \
      libharfbuzz0b libharfbuzz-dev \
      libxrandr2 libxinerama1 libxi6 libxxf86vm1 libxcursor1 \
      libxcomposite1 libxdamage1 libxfixes3 libxtst6 \
      libnss3 libnspr4 \
      libatk1.0-0t64 libatk-bridge2.0-0t64 libcups2t64 \
      libdbus-1-3 libxkbcommon0 libgbm1 libcurl4t64

# GStreamer capture pipeline + ffmpeg
RUN apt-get install -y --no-install-recommends \
      gstreamer1.0-tools \
      gstreamer1.0-plugins-base gstreamer1.0-plugins-good \
      gstreamer1.0-plugins-bad gstreamer1.0-plugins-ugly \
      gstreamer1.0-libav gstreamer1.0-nice gstreamer1.0-x \
      ffmpeg \
      python3 python3-requests

# 32-bit libs required by Steam client + gbe_fork stub companions
RUN apt-get install -y --no-install-recommends \
      lib32gcc-s1 libc6-i386 \
      libsdl2-2.0-0:i386 libncurses6:i386 \
      libxtst6:i386 libx11-6:i386 libxext6:i386 libxrandr2:i386 \
      libxi6:i386 libxfixes3:i386 libxcursor1:i386 libxcomposite1:i386 \
      libxdamage1:i386 libxrender1:i386 libxkbcommon0:i386 libxinerama1:i386 \
      libgl1:i386 libegl1:i386 libgbm1:i386 \
      libnss3:i386 libnspr4:i386 libdbus-1-3:i386 \
      libfreetype6:i386 libpulse0:i386 libva2:i386

# (Steam 32-bit UI libs — libgtk2.0-0:i386 / libpango:i386 etc — dropped
#  because we use the gbe_fork stub instead of the real Steam client. CS2
#  itself is 64-bit and does not need 32-bit GTK/Pango.)

RUN rm -rf /var/lib/apt/lists/*

# steamcmd from Valve's CDN (Ubuntu repos have it via multiverse but
# fetching directly is more deterministic and avoids debconf prompts).
RUN mkdir -p /opt/steamcmd \
 && curl -fsSL https://steamcdn-a.akamaihd.net/client/installer/steamcmd_linux.tar.gz \
    | tar -xz -C /opt/steamcmd \
 && printf '#!/bin/sh\nexec /opt/steamcmd/steamcmd.sh "$@"\n' >/usr/local/bin/steamcmd \
 && chmod +x /usr/local/bin/steamcmd

RUN locale-gen en_US.UTF-8

# Allow non-console user to start Xorg + pre-create the X11 socket dir.
RUN printf 'allowed_users=anybody\nneeds_root_rights=yes\n' >/etc/X11/Xwrapper.config \
 && mkdir -p /tmp/.X11-unix && chmod 1777 /tmp/.X11-unix

# Remove the default ubuntu user (UID 1000), run as root in this dev container.
RUN if id -u ubuntu >/dev/null 2>&1; then userdel -r ubuntu 2>/dev/null || userdel ubuntu; fi \
 && mkdir -p /opt/game-streamer /opt/5stack \
 && chown -R root:root /opt

COPY scripts/ /opt/game-streamer/scripts/
COPY xorg-dummy.conf /etc/X11/xorg-dummy.conf
COPY cfg/ /opt/game-streamer/cfg/
RUN chmod +x /opt/game-streamer/scripts/*.sh /opt/game-streamer/scripts/*.py 2>/dev/null || true

WORKDIR /root

ENTRYPOINT ["/usr/bin/tini", "--", "/opt/game-streamer/scripts/entrypoint.sh"]
