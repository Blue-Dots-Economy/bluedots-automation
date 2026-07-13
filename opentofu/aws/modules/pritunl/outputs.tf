output "instance_id" {
  description = "EC2 instance ID of the Pritunl server"
  value       = aws_instance.pritunl.id
}

output "public_ip" {
  description = "Elastic IP (fixed) — use this as the VPN server address in client .ovpn profiles"
  value       = aws_eip.pritunl.public_ip
}

output "private_ip" {
  description = "Private IP of the Pritunl EC2 within the VPC"
  value       = aws_instance.pritunl.private_ip
}
