![newapp](https://github.com/user-attachments/assets/a9da3bc0-ff59-4fbf-b612-94bc69c16d0f)
The first thing if you want to deploy this architecture is "terraform init"
Step 2: terraform apply -var="source_email=you@yourdomain.com"
replace source_email with email to be able to verify
Step 3: once you have deployed you need to replace the necessary arns in the lambda functions

***You can develop this application by instead of using s3 you will run nginx in ec2
