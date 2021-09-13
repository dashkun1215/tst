#!/usr/bin/env bash

#############################################################
#             SWITCH TO/FROM MAINTENANCE MODE
#     This script updates DNS records in order to route
#	  requests to maintenance service (if -m (mode) option)
#     is on or to the application (if -m (mode) option)
#     is off.
##############################################################


# Map that maps hosted zone name to hosted zone id
declare -A HOSTED_ZONES_MAP

# Array of ids that represents resource records change set ids
RECORD_CHANGE_IDS=()

# reflects the current mode state (on/off): it can be changed by the appropriate script
# (-m option) argument or by the script itself when the rollback occurs
MODE=""

# used as a suffix in maintenance loadbalancer name (could be specified as dev, qa, stage, prod)
ACCOUNT_TYPE=""

# the name of the load balancer
ELB_NAME=""

CURRENT_DIR=$(pwd)
OUTPUT_FOLDER=${CURRENT_DIR}/target
S3_BACKUP_FOLDER=backup/route53/records
OUTPUT_BACKUP_FOLDER=${OUTPUT_FOLDER}/backup
OUTPUT_BACKUP_RECORDS_FOLDER=${OUTPUT_BACKUP_FOLDER}/record-set
OUTPUT_CHANGE_SET_REQUEST_FOLDER=${OUTPUT_FOLDER}/change-set
S3_BUCKET_NAME=""
FILTER_BY_RECORD_NAMES_FOLDER=${CURRENT_DIR}/resources/hostedzone-records
CHANGE_SET_IDS_FILE=${OUTPUT_CHANGE_SET_REQUEST_FOLDER}/change-set-ids
PROFILE_FLAG=""
PROFILE=""
AWS_REGION_FLAG=""
AWS_REGION=""

rm -rf $OUTPUT_FOLDER

function showHelp() {
  echo
  echo "usage: $0 [options]"
  echo "Options:"
  echo "  -m Mode: on|off"
  echo "  -a Account type: dev|stage|prod|test"
  echo "  -r AWS_REGION"
  echo "  -h This help"
  exit 1
}

if [[ $# -gt 0 && $# -ne 8 ]]; then
  echo $#
  echo "All (4) arguments should be specified"
  showHelp
fi

while getopts "m:a:p:r:h" opt; do
  case $opt in
  m) MODE=${OPTARG} ;;
  a) ACCOUNT_TYPE=${OPTARG} ;;
  p)
    PROFILE_FLAG=true
    PROFILE=${OPTARG}
    ;;
  r)
    AWS_REGION_FLAG=true
    AWS_REGION=${OPTARG}
    ;;
  h) showHelp ;;
  \?)
    echo "ERROR: Unknown option: -$OPTARG"
    showHelp
    ;;
  :)
    echo "ERROR: Missing option argument for -$OPTARG"
    showHelp
    ;;
  *)
    echo "ERROR: Invalid option: -$OPTARG"
    showHelp
    ;;
  esac
done

if ${PROFILE_FLAG}; then
  export AWS_PROFILE="${PROFILE}"
  echo -e "Using AWS_PROFILE - ${AWS_PROFILE}\n"
elif ! ${SILENT_MODE}; then
  echo "[ERROR] You didn't set AWS_PROFILE parameter '-p'"
  usage
fi
if ! ${ACCOUNT_TYPE_FLAG}; then
  log_error "The account type must be provided"
fi

if ! ${AWS_REGION_FLAG}; then
  log_error "The region must be provided"
fi

AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query 'Account' --output text)

