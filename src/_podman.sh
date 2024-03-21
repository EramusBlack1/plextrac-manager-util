function podman_setup() {
  info "Configuring up PlexTrac with podman"
  debug "Podman Network Configuration"
  if container_client network exists plextrac; then
    debug "Network plextrac already exists"
  else
    debug "Creating network plextrac"
    container_client network create plextrac 1>/dev/null
  fi
  if container_client volume exists postgres-initdb; then
    debug "Volume postgres-initdb already exists"
  else
    debug "Creating volume postgres-initdb"
    container_client volume create postgres-initdb 1>/dev/null
    deploy_volume_contents_postgres
  fi
  create_volume_directories

  #####
  # Placeholder for right now. These ENVs may need to be set in the .env file if we are using podman.
  #####
  #POSTGRES_HOST_AUTH_METHOD=scram-sha-256
  #POSTGRES_INITDB_ARGS="--auth-local=scram-sha-256 --auth-host=scram-sha-256"
  #PG_MIGRATE_PATH=/usr/src/plextrac-api
  #PGDATA: /var/lib/postgresql/data/pgdata
}

function plextrac_install_podman() {
  declare -A serviceValues

  export POSTGRES_HOST_AUTH_METHOD=scram-sha-256
  export POSTGRES_INITDB_ARGS="--auth-local=scram-sha-256 --auth-host=scram-sha-256"
  export PG_MIGRATE_PATH=/usr/src/plextrac-api
  export PGDATA=/var/lib/postgresql/data/pgdata

  databaseNames=("plextracdb" "postgres")
  serviceNames=("plextracdb" "postgres" "redis" "plextracapi" "notification-engine" "notification-sender" "contextual-scoring-service" "migrations" "plextracnginx")
  serviceValues[network]="--network=plextrac"
  serviceValues[env-file]="--env-file /opt/plextrac/.env"
  serviceValues[cb-volumes]="-v dbdata:/opt/couchbase/var:rw -v couchbase-backups:/backups:rw"
  serviceValues[cb-ports]="-p 127.0.0.1:8091-8094:8091-8094"
  serviceValues[cb-healthcheck]=""
  serviceValues[cb-image]="docker.io/plextrac/plextracdb:7.2.0"
  serviceValues[pg-volumes]="-v postgres-initdb:/docker-entrypoint-initdb.d -v postgres-data:/var/lib/postgresql/data -v postgres-backups:/backups"
  serviceValues[pg-ports]="-p 127.0.0.1::5432"
  serviceValues[pg-healthcheck]=""
  serviceValues[pg-image]="docker.io/postgres:14-alpine"
  serviceValues[pg-env-vars]="-e 'POSTGRES_HOST_AUTH_METHOD' -e 'POSTGRES_INITDB_ARGS' -e 'PG_MIGRATE_PATH' -e 'PGDATA'"
  serviceValues[api-volumes]="-v uploads:/usr/src/plextrac-api/uploads:rw -v datalake-maintainer-keys:/usr/src/plextrac-api/keys/gcp -v localesOverride:/usr/src/plextrac-api/localesOverride:rw"
  serviceValues[api-healthcheck]=""
  serviceValues[api-image]="docker.io/plextrac/plextracapi:${UPGRADE_STRATEGY:-stable}"
  serviceValues[redis-volumes]="-v redis:/etc/redis:rw"
  serviceValues[redis-entrypoint]=$(printf '%s%s%s%s%s%s%s%s' "--entrypoint=" "[" "\"redis-server\"" "," "\"--requirepass\"" "," "\"${REDIS_PASSWORD}\"" "]")
  serviceValues[redis-image]="docker.io/redis:6.2-alpine"
  serviceValues[notification-engine-entrypoint]='--entrypoint ["npm","run","start:notification-engine"]'
  serviceValues[notification-sender-entrypoint]='--entrypoint ["npm","run","start:notification-sender"]'
  serviceValues[contextual-scoring-service-entrypoint]='--entrypoint ["npm","run","start:contextual-scoring-service"]'
  serviceValues[migrations-volumes]="-v uploads:/usr/src/plextrac-api/uploads:rw"
  serviceValues[plextracnginx-volumes]="-v letsencrypt:/etc/letsencrypt:rw"
  serviceValues[plextracnginx-ports]="-p 0.0.0.0:443:443"
  serviceValues[plextracnginx-image]="docker.io/plextrac/plextracnginx:${UPGRADE_STRATEGY:-stable}"

  title "Installing PlexTrac Instance"
  requires_user_plextrac
  mod_configure
  info "Starting Databases before other services"
  # Check if DB running first, then start it.
  debug "Handling Databases..."
  for database in "${databaseNames[@]}"; do
    debug "Checking $database"
    if container_client container exists "$database"; then
      debug "$database already exists"
      # if database exists but isn't running
      if [ "$(container_client container inspect --format '{{.State.Status}}' "$database")" != "running" ]; then
        debug "Starting $database"
        container_client start "$database" 1>/dev/null
      else
        debug "$database is already running"
      fi
    else
      debug "Container doesn't exist. Creating $database"
      if [ "$database" == "plextracdb" ]; then
        local volumes=${serviceValues[cb-volumes]}
        local ports="${serviceValues[cb-ports]}"
        local healthcheck="${serviceValues[cb-healthcheck]}"
        local image="${serviceValues[cb-image]}"
        local env_vars=""
      elif [ "$database" == "postgres" ]; then
        local volumes="${serviceValues[pg-volumes]}"
        local ports="${serviceValues[pg-ports]}"
        local healthcheck="${serviceValues[pg-healthcheck]}"
        local image="${serviceValues[pg-image]}"
        local env_vars="${serviceValues[pg-env-vars]}"
      fi
      container_client run "${serviceValues[env-file]}" "$env_vars" --restart=always "$healthcheck" \
        "$volumes" --name="${database}" "${serviceValues[network]}" "$ports" -d "$image" 1>/dev/null
      info "Sleeping to give $database a chance to start up"
      local progressBar
      for i in `seq 1 10`; do
        progressBar=`printf ".%.0s%s"  {1..$i} "${progressBar:-}"`
        msg "\r%b" "${GREEN}[+]${RESET} ${NOCURSOR}${progressBar}"
        sleep 2
      done
      >&2 echo -n "${RESET}"
      log "Done"
    fi
  done
  mod_autofix
  if [ ${RESTOREONINSTALL:-0} -eq 1 ]; then
    info "Restoring from backups"
    log "Restoring databases first"
    RESTORETARGET="couchbase" mod_restore
    if [ -n "$(ls -A -- ${PLEXTRAC_BACKUP_PATH}/postgres/)" ]; then
      RESTORETARGET="postgres" mod_restore
    else
      debug "No postgres backups to restore"
    fi
    debug "Checking for uploads to restore"
    if [ -n "$(ls -A -- ${PLEXTRAC_BACKUP_PATH}/uploads/)" ]; then
      log "Starting API to prepare for uploads restore"
      if container_client container exists plextracapi; then
        if [ "$(container_client container inspect --format '{{.State.Status}}' plextracapi)" != "running" ]; then
          container_client start plextracapi 1>/dev/null
        else
          log "plextracapi is already running"
        fi
      else
        debug "Creating plextracapi"
        container_client run "${serviceValues[env-file]}" --restart=always "$healthcheck" \
        "$volumes" --name="plextracapi" "${serviceValues[network]}" -d "${serviceValues[api-image]}" 1>/dev/null
      fi
      log "Restoring uploads"
      RESTORETARGET="uploads" mod_restore
    else
      debug "No uploads to restore"
    fi
  fi
  
  mod_start "${INSTALL_WAIT_TIMEOUT:-600}" # allow up to 10 or specified minutes for startup on install, due to migrations
  mod_info
  info "Post installation note:"
  log "If you wish to have access to historical logs, you can configure docker to send logs to journald."
  log "Please see the config steps at"
  log "https://docs.plextrac.com/plextrac-documentation/product-documentation-1/on-premise-management/setting-up-historical-logs"
}

