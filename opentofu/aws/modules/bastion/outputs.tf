output "instance_id" {
  description = "Bastion EC2 instance ID"
  value       = aws_instance.bastion.id
}

output "private_ip" {
  description = "Bastion private IP — SSH after connecting VPN: ssh -i <key.pem> ec2-user@<private_ip>"
  value       = aws_instance.bastion.private_ip
}
