#!/bin/bash
set -e

# Print ChangeSet in the format similar to Terraforms's or Azure's 'what-if'
prettyprint() {
  echo "$1" |
  jq -r '
    .Changes |
    to_entries |
    .[] |
    (.key|tostring) as $i |
    .value.ResourceChange |
    .LogicalResourceId as $log_id |
    (.PhysicalResourceId // "(n/a)") as $phy_id | 
    .Details as $d |
    (.ResourceType|sub("AWS::"; ""; "g")) as $res_type |
    (.Action|sub("Add";"+++";"g")|sub("Modify";"~~~";"g")|sub("Remove";"---";"g")) as $act_mark |
    (.Replacement // "(n/a)"|sub("True";"!!!REPLACE!!!";"g")|sub("False";"";"g")|sub("Conditional";"?replace?";"g")) as $replace_mark |
    [ 
      ( "\n№ " + $i + "\t" + $act_mark + "\t" + $replace_mark + "\t" + $log_id + "(" + $res_type + ")" + "\t" + "--> " + "\t" + $phy_id ),
      (
        .Details[] |
        .Evaluation as $eval |
        (.Target.RequiresRecreation|sub("Always";"causes RECREATE";"g")|sub("Never";"(in-place)";"g")|sub("Conditionally";"?recreate?";"g")) as $recreate_mark |
        .Target.Attribute as $attr |
        .Target.Name as $name |
        (($attr + "/" + $name)|sub("/$"; "")) as $key | 
        .ChangeSource as $source |
        (.CausingEntity // "n/a") as $cause |
        ("\n\t" + $recreate_mark + "\t\"" + $key + "\" affected by\t" + $eval + " " + $source + " (" + $cause + ")")
      )
    ] |
    join("")
    '
}

# From https://github.com/aws/aws-cli/issues/2887
# Bash function to watch CFN Stack progress
cloudformation_tail() {
  local stack="$1"
  local lastEvent
  local lastEventId
  local stackStatus=$(${AWSCF} describe-stacks --stack-name $stack | jq -c -r .Stacks[0].StackStatus)

  until \
	[ "$stackStatus" = "CREATE_COMPLETE" ] \
	|| [ "$stackStatus" = "CREATE_FAILED" ] \
	|| [ "$stackStatus" = "DELETE_COMPLETE" ] \
	|| [ "$stackStatus" = "DELETE_FAILED" ] \
	|| [ "$stackStatus" = "ROLLBACK_COMPLETE" ] \
	|| [ "$stackStatus" = "ROLLBACK_FAILED" ] \
	|| [ "$stackStatus" = "UPDATE_COMPLETE" ] \
	|| [ "$stackStatus" = "UPDATE_ROLLBACK_COMPLETE" ] \
	|| [ "$stackStatus" = "UPDATE_ROLLBACK_FAILED" ]
  do
    #[[ $stackStatus == *""* ]] || [[ $stackStatus == *"CREATE_FAILED"* ]] || [[ $stackStatus == *"COMPLETE"* ]]; do
    lastEvent=$(${AWSCF} describe-stack-events --stack $stack --query 'StackEvents[].{ EventId: EventId, LogicalResourceId:LogicalResourceId, ResourceType:ResourceType, ResourceStatus:ResourceStatus, Timestamp: Timestamp }' --max-items 1 | jq .[0])
    eventId=$(echo "$lastEvent" | jq -r .EventId)
    if [ "$eventId" != "$lastEventId" ]
    then
      lastEventId=$eventId
      echo $(echo $lastEvent | jq -r '.Timestamp + "\t-\t" + .ResourceType + "\t-\t" + .LogicalResourceId + "\t-\t" + .ResourceStatus')
    fi
    sleep 1
    stackStatus=$(${AWSCF} describe-stacks --stack-name $stack | jq -c -r .Stacks[0].StackStatus)
  done
  echo "Stack Status: $stackStatus"
}
# End Bash function to watch CFN Stack progress

GIT_COMMIT=`git rev-parse --verify HEAD 2>/dev/null` || GIT_COMMIT="" #echo "No Git commit detected"
GIT_BRANCH=`git rev-parse --abbrev-ref HEAD 2>/dev/null | cut -f2 -d '/'` || GIT_BRANCH="" #echo "No Git branch detected" 

[[ ! -z "$BASH_VERBOSE" ]] && set -x
# Realize Stack name
# TO DO: sanitaze fancy Git branch names (leave only letters, nums, hypens, underscores) 
[[ -z "$STACK_NAME_BASE" ]] && STACK_NAME_BASE="${GIT_BRANCH}"

[[ -z "$AWS_REGION" ]] && AWS_REGION='us-east-1'

[[ -z "$TEMPLATES" ]] && TEMPLATES='core.main.cfn.yaml app.main.cfn.yaml'
PACKAGED_TEMPLATE_SUFFIX='packaged.main.cfn.yaml'

[[ -z "$S3_BUCKET" ]] && exit 1

# Specify CFN parameters
[[ ! -z "$PARAMETERS" ]] && PARAMETERS="  --parameters `jq '.' -c ${PARAMETERS}` "

[[ ! -z "$AWS_PROFILE" ]] && AWS_PROFILE_NAME=" --profile $AWS_PROFILE_NAME "
AWSCF="aws cloudformation --region ${AWS_REGION} ${AWS_PROFILE_NAME} "

# Deploy\update Stack and watch the progress
deploy_stack() {
  # TO DO: do fail if Stack update not successful !
  echo "\n\tProcessing $1"
  TEMPLATE="$1"
  # take Stack name suffix from template's name
  STACK_NAME_SUFFIX=`echo $TEMPLATE | cut -f1 -d'.'`
  STACK_NAME="${STACK_NAME_BASE}-${STACK_NAME_SUFFIX}"
  PACKAGED_TEMPLATE="_${STACK_NAME_SUFFIX}.${PACKAGED_TEMPLATE_SUFFIX}"
  echo "AWS $AWS_PROFILE_NAME, Stack '${STACK_NAME}', located in ${AWS_REGION}, uploaded to ${S3_BUCKET}, template is $TEMPLATE"
  $AWSCF package \
    --template-file ./"${TEMPLATE}" \
    --s3-bucket "${S3_BUCKET}" \
    --s3-prefix ${STACK_NAME} \
    --output-template-file "${PACKAGED_TEMPLATE}"

  STACK_METADATA="Git branch '${GIT_BRANCH}', commit '${GIT_COMMIT}'"
  sed -i -e "s/%STACK_METADATA%/${STACK_METADATA}/g" "${PACKAGED_TEMPLATE}"

  # Check if the Stack exists to correctly set CHANGE_SET_TYPE
  CHANGE_SET_TYPE=''
  if $AWSCF describe-stacks --stack-name ${STACK_NAME} >/dev/null
  then
    CHANGE_SET_TYPE=UPDATE
  else
    CHANGE_SET_TYPE=CREATE
  fi

  echo "Creating ChangeSet..."
  cs_start=`date +%s`
  $AWSCF create-change-set \
    --change-set-name "${STACK_NAME}-ChangeSet" \
    --stack-name "${STACK_NAME}" \
    --template-body file://"${PACKAGED_TEMPLATE}" \
    --output text \
    --capabilities CAPABILITY_NAMED_IAM CAPABILITY_AUTO_EXPAND CAPABILITY_IAM \
    --change-set-type $CHANGE_SET_TYPE \
    --include-nested-stacks \
    $PARAMETERS

  echo "Waiting for the ChangeSet to complete create..."
  $AWSCF wait change-set-create-complete  \
    --stack-name "${STACK_NAME}" \
    --change-set-name "${STACK_NAME}-ChangeSet"

  cs_end=`date +%s`
  cs_duration=$((cs_end-cs_start))
  echo "ChangeSet created in ${cs_duration} seconds"

  echo "Describing the ChangeSet"
    CS=`$AWSCF describe-change-set \
      --stack-name "${STACK_NAME}" \
      --change-set-name "${STACK_NAME}-ChangeSet"`
    prettyprint "$CS"

  NESTED_CHANGESETS=`$AWSCF describe-change-set \
    --stack-name "${STACK_NAME}" \
    --change-set-name "${STACK_NAME}-ChangeSet" |
    jq '.Changes[].ResourceChange | select( .ResourceType == "AWS::CloudFormation::Stack" ) | .LogicalResourceId + "," + .ChangeSetId' | 
    tr -d '"'`

  for LOGICAL_NAME__CHANGESET_ARN__COMMA_SEPARATED in $NESTED_CHANGESETS
  do
    LOGICAL_NAME=${LOGICAL_NAME__CHANGESET_ARN__COMMA_SEPARATED%%,*}
    CHANGESET_ARN=${LOGICAL_NAME__CHANGESET_ARN__COMMA_SEPARATED#*,}
    echo "ChangeSet for nested Stack ${LOGICAL_NAME}:"
    CS=""
    [[ -z "$CHANGESET_ARN" ]] || CS=`$AWSCF describe-change-set --change-set-name "${CHANGESET_ARN}"`
    prettyprint "$CS"
  done

  CHANGESET_ARN=`$AWSCF describe-change-set \
    --stack-name "${STACK_NAME}" \
    --change-set-name "${STACK_NAME}-ChangeSet" \
    --query \
    '{ChangeSetId:ChangeSetId}' \
    --output text`

  STACK_ARN=`$AWSCF describe-change-set \
    --stack-name "${STACK_NAME}" \
    --change-set-name "${STACK_NAME}-ChangeSet" \
    --query \
    '{StackId:StackId}' \
    --output text`

  CHANGESET_LINK="https://console.aws.amazon.com/cloudformation/home?region=${AWS_REGION}#/stacks/changesets/changes?stackId=${STACK_ARN}&changeSetId=${CHANGESET_ARN}"

  printf " # # # # # Check the ChangeSet: ${CHANGESET_LINK} # # # # # \n"

  echo "Executing the ChangeSet"
  cs_start=`date +%s`
  $AWSCF execute-change-set \
    --stack-name "${STACK_NAME}" \
    --change-set-name "${STACK_NAME}-ChangeSet"

  cloudformation_tail $STACK_NAME

  cs_end=`date +%s`
  cs_duration=$((cs_end-cs_start))
  echo "ChangeSet executed in ${cs_duration} seconds"

}

for TEMPLATE in $TEMPLATES
do
  deploy_stack $TEMPLATE
done


