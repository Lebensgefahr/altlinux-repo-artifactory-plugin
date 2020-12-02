#!/bin/bash

declare -a URL

ARTIFACTORY="https://your.artifactory.host/artifactory"
PROCESSES=10

usage(){

cat <<EOF

Usage: ${BASH_SOURCE[0]} [OPTION] 

Script for uploading artifacts to Artifactory

  -c, --count                   Count of parallel uploading processes (default 10)
  -U, --user                    CI user name
  -P, --password                CI user password
  -p, --path                    Path with bash wildcards (i.e. "./*/*/*.rpm", "*/*.tar.gz", etc.).
                                Path should be placed in quotes.
  -pn, --project-name           Name of the project
  -pv, --project-vers           Version of the project
  -os, --os-name                OS name. Will be used as repository directory for target OS (centos, altlinux, sles)
                                If not specified, it will be determined from /etc/os-release
  -ov, --os-vers                Version of the operational system (i.e. 7 for centos, 15 for sles, 8 for altlinux, etc.)
                                If not specified, it will be determined from /etc/os-release
  -a, --arch                    Architecture of RPM (If not specified, it will be determined with rpm --eval '%{_arch}')
  -e, --edition                 Distributive edition (i.e. community, enterprise, etc.)
  -j, --job                     Jenkins job name
  -id, --build-id               Jenkins job build ID
  -pkgs, --packages             Mode of build. May take "all" or "incomplete" values
  -h, --help                    Usage info

EOF

}

function check_parameter(){
  KEY="$1"
  VAL="$2"
  if [[ "$VAL" =~ ^- ]]; then
    echo "Error in parameter $KEY. it can't be $VAL"
    exit 1
  fi
}

function parse_options() {

  if [[ $# -eq 0 ]]; then
    echo "No arguments supplied"
    usage
    exit 1
  fi

  while [[ $# -gt 0 ]]; do
    key="$1"
    check_parameter "${@:1:2}"
    case ${key} in
            -c|--count)
                    PROCESSES="$2"; shift 2
                    ;;
            -U|--user)
                    CI_USER="$2"; shift 2
                    ;;
            -P|--password)
                    CI_PASSWORD="$2"; shift 2
                    ;;
            -p|--path)
                    MASK="$2"; shift 2
                    ;;
            -pn|--project-name)
                    PRJ_NAME="$2"; shift 2
                    URL[0]="$PRJ_NAME"
                    ;;
            -pv|--project-vers)
                    PRJ_VERS="$2"; shift 2
                    URL[1]="$PRJ_VERS"
                    ;;
            -os|--os-name)
                    OS_NAME="$2"; shift 2
                    URL[2]="$OS_NAME"
                    ;;
            -ov|--os-vers)
                    OS_VERS="$2"; shift 2
                    URL[3]="$OS_VERS"
                    ;;
            -a|--arch)
                    ARCH="$2"; shift 2
                    URL[5]="$ARCH"
                    ;;
            -e|--edition)
                    EDITION="$2"; shift 2
                    URL[4]="$EDITION"
                    ;;
            -j|--job)
                    JOB="$2"; shift 2
                    ;;
            -id|--build-id)
                    BUILD_ID="$2"; shift 2
                    ;;
            -pkgs|--packages)
                    PACKAGES="$2"; shift 2
                    ;;
            -h|--help)
                    usage
                    exit 0
                    ;;
            *)
                    echo "Error: unknown option" >&2
                    exit 1
                    ;;
    esac
  done
}

function get_arch() {
  # shellcheck disable=SC1083
  if ! ARCH="$(rpm --eval %{_arch})"; then
    return 1
  else
    URL[5]="$ARCH"
    return 0
  fi
}

function get_os_details() {

  RELEASE="/etc/os-release"

  if [[ -f "$RELEASE" ]]; then
    # shellcheck disable=SC1090
    . "$RELEASE"
    OS_NAME="$ID"
    URL[2]="$OS_NAME"
    OS_VERS="$VERSION_ID"
    URL[3]="$OS_VERS"
#    if [[ "$VERSION_ID" =~ [0-9]+ ]]; then
#      OS_VERS="${BASH_REMATCH[0]}"
#    fi
    return 0
  else
    echo "Can't detect OS details" >&2
    return 1
  fi
}

