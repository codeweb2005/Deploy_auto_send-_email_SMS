// main.tf: Terraform triển khai kiến trúc S3 → API Gateway → Lambda → Step Functions → SMS/SES

terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
  }
  required_version = ">= 1.3.0"
}

provider "aws" {
  region = var.region
}

// ========== VARIABLES ===========
variable "region" {
  type    = string
  default = "ap-southeast-1"
}
variable "lambda_memory" {
  type    = number
  default = 128
}
variable "lambda_timeout" {
  type    = number
  default = 10
}
variable "source_email" {
  type        = string
  description = "Email đã verify trong SES"
}

// ========== S3 HOSTING ===========
resource "random_id" "bucket_suffix" {
  byte_length = 4
}

resource "aws_s3_bucket" "static_site" {
  bucket = "my-static-site-bucket-${random_id.bucket_suffix.hex}"

  website {
    index_document = "index.html"
    error_document = "error.html"
  }

  cors_rule {
    allowed_origins = ["*"]
    allowed_methods = ["GET"]
    allowed_headers = ["*"]
  }
}

// Thiết lập public access block (cho phép public website)
resource "aws_s3_bucket_public_access_block" "static_block" {
  bucket = aws_s3_bucket.static_site.id

  block_public_acls       = false
  block_public_policy     = false
  ignore_public_acls      = false
  restrict_public_buckets = false
}

// Ownership controls: enforce bucket owner
resource "aws_s3_bucket_ownership_controls" "static_ownership" {
  bucket = aws_s3_bucket.static_site.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}
resource "aws_s3_bucket_object" "upload_file" {
  bucket = aws_s3_bucket.static_site.id
  key    = "index.html"     # đường dẫn bên trong bucket
  source = "./uploads/index.html"  # file cục bộ
  acl    = "private"
}
// ========== IAM ROLES ===========
// Common assume-role for Lambda functions
data "aws_iam_policy_document" "lambda_assume" {
  statement {
    effect = "Allow"
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
    actions = ["sts:AssumeRole"]
  }
}

// Role & policy for starting Step Functions
data "aws_iam_policy_document" "lambda_sfn" {
  statement {
    actions   = ["states:StartExecution"]
    resources = [aws_sfn_state_machine.notify.arn]
  }
}
resource "aws_iam_role" "lambda_sfn_role" {
  name               = "lambda_sfn_role"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
}
resource "aws_iam_policy" "lambda_sfn_policy" {
  name   = "lambda_sfn_policy"
  policy = data.aws_iam_policy_document.lambda_sfn.json
}
resource "aws_iam_role_policy_attachment" "attach_sfn" {
  role       = aws_iam_role.lambda_sfn_role.name
  policy_arn = aws_iam_policy.lambda_sfn_policy.arn
}

// Role & policy for SMS Lambda
data "aws_iam_policy_document" "lambda_sms" {
  statement {
    actions   = ["sns:Publish"]
    resources = ["*"]
  }
}
resource "aws_iam_role" "lambda_sms_role" {
  name               = "lambda_sms_role"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
}
resource "aws_iam_policy" "lambda_sms_policy" {
  name   = "lambda_sms_policy"
  policy = data.aws_iam_policy_document.lambda_sms.json
}
resource "aws_iam_role_policy_attachment" "attach_sms" {
  role       = aws_iam_role.lambda_sms_role.name
  policy_arn = aws_iam_policy.lambda_sms_policy.arn
}

// Role & policy for Email Lambda
data "aws_iam_policy_document" "lambda_email" {
  statement {
    actions   = ["ses:SendEmail", "ses:SendRawEmail"]
    resources = ["*"]
  }
}
resource "aws_iam_role" "lambda_email_role" {
  name               = "lambda_email_role"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
}
resource "aws_iam_policy" "lambda_email_policy" {
  name   = "lambda_email_policy"
  policy = data.aws_iam_policy_document.lambda_email.json
}
resource "aws_iam_role_policy_attachment" "attach_email" {
  role       = aws_iam_role.lambda_email_role.name
  policy_arn = aws_iam_policy.lambda_email_policy.arn
}