function setVars() {
  S3_BUCKET_NAME=knovio-devops-$AWS_REGION-$ACCOUNT_TYPE-$AWS_ACCOUNT_ID
  ELB_NAME="elb-knovio-maintenance-$ACCOUNT_TYPE"
  if [ "${MODE}" != "on" ] &&  [ "${MODE}" != "off" ]; then
    echo "-m argument should be \"on\" or \"off\""
    exit 1
  fi

  if [ "${ACCOUNT_TYPE}" = "test" ]; then
    URL="https://dev2.knowledgevision.com"
    response=$(curl -s -w "%{http_code}" $URL)
    http_code=$(tail -n1 <<< "$response")
    if [ "${http_code}" != "503" ]; then
    S3_BUCKET_NAME=knovio-devops-$AWS_REGION-dev-$AWS_ACCOUNT_ID
    HOSTED_ZONES_MAP+=([dev2.knowledgevision.com]=Z359KD5QMQ9RUW)
    ELB_NAME="elb-knovio-maintenance-dev"
    else
      echo "Maintenance is already running"
      exit 1



  else
    HOSTED_ZONES_MAP+=([knowledgevision.com]=ZLLQ99KLK5KSE)
    HOSTED_ZONES_MAP+=([kvcentral.com]=Z25H6SN9C8JR5G)
    case $ACCOUNT_TYPE in
    dev)
      HOSTED_ZONES_MAP+=([dev-videoshowcase.net]=Z3MLEWMIUXZTQB)
      ;;
    stage)
      HOSTED_ZONES_MAP+=([stage-videoshowcase.net]=Z1F79KEKAHQN1U)
      ;;
    prod)
      HOSTED_ZONES_MAP+=([videoshowcase.net]=Z1IOEBUAPWIVFX)
      ;;

    *)
      echo "-a Account type should be dev|stage|prod"
      exit 1
      ;;
    esac
  fi

}

exit_on_error() {
  exit_code=$1
  last_command=${@:2}
  if [ $exit_code -ne 0 ]; then
    echo >&2 "\"${last_command}\" command failed with exit code ${exit_code}."
    exit $exit_code
  fi
}
#set -o history -o histexpand

setVars

mkdir -p $OUTPUT_BACKUP_RECORDS_FOLDER
mkdir -p $OUTPUT_CHANGE_SET_REQUEST_FOLDER


DNSName="dualstack.$(aws elbv2 describe-load-balancers  --names $ELB_NAME --query LoadBalancers[*].DNSName --output text)"
CanonicalHostedZoneId=$(aws elbv2 describe-load-balancers  --names $ELB_NAME --query LoadBalancers[*].CanonicalHostedZoneId --output text)

if [ $? -ne 0 ]; then
  echo -e "Error: load balancer with the given name ${ELB_NAME} wasn't found"
  exit 1
fi

for hosted_zone_name in "${!HOSTED_ZONES_MAP[@]}"
  do

    echo "hosted zone name " $hosted_zone_name
    hosted_zone_id=${HOSTED_ZONES_MAP[$hosted_zone_name]}
    records_file_name=$hosted_zone_id.json
    hosted_zone_records_path=$OUTPUT_BACKUP_RECORDS_FOLDER/$records_file_name
    if [ "${MODE}" = "on" ]; then
      aws route53 list-resource-record-sets  --hosted-zone-id "$hosted_zone_id" > $hosted_zone_records_path
      echo "putting recordSet into s3 bucket ${S3_BUCKET_NAME} in ${S3_BACKUP_FOLDER}/${records_file_name} file to backup data"
      aws s3api put-object  --bucket ${S3_BUCKET_NAME} --key ${S3_BACKUP_FOLDER}/${records_file_name} --body $hosted_zone_records_path
    elif [ "${MODE}" = "off" ]; then
      aws s3 cp "s3://${S3_BUCKET_NAME}/${S3_BACKUP_FOLDER}/${records_file_name}" $hosted_zone_records_path
    fi
    exit_on_error $?
    chmod +rwx generate-change-set-request.py

    change_set_request_path=${OUTPUT_CHANGE_SET_REQUEST_FOLDER}/${hosted_zone_id}.json
    filter_by_record_names_file=$FILTER_BY_RECORD_NAMES_FOLDER/${ACCOUNT_TYPE}-${hosted_zone_id}.json
    python3 generate-change-set-request.py -lDNS $DNSName -lHZID $CanonicalHostedZoneId \
      -i $hosted_zone_records_path -o $change_set_request_path -m $MODE -f $filter_by_record_names_file -d
    exit_on_error $?

    echo "updating route53 records with a change resource record set"
    update_result_id=$(aws route53 change-resource-record-sets  --hosted-zone-id $hosted_zone_id \
      --change-batch file://$change_set_request_path | grep -oP '"Id": "\K.*(?=\")')
    exit_on_error $?

    RECORD_CHANGE_IDS+=("$update_result_id")
    echo $update_result_id >> $CHANGE_SET_IDS_FILE
    echo "Request for updating records is executing..."
  done


chmod +rx check-status.sh

./check-status.sh -i $CHANGE_SET_IDS_FILE -a $ACCOUNT_TYPE

