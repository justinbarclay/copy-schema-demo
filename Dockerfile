FROM silex/emacs:27-dev
RUN rm -rf ~/.emacs.d/
RUN git clone --depth 1 https://github.com/hlissner/doom-emacs ~/.emacs.d
COPY ./init.el /root/.doom.d/init.el
RUN yes | ~/.emacs.d/bin/doom install
ARG DEBIAN_FRONTEND=noninteractive
RUN apt-get update \
    && apt-get install -y postgresql-common \
    && sed -ri 's/#(create_main_cluster) .*$/\1 = false/' /etc/postgresql-common/createcluster.conf
RUN yes | sh /usr/share/postgresql-common/pgdg/apt.postgresql.org.sh
RUN apt-get install -y --\
        postgresql-9.6 \
        postgresql-contrib \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /demo
COPY ./copy-schema.org ./copy-schema.org
