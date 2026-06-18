#!/bin/bash
set -euo pipefail

# Validate secrets exist
for f in \
  /run/secrets/mongo_app_user \
  /run/secrets/mongo_app_pass \
  /run/secrets/mongo_admin_user \
  /run/secrets/mongo_admin_pass
do
  [[ -s "$f" ]] || { echo "FATAL: missing secret $f"; exit 1; }
done

# Read secrets into shell vars
MONGO_APP_USER="$(cat /run/secrets/mongo_app_user)"
MONGO_APP_PASS="$(cat /run/secrets/mongo_app_pass)"
MONGO_ADMIN_USER="$(cat /run/secrets/mongo_admin_user)"
MONGO_ADMIN_PASS="$(cat /run/secrets/mongo_admin_pass)"

echo "Creating role-based MongoDB users..."

mongosh \
  -u "$MONGODB_INITDB_ROOT_USERNAME" \
  -p "$MONGODB_INITDB_ROOT_PASSWORD" \
  --authenticationDatabase admin <<EOF

use admin

print("Creating application user...");
db.createUser({
  user: "$MONGO_APP_USER",
  pwd:  "$MONGO_APP_PASS",
  roles: [ { role: "readWrite", db: "edgev3" } ]
});

print("Creating admin user...");
db.createUser({
  user: "$MONGO_ADMIN_USER",
  pwd:  "$MONGO_ADMIN_PASS",
  roles: [ { role: "dbAdmin", db: "edgev3" } ]
});

print("MongoDB users created successfully");

EOF

echo "Importing initial users collection..."

mongoimport \
  --authenticationDatabase=admin \
  -u "$MONGODB_INITDB_ROOT_USERNAME" \
  -p "$MONGODB_INITDB_ROOT_PASSWORD" \
  --db=edgev3 \
  --collection=users \
  --file=/docker-entrypoint-initdb.d/admin_user.json
