# AU-G3 is opt-in only after a concrete producer/consumer contract is accepted.
variable "audit_contract" {
  description = "Accepted AU-G3 contract and existing IAM role names. Null leaves messaging disabled; no consumer is deployed."
  type = object({
    reference           = string
    producer_role_names = set(string)
    consumer_role_name  = string
    visibility_timeout  = number
    max_receive_count   = number
    alarm_actions       = list(string)
  })
  default = null
  validation {
    condition = var.audit_contract == null ? true : (
      length(trimspace(var.audit_contract.reference)) > 0 &&
      length(var.audit_contract.producer_role_names) > 0 &&
      startswith(var.audit_contract.consumer_role_name, "${var.name_prefix}-") &&
      alltrue([for role in var.audit_contract.producer_role_names : startswith(role, "${var.name_prefix}-")]) &&
      length(var.audit_contract.alarm_actions) > 0 &&
      var.audit_contract.visibility_timeout >= 1 && var.audit_contract.visibility_timeout <= 43200 &&
      var.audit_contract.max_receive_count >= 1 && var.audit_contract.max_receive_count <= 1000
    )
    error_message = "An enabled audit contract must identify DEV platform-prefixed producer and consumer roles, alarm actions, contract reference, visibility timeout, and retry limit."
  }
}

resource "aws_sqs_queue" "audit_dlq" {
  count                     = var.audit_contract == null ? 0 : 1
  name                      = "${var.name_prefix}-audit-dlq"
  sqs_managed_sse_enabled   = true
  message_retention_seconds = 1209600
}
resource "aws_sqs_queue" "audit" {
  count                      = var.audit_contract == null ? 0 : 1
  name                       = "${var.name_prefix}-audit"
  sqs_managed_sse_enabled    = true
  visibility_timeout_seconds = var.audit_contract.visibility_timeout
  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.audit_dlq[0].arn
    maxReceiveCount     = var.audit_contract.max_receive_count
  })
}
resource "aws_sqs_queue_redrive_allow_policy" "audit" {
  count     = var.audit_contract == null ? 0 : 1
  queue_url = aws_sqs_queue.audit_dlq[0].id
  redrive_allow_policy = jsonencode({
    redrivePermission = "byQueue"
    sourceQueueArns   = [aws_sqs_queue.audit[0].arn]
  })
}
resource "aws_iam_role_policy" "audit_producer" {
  for_each = var.audit_contract == null ? toset([]) : var.audit_contract.producer_role_names
  name     = "${var.name_prefix}-audit-send"
  role     = each.value
  policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Effect = "Allow", Action = ["sqs:SendMessage"], Resource = aws_sqs_queue.audit[0].arn }]
  })
}
resource "aws_iam_role_policy" "audit_consumer" {
  count = var.audit_contract == null ? 0 : 1
  name  = "${var.name_prefix}-audit-consume"
  role  = var.audit_contract.consumer_role_name
  policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Effect = "Allow", Action = ["sqs:ReceiveMessage", "sqs:DeleteMessage", "sqs:ChangeMessageVisibility", "sqs:GetQueueAttributes"], Resource = aws_sqs_queue.audit[0].arn }]
  })
}
resource "aws_cloudwatch_metric_alarm" "audit_dlq" {
  count               = var.audit_contract == null ? 0 : 1
  alarm_name          = "${var.name_prefix}-audit-dlq-visible"
  namespace           = "AWS/SQS"
  metric_name         = "ApproximateNumberOfMessagesVisible"
  dimensions          = { QueueName = aws_sqs_queue.audit_dlq[0].name }
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 1
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = var.audit_contract.alarm_actions
}
resource "aws_cloudwatch_metric_alarm" "audit_age" {
  count               = var.audit_contract == null ? 0 : 1
  alarm_name          = "${var.name_prefix}-audit-message-age"
  namespace           = "AWS/SQS"
  metric_name         = "ApproximateAgeOfOldestMessage"
  dimensions          = { QueueName = aws_sqs_queue.audit[0].name }
  statistic           = "Maximum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 300
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = var.audit_contract.alarm_actions
}
output "audit_queue_arn" {
  value = try(aws_sqs_queue.audit[0].arn, null)
}
output "audit_queue_url" {
  value = try(aws_sqs_queue.audit[0].url, null)
}

# Enforce TLS for queue access. Role identity policies remain scoped to the queue.
data "aws_iam_policy_document" "audit_tls" {
  count = var.audit_contract == null ? 0 : 1
  statement {
    sid    = "DenyInsecureTransport"
    effect = "Deny"
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    actions   = ["sqs:*"]
    resources = [aws_sqs_queue.audit[0].arn]
    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}
resource "aws_sqs_queue_policy" "audit_tls" {
  count     = var.audit_contract == null ? 0 : 1
  queue_url = aws_sqs_queue.audit[0].id
  policy    = data.aws_iam_policy_document.audit_tls[0].json
}
