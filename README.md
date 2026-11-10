# Automated CIS Compliance Enforcement with Ansible

An Ansible suite that **audits** and **remediates** CIS benchmark controls across a fleet of Ubuntu 24.04 servers, then produces a compliance report (HTML and JSON) per host per control, with optional email alerts and a nightly schedule.

- **25 controls** across 8 areas (covers all 8 brief requirements and CIS Level 1 bonus, 20+)
- **Audit mode** (`--check`) reports without changing anything
- **Remediation mode** fixes non-compliant items, and a second run reports `changed=0` (idempotent)
- **Ansible Vault** protects the only secret (the email password)

## Architecture

```
ansible-cis-compliance/
├── ansible.cfg                   # project defaults (inventory, user, key, Vault password file)
├── inventory/
│   ├── hosts.ini                 # lab inventory (real IPs, temporary)
│   ├── hosts.example.ini         # sample inventory with placeholder IPs
│   └── group_vars/
│       ├── webservers.yml        # web-only firewall ports (80, 443)
│       ├── dbservers.yml         # db-only firewall port (5432)
│       └── all/
│           ├── vars.yml          # alert settings, points to the Vault secret
│           └── vault.yml         # ENCRYPTED: email app password
├── playbooks/
│   ├── compliance.yml            # play 1: audit or fix servers; play 2: report and alert
│   └── schedule.yml              # sets a nightly audit via cron
├── roles/
│   ├── cis_ssh/                  # SSH hardening
│   ├── cis_firewall/             # UFW
│   ├── cis_users/                # empty passwords, sudo membership
│   ├── cis_file_permissions/     # critical file and key permissions
│   ├── cis_services/             # legacy remote services
│   ├── cis_updates/              # security updates
│   ├── cis_logging/              # rsyslog, journald
│   ├── cis_network/              # kernel network settings
│   ├── cis_report/               # builds HTML and JSON reports
│   └── cis_notify/               # emails the summary
├── reports/                      # sample audit and remediation reports
├── terraform/                    # lab: two EC2 servers, SSH from one IP only
└── screenshots/                  # numbered evidence
```

**How the pieces fit:** each role checks its area, fixes it if needed, and adds a result (`PASS`, `FAIL` or `FIXED`) to that server's scorecard. A second play on the control node collects every scorecard into one report and emails a summary.

**Reusable across server types:** roles hold safe defaults; `group_vars` override them per group. The firewall role is written once, yet web servers open 80 and 443 whilst database servers open 5432 (see `screenshots/11-ufw-rules-per-group.png`).

## Compliance controls

| ID | Area | Control | Required state | Brief item |
|---|---|---|---|---|
| SSH-01 | SSH | Root login disabled | `PermitRootLogin no` | 1 |
| SSH-02 | SSH | Password authentication disabled | `PasswordAuthentication no` | 1 |
| SSH-03 | SSH | Login attempts limited | `MaxAuthTries 4` | 1 |
| FW-01 | Firewall | UFW enabled | active | 2 |
| FW-02 | Firewall | Default deny incoming, enforced | deny (incoming) | 2 |
| USR-01 | Users | No accounts with empty passwords | none found | 3 |
| USR-02 | Users | Only approved users have sudo | approved list only | 3 |
| FP-01 | Files | `/etc/passwd` | 0644 root:root | 4 |
| FP-02 | Files | `/etc/shadow` | 0600 root:shadow | 4 |
| FP-03 | Files | Admin `authorized_keys` | 0600 owner only | 4 |
| FP-04 | Files | SSH host key (ed25519) | 0600 root:root | 4 |
| FP-05 | Files | SSH host key (rsa) | 0600 root:root | 4 |
| FP-06 | Files | SSH host key (ecdsa) | 0600 root:root | 4 |
| SVC-01 | Services | Telnet not installed | absent | 5 |
| SVC-02 | Services | rsh and rlogin not installed | absent | 5 |
| UPD-01 | Updates | No pending security updates | 0 pending | 6 |
| UPD-02 | Updates | Automatic security updates enabled | enabled | 6 |
| LOG-01 | Logging | rsyslog running | running | 7 |
| LOG-02 | Logging | journald stores logs on disk | `Storage=persistent` | 7 |
| NET-01 | Network | IP forwarding disabled | 0 | 8 |
| NET-02 | Network | Send redirects disabled (all) | 0 | 8 |
| NET-03 | Network | Send redirects disabled (default) | 0 | 8 |
| NET-04 | Network | ICMP redirects not accepted (all) | 0 | 8 |
| NET-05 | Network | ICMP redirects not accepted (default) | 0 | 8 |
| NET-06 | Network | IPv6 ICMP redirects not accepted | 0 | 8 |

## How audit and remediation work

Every role follows the same three steps:

1. **Audit:** read the current state with read-only tasks. Commands that only read are marked `check_mode: false` (so they still run in audit mode) and `changed_when: false` (reading is never a change).
2. **Fix:** use desired-state modules (`copy`, `file`, `ufw`, `sysctl`, `apt`). In audit mode these only report what they would change.
3. **Record:** `PASS` if already compliant; otherwise `FAIL` in audit mode or `FIXED` in remediation mode.

Rule followed throughout: `check_mode: false` is only ever used on read-only tasks, so audit mode never changes a server. The report tasks are the one exception, as they write to the control node, not the servers.

### Safety nets

