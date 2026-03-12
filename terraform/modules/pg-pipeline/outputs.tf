output "pipeline_name" {
  value = aws_codepipeline.this.name
}

output "pipeline_arn" {
  value = aws_codepipeline.this.arn
}

output "eventbridge_rule_arn" {
  value = aws_cloudwatch_event_rule.tag_trigger.arn
}

output "eventbridge_rule_name" {
  value = aws_cloudwatch_event_rule.tag_trigger.name
}
