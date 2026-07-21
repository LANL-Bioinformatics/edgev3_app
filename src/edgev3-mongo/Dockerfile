FROM mongodb/mongodb-community-server:7.0.0-ubuntu2204
LABEL maintainer="chienchi@lanl.gov"

USER root
COPY --chmod=755 installation/init-mongo-users.sh /docker-entrypoint-initdb.d/init-mongo-users.sh
RUN chown -R mongodb:mongodb /docker-entrypoint-initdb.d

USER mongodb