- **SSH:** new settings are validated (`sshd -t`) before SSH restarts; the restart only happens if something changed (handler).
- **Firewall:** the SSH allow rule is applied before UFW is enabled, preventing lockout.
- **Users:** an `assert` stops the run if Ansible's own user is not on the approved sudo list, preventing self-lockout.

## Usage

### Prerequisites

Ansible core 2.16+, the `community.general` and `ansible.posix` collections, Terraform 1.5+, the AWS CLI with credentials, and a Linux or WSL control node.

### 1. Create the lab (optional)

```bash
ssh-keygen -t ed25519 -f ~/.ssh/ansible-cis -C "ansible-cis-lab"
cd terraform
echo "my_ip = \"$(curl -s https://checkip.amazonaws.com)\"" > terraform.tfvars
terraform init && terraform apply
```

Put the two output IPs into `inventory/hosts.ini` (copy `hosts.example.ini`).

### 2. Set up Vault

```bash
read -s -p "Vault password: " VP && echo "$VP" > ~/.ansible-cis-vault-pass && chmod 600 ~/.ansible-cis-vault-pass && unset VP
ansible-vault create inventory/group_vars/all/vault.yml
# add: vault_cis_alert_smtp_password: "your Gmail app password"
```

To run without email, set `cis_alert_enabled: false` in `inventory/group_vars/all/vars.yml`.

### 3. Run

```bash
# Audit only, no changes
ansible-playbook playbooks/compliance.yml --check --diff

# Audit and fix
ansible-playbook playbooks/compliance.yml --diff

# One area only (tags: ssh, firewall, users, files, services, updates, logging, network)
ansible-playbook playbooks/compliance.yml --tags firewall --check

# Schedule a nightly audit at 02:00
ansible-playbook playbooks/schedule.yml
```

Reports are written to `reports/compliance-report.html` and `reports/compliance-report.json`.

## Sample reports

- `reports/sample-audit-report.html` and `.json`: audit run with two planted problems (an unapproved sudo user on `web1`, IP forwarding on `db1`), both shown as `FAIL`.
- `reports/sample-remediation-report.html` and `.json`: the following run, both shown as `FIXED`.

## Security

- **Ansible Vault:** the email app password is encrypted (AES256) in `vault.yml`. The Vault password file lives outside the repo (`~/.ansible-cis-vault-pass`). Secrets use the `vault_` prefix and are referenced from plain `vars.yml`, so readers see which secrets exist without seeing them.
- **`no_log`:** the email task hides its output by default, so the password cannot leak into logs.
- **Least privilege:** Ansible logs in as a normal user and uses `sudo` only where needed; the report play runs with `become: false`; root login is disabled; the lab security group allows SSH from a single IP (`/32`).
- **Defence in depth:** UFW on each server in addition to the AWS security group.

## Evidence

| # | Screenshot | Shows |
|---|---|---|
| 01 | `01-terraform-apply.png` | Lab servers created |
| 02 | `02-ec2-running.png` | Both servers running |
| 03 | `03-ssh-manual-test.png` | Key-based SSH works |
| 04 | `04-ansible-ping.png` | Ansible reaches the fleet |
| 05 | `05-ssh-audit-check.png` | SSH audit: FAIL |
| 06 | `06-ssh-remediate.png` | SSH fixed |
| 07 | `07-ssh-idempotent-rerun.png` | Second run, `changed=0` |
| 08 | `08-firewall-audit-check.png` | Firewall audit: FAIL |
| 09 | `09-firewall-remediate.png` | Firewall fixed |
| 10 | `10-firewall-idempotent-rerun.png` | Second run, `changed=0` |
| 11 | `11-ufw-rules-per-group.png` | Different ports per server group |
| 12a/b | `12a-users-audit-web1.png`, `12b-users-audit-db1.png` | Planted intruder caught on web1 only |
| 14 | `14-intruder-removed.png` | Intruder no longer has sudo |
| 15 to 17 | `15-files-audit-check.png` to `17-files-idempotent-rerun.png` | File permissions: FAIL, FIXED, idempotent |
| 18 to 20 | `18-services-audit-check.png` to `20-services-idempotent-rerun.png` | Telnet: FAIL, FIXED, idempotent |
| 21 to 23 | `21-updates-audit-check.png` to `23-updates-idempotent-rerun.png` | Updates: FAIL, FIXED, idempotent |
| 24 to 26 | `24-logging-network-audit.png` to `26-logging-network-rerun.png` | Logging and network: FAIL, FIXED, idempotent |
| 27a/b | `27a-html-report-audit-web1.png`, `27b-html-report-audit-db1.png` | HTML audit report |
| 28 | `28-html-report-remediation.png` | HTML remediation report |
| 29 | `29-vault-encrypted.png` | Vault file is encrypted |
| 30 | `30-email-alert.png` | Email alert received |
| 31 | `31-cron-schedule.png` | Nightly audit scheduled |

## Notes and limitations

- **`/etc/shadow`:** CIS accepts 0640; this project applies the brief's stricter 0600, which suits key-only servers.
- **MaxAuthTries:** checked for exactly 4; CIS allows 4 or fewer.
- **Database port:** 5432 is open to any source on db servers; production should restrict it to the web servers only.
- **Email port:** uses SMTP over SSL on port 465, as some internet providers block 587.
- **Scheduling:** cron on a WSL laptop runs only while it is on; in production, run the schedule on an always-on control node or in AWX.

## Clean up

```bash
cd terraform && terraform destroy
```
