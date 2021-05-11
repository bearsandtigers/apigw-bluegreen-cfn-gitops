#!/bin/bash
#set -x
set -e

[[ -z "${S3_BUCKET}" ]] && ( echo "Specify S3 bucket name for artifacts!"; exit 1 )

TPL_NAME='tpl.cfn.yaml'
MAIN_TPL_NAME='main.cfn.yaml'
INFRA_REPO_DIR='../../infra-repo/app'

GIT_COMMIT=`git rev-parse --verify HEAD 2>/dev/null` || GIT_COMMIT="" #echo "No Git commit detected"
GIT_COMMIT_DATE_TIME=`git show -s --format=%cI ${GIT_COMMIT} | sed -e 's/[:+]//g'`
# regarding tags: https://stackoverflow.com/questions/3404936/show-which-git-tag-you-are-on
GIT_TAG=`git describe --exact-match --tags 2>/dev/null || echo ''`
[[ -z ${GIT_TAG} ]] || GIT_TAG="${GIT_TAG}."

GIT_REF="${GIT_COMMIT_DATE_TIME}.${GIT_TAG}${GIT_COMMIT}"
echo "git ref: ${GIT_REF}"

# Use git ref as `Version` Parameter
ENVSUBST_GITREF=${GIT_REF} \
  envsubst '$ENVSUBST_GITREF' < "${TPL_NAME}" > "a.${TPL_NAME}" && cp "a.${TPL_NAME}" "b.${TPL_NAME}"

# Look through the templates for artifacts references
CODE_PATHS=`find -type f -name ${TPL_NAME} -exec egrep '^\s*Code:.*zip' {} \; | sed -e 's/Code://g'`
for CODE_PATH in `echo $CODE_PATHS`
do
  # .. and for each such reference upload the correspinding code to S3 
  # and replace in the template the local reference with a reference to s3
  echo $CODE_PATH
  ARTIFACT_NAME=`echo "${CODE_PATH}" | sed -e 's|/target/|-|g' | sed -e 's|\.\./||g'`
  S3_KEY="apigw/${GIT_REF}/${ARTIFACT_NAME}"
  S3_LOCATION="{ S3Bucket: ${S3_BUCKET}, S3Key: { \"Fn::Sub\": \"apigw/\${Version}/${ARTIFACT_NAME}\" } }"
  echo "aws s3 cp $CODE_PATH ${S3_KEY}"
  aws s3 cp ../$CODE_PATH "s3://${S3_BUCKET}/${S3_KEY}"
  find -type f -name \*\.${TPL_NAME} -exec sed -i -e "s|${CODE_PATH}|${S3_LOCATION}|g" {} \;
done

# GITOPS:
# In this step your ci\cd server has to checkout the correct branch of the infrastructure repo to a local dir `infra`

# First lets find if the corresponding directory in the infra repo already has files,
# if not, copy all the necessary files (main.cfn.yaml, both a and b templates)
if [ -z "$(ls -A ${INFRA_REPO_DIR})" ]
then
  echo "It seems to be the first commit to the infra repo, so copying all the files"
  cp "${MAIN_TPL_NAME}" "${INFRA_REPO_DIR}/"
  cp "a.${TPL_NAME}" "${INFRA_REPO_DIR}/"
  cp "b.${TPL_NAME}" "${INFRA_REPO_DIR}/"
fi

# Get the green slot (a or b) and commit the corresponding file to the infra repo.
# Surely, this step makes no sense if this is the first commit for infra and we already copied all the files.
A_SLOT_PATTERN='Default: A # LiveVersionMark'
B_SLOT_PATTERN='Default: B # LiveVersionMark'

if grep "${B_SLOT_PATTERN}" "${INFRA_REPO_DIR}/${MAIN_TPL_NAME}" 2>/dev/null
then
  echo "Current live slot is B, modifying slot A as green one"
  GREEN_SLOT='a'
  #sed -i -e "s/${B_SLOT_PATTERN}/${A_SLOT_PATTERN}/g" "$MAIN_TPL_NAME"
else
  echo "Current live slot is A, modifying slot B as green one"
  GREEN_SLOT='b'
fi
cp "${GREEN_SLOT}.${TPL_NAME}" "${INFRA_REPO_DIR}/" && \
  cd ${INFRA_REPO_DIR}/ && \
  git add "${GREEN_SLOT}.${TPL_NAME}" && \
  git commit -m "Update ${GREEN_SLOT}.${TPL_NAME}"

# How to handle JSON file with bash:
# https://stackoverflow.com/questions/52689219/find-and-replace-a-value-in-a-json-file-using-bash