## Api Gateway + Lambda(s) blue/green deploy with CloudFormation (GitOps approach)

Nowhere in the Internet I was able to find a description of how to conduct blue/green deploys of a combination of AWS Api Gateway and Lambdas (such a combination is supposed to represent a separate serverless microservice in a large microservice application). The stages feature of Api GW is obviously not a choice as Api GW resources are tied to the Api GW entity itself not to stages (in that case it would have made sense).

So, this project demonstrates my view on how to perform blue/green deploys of Api GW + Lambdas using CloudFormation as IaC tool and following so called GitOps approach (which is mostly used in Kubernetes world but why not to use it here too ?).

## Prerequisites:

It's assumed that you are familiar with the CloudFormation.

Route53 is used as a mean to point out clients to Live and Green Api Gateways. So, beforehand you have to create a Route53 Hosted Zone and AWS Certificate manager certificate and put the Zone properties and the certificate arn into the SSM parameters. The `main.cfn.yaml` CloudFormation (CFN) template expects those values to be presented at the Stack creation time.

For Route53:
```
aws ssm put-parameter \
    --name "/apigw-bluegreen/HostedZoneDomainId" \
    --value <HostedZoneDomainId> \
    --type String
```

```
aws ssm put-parameter \
    --name "/apigw-bluegreen/HostedZoneDomainName" \
    --value <HostedZoneDomainName> \
    --type String
```
For certificate:
```
aws ssm put-parameter \
    --name "/apigw-bluegreen/CertificateArn" \
    --value <certificate arn> \
    --type String
```

## Directories and files:

In real life the directories `app-repo` and `infra-repo` are to be separate Git repositories (here for simplicity they are just directories within the same repository).

 - `app-repo` is supposed to store an application code in the `src` directory and CFN templates and script to prepare artifacts in the `cicd` dir.

I'm using two really dumb Lambda functions as an example application code serving no particular purpose. One of them is just inline in the CFN template and the other is a Python code packed into ZIP archive. The ZIP is provided right in the repo for convinience but it goes without saying that in real you are to have some solution that packages your code appropriately during the pipeline run.

In the `cicd` directory you can see CFN templates describing both A and B slots (see below) and `artifacts.sh` bash script which uploads the artifacts (zipped code and processes CFN templates) and performs commit to the infra repo to trigger deploy.

The `main.cfn.yaml` is the CFN template to be deployed. It integrates two CFN "nested" subStacks into one single CFN Stack for convinience. Each subStack is so called "slot", i.e. only one of them is active at a time (holding a "prod" version of the application) and another one just stands by holding a so called "green" state. Active slot is referred by a "prod" Route53 APi Gateway Custom Domain Name (created in `main.cfn.yaml`), i.e. the one that servers prod traffic. There is also additional APi Gateway Custom Domain Name that I call the "green" one which includes some obvious prefix to its URL (I use "candidate-" in this example). This Custom Domain Name is to direct to the "green" slot.

 - `infra-repo` is a GitOps repo, i.e. that stores the state of the infrastructure of the application. A some tool (CI/CD server ? In the Kubernetes world such tool might be Flux or ArgoCD) should watch the state of the repository and syncronize any changes with the actual state in the cloud. The `app` directory is to contain CFN files from `app-repo`.

## Workflow:

As already mentioned you are supposed to put each `app-repo` and `infra-repo` into a separate Git repo. For each repo you should have a separate pipeline configured in your favorite CI/CD tool, triggered by a Git repo event (a commit, a tag, a PR creation\merge, it's all up to you depending on your general Git branching and deployment strategy). I'm skipping such a configuration here and instead describing how to imitate the job of a CI/CD tool by running the corresponding scripts by hand :-).

### 1. Activity in the `app-repo` repo:

Let's suppose you are just started and have some initial state of your Lambdas and Api Gateway configuration, and empty `app` directory in the `infra-repo`. Commit the state in the `app-repo` and run `artifacts.sh` in the `cicd` directory (keep in mind, in real life your CI/CD tool is to run it!). `artifacts.sh` uploads packed Lambda code to a S3 location, updates `Code:` specifiers in the `tpl.cfn.yaml` (so they point to the S3 location instead of local files, this is something that `aws cloudformation package` can do automatically but I like to control the process by myself :-)), duplicates the latter into two equal files `a.tpl.cfn.yaml` and `b.tpl.cfn.yaml`.

The next step is that your CI/CD tool checkouts the infra-repo into some local directory. Here it's not implemented, the result of such a checkout is imitated by `infra-repo` directory.

So now starts the GitOps activity. `artifacts.sh` checks the content of the `infra-repo` dir. If it's empty it's assumed that this is the very first run and `artifacts.sh` just copies all the processed CFN templates into `infra-repo/app`.

If `infra-repo/app` is not empty, `artifacts.sh` looks into the `LiveStack` CFN parameter in the `main.cfn.yaml` to understand which Stack ("a" or "b") is Live and which is "green". Then it just copies over only a corresponding file (`a.tpl.cfn.yaml` or `b.tpl.cfn.yaml`) thus updating the configuration of a "green" Stack, adds the file to the Git staging area and commits and pushes it to the `infra-repo` (recall that the content of the `infra-repo` is result of check out of a separate Git repo!).

Here the activity in the `app-repo` repo ends.


### 2. Activity in the `infra-repo` repo:

Now the pipeline attached to the `infra-repo` Git repository notices a new commit and starts build by running `deploy.sh` (see an example in the `infra-repo/README.md`).
`deploy.sh` just takes the `main.cfn.yaml` and deploys it using set of `aws` cli commands (and a pinch of bash spaghetti code :-) ).
If it's the first deploy then a two identical copies of Api Gateway and Lambdas are deployed as slots (aka CFN Stacks) A and B.

But if it's not we know that `artifacts.sh` has updated only one of the `a.tpl.cfn.yaml` or `b.tpl.cfn.yaml` (which one was detected as a "green" one) and thus only the green slot is being modified by deploy leaving the active one (i.e. the "prod") untouched. So, now you have two versions of your application running. Here you can run some tests against the "green" slot and if everything is OK then just modify the `LiveStack` CFN parameter in the `main.cfn.yaml` and commit (this action is to be performed by some person in charge of releasing a new version into "prod"). In this commit both Stacks are not modified but `main.cfn.yaml` now swaps the "live" (or "prod") Api Gateway Custom Domain Name and the "green" one so the first one now directs traffic to the "green" slot which thus becomes the new "active". And the former "active" slot is still around just for case you will want to rollback.
