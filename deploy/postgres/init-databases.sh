#!/bin/bash
# Creates one database per service.
#
# Sharing a single PostgreSQL server but giving each service its own database
# keeps the services independent at the schema level without paying for four
# database servers. It is the compromise most teams actually run, and it is
# worth calling out during the session: the boundary that matters is "no service
# reads another service's tables", not "no service shares a host".
#
# The official postgres image runs everything in /docker-entrypoint-initdb.d
# exactly once, on an empty data directory. On EKS that data directory lives on
# an EBS gp3 volume, so this runs on first boot of the StatefulSet and never
# again — even across pod restarts and rescheduling.
set -euo pipefail

for db in events bookings payments notifications; do
    echo "init-databases: creating database '${db}'"
    psql -v ON_ERROR_STOP=1 \
         --username "${POSTGRES_USER}" \
         --dbname "${POSTGRES_DB}" \
         -c "CREATE DATABASE \"${db}\" OWNER \"${POSTGRES_USER}\";"
done

echo "init-databases: done"
