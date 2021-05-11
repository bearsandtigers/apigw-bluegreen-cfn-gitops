### Example of deployment command:

```S3_BUCKET=<buckiet name>  AWS_PROFILE=<aws profile> STACK_NAME_BASE=apigw-bluegreen-cfn TEMPLATES=main.cfn.yaml ./deploy.sh```

Basically, `deploy.sh` is similar to AWS's `sam` cli tool but at the moment `sam` tool doesnt allow creating ChangeSet in one run and then executing it in another one. `aws` cli tool does.