// ========== LAMBDA FUNCTIONS ===========
resource "aws_lambda_function" "rest_api" {
  filename         = "build/restApiHandler.zip"
  function_name    = "restApiHandler"
  handler          = "restApiHandler.handler"
  runtime          = "python3.10"
  memory_size      = var.lambda_memory
  timeout          = var.lambda_timeout
  role             = aws_iam_role.lambda_sfn_role.arn
  source_code_hash = filebase64sha256("build/restApiHandler.zip")

  environment {
    variables = {
      STATE_MACHINE_ARN = aws_sfn_state_machine.notify.arn
    }
  }
}
resource "aws_lambda_function" "sms" {
  filename         = "build/sms.zip"
  function_name    = "smsHandler"
  handler          = "smsHandler.handler"
  runtime          = "python3.10"
  memory_size      = var.lambda_memory
  timeout          = var.lambda_timeout
  role             = aws_iam_role.lambda_sms_role.arn
  source_code_hash = filebase64sha256("build/sms.zip")
}
resource "aws_lambda_function" "email" {
  filename         = "build/email.zip"
  function_name    = "emailHandler"
  handler          = "emailHandler.handler"
  runtime          = "python3.10"
  memory_size      = var.lambda_memory
  timeout          = var.lambda_timeout
  role             = aws_iam_role.lambda_email_role.arn
  source_code_hash = filebase64sha256("build/email.zip")
}

// ========== API GATEWAY ===========
resource "aws_api_gateway_rest_api" "api" {
  name        = "NotifyAPI"
  description = "API cho việc gọi Step Functions"
}
resource "aws_api_gateway_resource" "notify" {
  rest_api_id = aws_api_gateway_rest_api.api.id
  parent_id   = aws_api_gateway_rest_api.api.root_resource_id
  path_part   = "notify"
}
resource "aws_api_gateway_method" "post_notify" {
  rest_api_id      = aws_api_gateway_rest_api.api.id
  resource_id      = aws_api_gateway_resource.notify.id
  http_method      = "POST"
  authorization    = "NONE"
  api_key_required = false
}
resource "aws_api_gateway_integration" "lambda_notify" {
  rest_api_id             = aws_api_gateway_rest_api.api.id
  resource_id             = aws_api_gateway_resource.notify.id
  http_method             = aws_api_gateway_method.post_notify.http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = aws_lambda_function.rest_api.invoke_arn
}
resource "aws_lambda_permission" "apigw_lambda" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.rest_api.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_api_gateway_rest_api.api.execution_arn}/*/*"
}
resource "aws_api_gateway_deployment" "deploy" {
  depends_on = [aws_api_gateway_integration.lambda_notify]
  rest_api_id = aws_api_gateway_rest_api.api.id
  stage_name  = "prod"
}

// Manual output vì invoke_url deprecated
output "api_invoke_url" {
  value = "https://${aws_api_gateway_rest_api.api.id}.execute-api.${var.region}.amazonaws.com/${aws_api_gateway_deployment.deploy.stage_name}/notify"
}

// ========== STEP FUNCTIONS ===========
resource "aws_sfn_state_machine" "notify" {
  name     = "NotifyStateMachine"
  role_arn = aws_iam_role.lambda_sfn_role.arn

  definition = jsonencode({
    Comment   = "Parallel SMS & Email",
    StartAt   = "ParallelNotify",
    States    = {
      ParallelNotify = {
        Type     = "Parallel",
        Branches = [
          {
            StartAt = "SendSMS",
            States  = { SendSMS = { Type = "Task", Resource = aws_lambda_function.sms.arn, End = true } }
          },
          {
            StartAt = "SendEmail",
            States  = { SendEmail = { Type = "Task", Resource = aws_lambda_function.email.arn, End = true } }
          }
        ],
        End = true
      }
    }
  })
}

// ========== SES EMAIL IDENTITY ===========
resource "aws_ses_email_identity" "from" {
  email = var.source_email
}

// ========== OUTPUT S3 WEBSITE ===========
output "s3_website_url" {
  value = aws_s3_bucket.static_site.website_endpoint
}