function check_required_params() {
  
  for var in PRJ_NAME PRJ_VERS EDITION; do
    if [[ -z "${!var}" ]]; then
      echo "Parameter ${var} should be provided" >&2
      usage
      exit 1
    fi
  done

  if [[ -z "$ARCH" ]]; then
    get_arch || exit 1
  fi

  if [[ -z "$OS_NAME" && -z "$OS_VERS" ]]; then
    get_os_details || exit 1
  elif [[ -z "$OS_NAME" || -z "$OS_VERS" ]]; then
    echo "You should provide -os and -ov together if your current OS is different from OS you are uploading for" >&2
    exit 1
  fi

  case "$OS_NAME" in 
    altlinux|centos|sles)
      echo "Uploading in repository for $OS_NAME $OS_VERS"
    ;;
    *)
      echo "Error in OS name determination. $OS_NAME is not in list" >&2
      exit 1
    ;;
  esac
 
  if [[ "${#URL[@]}" -lt 6 ]]; then
    echo "Not enough parameters" >&2
    exit 1
  fi

  if [[ -n "$BUILD_ID" ]]; then
    PROPERTIES+="build.number=$BUILD_ID;"
  fi
  
  if [[ -n "$JOB" ]]; then
    PROPERTIES+="job=$JOB;"
  fi

  if [[ -n $PACKAGES ]]; then
    PROPERTIES+="packages=$PACKAGES;"
  fi
}

function create_repo() {

  DEPTH=$((${#URL[@]}-1))

  curl -u "${CI_USER}":"${CI_PASSWORD}" \
       --fail \
       --silent \
       "$ARTIFACTORY/api/repositories/${URL[0]}" > /dev/null || \
  curl  -u "${CI_USER}":"${CI_PASSWORD}" \
        --fail \
        --silent \
        -X PUT \
        -H "Content-Type: application/json" \
        -d '{ 
            "rclass":"local", 
            "packageType":"rpm",
            "repoLayoutRef":"simple-default",
            "excludesPattern": "**/altlinux/**/repodata", 
            "calculateYumMetadata":"true", 
            "yumRootDepth":"'$DEPTH'", 
            "enableFileListsIndexing":"true"
            }' \
        $ARTIFACTORY/api/repositories/"${URL[0]}" > /dev/null || 
  {
    echo "Can't create repository ${URL[0]}" >&2
    exit 1
  }
}

function upload_file(){

  FILE="$1"

  curl --fail -s -u "$CI_USER":"$CI_PASSWORD" \
       -X PUT -T "$FILE" \
       -H "X-Checksum-Sha1:$(sha1sum "$FILE" | awk '{ print $1 }')" \
        "$URI/$(basename "$FILE");$PROPERTIES" > /dev/null ||
  {
    echo "Error while uploading $FILE" >&2
    return 1
  }
}

function _main() {
  i=0
  ERRORS=0
  PIDS=()
  URI="$ARTIFACTORY"

  parse_options "$@"
  check_required_params

  for k in "${URL[@]}"; do
    URI+="/$k"
  done

  if [[ "${URL[2]}" == "altlinux" ]]; then
    URI+="/RPMS.classic"
  fi

  create_repo

  for file in $MASK; do
    if [[ ! -f "$file" ]]; then
      echo "File $file not found"
      exit 1
    fi
    upload_file "$file" &
    PIDS+=("$!")
    if [[ "${#PIDS[@]}" -eq "$PROCESSES" ]]; then
      if ! wait "${PIDS[$i]}"; then
        ERRORS=$((ERRORS+1))
      fi
      unset "PIDS[$i]"
      if [[ "$PROCESSES" -gt 1 ]]; then
        i=$((i+1))
      fi
    fi
  done
  wait
  if [[ "$ERRORS" -gt 0 ]]; then
    exit 1
  fi
}

_main "$@"
