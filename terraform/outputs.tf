output "public_ips" {
  value = { for name, inst in aws_instance.node : name => inst.public_ip }
}