function plextrac_start_podman() {
  declare -A serviceValues

  export POSTGRES_HOST_AUTH_METHOD=scram-sha-256
  export POSTGRES_INITDB_ARGS="--auth-local=scram-sha-256 --auth-host=scram-sha-256"
  export PG_MIGRATE_PATH=/usr/src/plextrac-api
  export PGDATA=/var/lib/postgresql/data/pgdata

  databaseNames=("plextracdb" "postgres")
  serviceNames=("plextracdb" "postgres" "redis" "plextracapi" "notification-engine" "notification-sender" "contextual-scoring-service" "migrations" "plextracnginx")
  serviceValues[network]="--network=plextrac"
  serviceValues[env-file]="--env-file /opt/plextrac/.env"
  serviceValues[cb-volumes]="-v dbdata:/opt/couchbase/var:rw -v couchbase-backups:/backups:rw"
  serviceValues[cb-ports]="-p 127.0.0.1:8091-8094:8091-8094"
  serviceValues[cb-healthcheck]=""
  serviceValues[cb-image]="docker.io/plextrac/plextracdb:7.2.0"
  serviceValues[pg-volumes]="-v postgres-initdb:/docker-entrypoint-initdb.d -v postgres-data:/var/lib/postgresql/data -v postgres-backups:/backups"
  serviceValues[pg-ports]="-p 127.0.0.1::5432"
  serviceValues[pg-healthcheck]=""
  serviceValues[pg-image]="docker.io/postgres:14-alpine"
  serviceValues[pg-env-vars]="-e 'POSTGRES_HOST_AUTH_METHOD' -e 'POSTGRES_INITDB_ARGS' -e 'PG_MIGRATE_PATH' -e 'PGDATA'"
  serviceValues[api-volumes]="-v uploads:/usr/src/plextrac-api/uploads:rw -v datalake-maintainer-keys:/usr/src/plextrac-api/keys/gcp -v localesOverride:/usr/src/plextrac-api/localesOverride:rw"
  serviceValues[api-healthcheck]=""
  serviceValues[api-image]="docker.io/plextrac/plextracapi:${UPGRADE_STRATEGY:-stable}"
  serviceValues[redis-volumes]="-v redis:/etc/redis:rw"
  serviceValues[redis-entrypoint]=$(printf '%s' "--entrypoint=" "[" "\"redis-server\"" "," "\"--requirepass\"" "," "\"${REDIS_PASSWORD}\"" "]")
  serviceValues[redis-image]="docker.io/redis:6.2-alpine"
  serviceValues[notification-engine-entrypoint]='--entrypoint ["npm","run","start:notification-engine"]'
  serviceValues[notification-sender-entrypoint]='--entrypoint ["npm","run","start:notification-sender"]'
  serviceValues[contextual-scoring-service-entrypoint]='--entrypoint ["npm","run","start:contextual-scoring-service"]'
  serviceValues[migrations-volumes]="-v uploads:/usr/src/plextrac-api/uploads:rw"
  serviceValues[plextracnginx-volumes]="-v letsencrypt:/etc/letsencrypt:rw"
  serviceValues[plextracnginx-ports]="-p 0.0.0.0:80:80 -p 0.0.0.0:443:443"
  serviceValues[plextracnginx-image]="docker.io/plextrac/plextracnginx:${UPGRADE_STRATEGY:-stable}"
  
  title "Starting PlexTrac..."
  requires_user_plextrac
  
  for service in "${serviceNames[@]}"; do
  debug "Checking $service"
    local volumes=""
    local ports=""
    local healthcheck=""
    local image="${serviceValues[api-image]}"
    local restart_policy="--restart=always"
    local entrypoint=""
    local deploy=""
    local env_vars=""
    if container_client container exists "$service"; then
      if [ "$(container_client container inspect --format '{{.State.Status}}' "$service")" != "running" ]; then
        debug "Starting $service"
        container_client start "$service" 1>/dev/null
      else
        debug "$service is already running"
      fi
    else
      if [ "$service" == "plextracdb" ]; then
        local volumes=${serviceValues[cb-volumes]}
        local ports="${serviceValues[cb-ports]}"
        local healthcheck="${serviceValues[cb-healthcheck]}"
        local image="${serviceValues[cb-image]}"
      elif [ "$service" == "postgres" ]; then
        local volumes="${serviceValues[pg-volumes]}"
        local ports="${serviceValues[pg-ports]}"
        local healthcheck="${serviceValues[pg-healthcheck]}"
        local image="${serviceValues[pg-image]}"
        local env_vars="${serviceValues[pg-env-vars]}"
      elif [ "$service" == "plextracapi" ]; then
        local volumes="${serviceValues[api-volumes]}"
        local healthcheck="${serviceValues[api-healthcheck]}"
        local image="${serviceValues[api-image]}"
      elif [ "$service" == "redis" ]; then
        local volumes="${serviceValues[redis-volumes]}"
        local image="${serviceValues[redis-image]}"
        local entrypoint="${serviceValues[redis-entrypoint]}"
      elif [ "$service" == "notification-engine" ]; then
        local entrypoint="${serviceValues[notification-engine-entrypoint]}"
      elif [ "$service" == "notification-sender" ]; then
        local entrypoint="${serviceValues[notification-sender-entrypoint]}"
      elif [ "$service" == "contextual-scoring-service" ]; then
        local entrypoint="${serviceValues[contextual-scoring-service-entrypoint]}"
        local deploy="" # update this
      elif [ "$service" == "migrations" ]; then
        local volumes="${serviceValues[migrations-volumes]}"
      elif [ "$service" == "plextracnginx" ]; then
        local volumes="${serviceValues[plextracnginx-volumes]}"
        local ports="${serviceValues[plextracnginx-ports]}"
        local image="${serviceValues[plextracnginx-image]}"
      fi
      debug "Creating $service"
      # This specific if loop is because Bash escaping and the specific need for the podman flag --entrypoint were being a massive pain in figuring out. After hours of effort, simply making an if statement here and calling podman directly fixes the escaping issues
      if [ "$service" == "migrations" ]; then
        podman run ${serviceValues[env-file]} $env_vars --entrypoint='["/bin/sh","-c","npm run maintenance:enable && npm run pg:migrate && npm run db:migrate && npm run pg:etl up all && npm run maintenance:disable"]' --restart=no $healthcheck \
        $volumes --name=${service} $deploy ${serviceValues[network]} $ports -d $image 1>/dev/null
        continue
      fi
      container_client run ${serviceValues[env-file]} $env_vars $entrypoint $restart_policy $healthcheck \
        $volumes --name=${service} $deploy ${serviceValues[network]} $ports -d $image 1>/dev/null
    fi
  done
  ## TODO: Write bit to edit the resolver as needed / TEST THIS PLEASE
  waitTimeout=${1:-90}
  info "Waiting up to ${waitTimeout}s for application startup"
  local progressBar
  # todo: extract this to function waitForCondition
  # it should take an optional param which is a function
  # that should return 0 when ready
  (
    while true; do
      progressBar=$(printf ".%s" "${progressBar:-}")
      msg "\r%b" "${GREEN}[+]${RESET} ${NOCURSOR}${progressBar}"
      sleep 2
    done &
    progressBarPid=$!
    debug "Waiting for migrations to run and complete if needed"
    timeout --preserve-status $waitTimeout podman wait migrations >/dev/null || { error "Migrations exceeded timeout"; kill $progressBarPid; exit 1; } &

    timeoutPid=$!
    trap "kill $progressBarPid $timeoutPid >/dev/null 2>&1 || true" SIGINT SIGTERM

    wait $timeoutPid

    kill $progressBarPid >/dev/null 2>&1 || true
    >&2 echo -n "${RESET}"

    msg " Done"
  )
}