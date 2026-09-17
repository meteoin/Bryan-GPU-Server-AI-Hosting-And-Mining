# SSH Key-Only Access

Run this from the **admin laptop**, over VPN, while the host still accepts a password. Use a **unique `--alias` per host**.

```bash
./scripts/setup_ssh_key_access.sh flyanb@192.168.1.174 --alias rigv3 --disable-password
./scripts/setup_ssh_key_access.sh flyanb@192.168.1.81  --alias rigv4 --disable-password
```

Each command creates `~/.ssh/id_ed25519_<alias>` if needed, installs that public key, proves key login, writes a `Host <alias>` SSH config block, then prompts for the **host sudo password** and disables password SSH with `00-key-only.conf`. It fails if `sshd` still offers password after reload.

Do not reuse `--alias` across IPs. `rigv3` is `192.168.1.174`; `rigv4` is `192.168.1.81`.

If the dedicated key already exists, rerun the same command. Key install is skipped; sudo disable still runs.

## What goes where

| Item | Where it lives |
|---|---|
| Private key (`id_ed25519_rigv3`) | admin laptop only |
| Public key (`id_ed25519_rigv3.pub`) | host `~/.ssh/authorized_keys` |
| Host fingerprint (`SHA256:...`) | laptop known_hosts; **not** pasted onto the server |

Never copy the private key to the GPU host.

## 1. Create a dedicated key on the laptop

Use a per-host key with an empty passphrase so `ssh-agent` is not required:

```bash
ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519_rigv3 -C 'eqan-mac-rigv3' -N ''
cat ~/.ssh/id_ed25519_rigv3.pub
```

Do not reuse `~/.ssh/id_ed25519` if you do not know that key's passphrase. `ssh` and `ssh-copy-id` will keep asking for it.

## 2. Install the public key on the host

From the laptop, force password login so the old default key is ignored:

```bash
ssh-copy-id -i ~/.ssh/id_ed25519_rigv3.pub \
  -o IdentitiesOnly=yes \
  -o PreferredAuthentications=password \
  -o PubkeyAuthentication=no \
  flyanb@192.168.1.174
```

Type the **host account password** (`flyanb`), not a key passphrase.

If `ssh-copy-id` still tries `~/.ssh/id_ed25519`:

```bash
mv ~/.ssh/id_ed25519 ~/.ssh/id_ed25519.disabled
mv ~/.ssh/id_ed25519.pub ~/.ssh/id_ed25519.pub.disabled
ssh-copy-id -i ~/.ssh/id_ed25519_rigv3.pub flyanb@192.168.1.174
mv ~/.ssh/id_ed25519.disabled ~/.ssh/id_ed25519
mv ~/.ssh/id_ed25519.pub.disabled ~/.ssh/id_ed25519.pub
```

Success looks like: `Number of key(s) added: 1`.

## 3. Prove key login from a new laptop terminal

Do not test by SSHing from the GPU host to itself. That uses the server's keys, not the laptop key.

```bash
ssh -i ~/.ssh/id_ed25519_rigv3 \
  -o IdentitiesOnly=yes \
  -o PreferredAuthentications=publickey \
  -o PasswordAuthentication=no \
  flyanb@192.168.1.174
```

Pass:

- you get a shell
- no `password:` prompt

Fail:

- `Permission denied (publickey)` — public key is missing or truncated on the host
- `Enter passphrase for key '.../id_ed25519'` — SSH is still using the old default key
- `flyanb@... password:` — it fell back to password; keys are not in use yet

A password login that succeeds is **not** proof that keys work.

## 4. Optional laptop SSH config

```text
Host rigv3
  HostName 192.168.1.174
  User flyanb
  IdentityFile ~/.ssh/id_ed25519_rigv3
  IdentitiesOnly yes
```

Then `ssh rigv3`.

## 5. Disable password SSH

Keep a working key session open. OpenSSH uses the **first** `PasswordAuthentication` value it reads. Ubuntu often sets `yes` in `50-cloud-init.conf` before a `99-` drop-in, so a later `no` is ignored.

On the host:

```bash
sudo tee /etc/ssh/sshd_config.d/00-key-only.conf >/dev/null <<'EOF'
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
PermitRootLogin no
EOF
sudo rm -f /etc/ssh/sshd_config.d/99-key-only.conf
sudo sed -ri 's/^[[:space:]]*#?[[:space:]]*PasswordAuthentication[[:space:]]+.*/PasswordAuthentication no/' /etc/ssh/sshd_config
if [ -f /etc/ssh/sshd_config.d/50-cloud-init.conf ]; then
  sudo sed -ri 's/^[[:space:]]*#?[[:space:]]*PasswordAuthentication[[:space:]]+.*/PasswordAuthentication no/' /etc/ssh/sshd_config.d/50-cloud-init.conf
fi

sudo sshd -t
sudo systemctl reload ssh
```

From a **second** laptop terminal:

```bash
ssh -i ~/.ssh/id_ed25519_rigv3 -o IdentitiesOnly=yes flyanb@192.168.1.174
```

Must still work. Then confirm passwords are rejected:

```bash
ssh -o PreferredAuthentications=password -o PubkeyAuthentication=no flyanb@192.168.1.174
```

That should print `Permission denied`.

If `sshd -T` still shows `passwordauthentication yes`, an earlier drop-in won:

```bash
sudo grep -R PasswordAuthentication /etc/ssh/sshd_config /etc/ssh/sshd_config.d/
sudo sshd -T | grep -E 'passwordauthentication|kbdinteractiveauthentication|pubkeyauthentication'
```

## Pitfalls seen on rigv3

- Running `ssh flyanb@192.168.1.174` **from** `rigv3` tests the server talking to itself.
- Pasting the host fingerprint into `authorized_keys` does nothing useful.
- `ssh-copy-id` without extra options used the default `id_ed25519` and asked for its forgotten passphrase.
- Key login was not working until `ssh-copy-id` reported `Number of key(s) added: 1` and the `PasswordAuthentication=no` test succeeded.
- A `99-key-only.conf` drop-in did not disable passwords: OpenSSH keeps the first `PasswordAuthentication` value, and Ubuntu's `50-cloud-init.conf` often sets `yes` first. Use `00-key-only.conf`.
- Reusing `--alias rigv3` on `192.168.1.81` writes `Host rigv3` to the wrong IP. Each host needs its own alias.
- `ssh -t` with a stdin heredoc cannot prompt for sudo. The script uploads a temp file, then runs `sudo bash` with the laptop TTY.

## Afterward

Stay on the UniFi WireGuard VPN for admin SSH. Do not forward host port 22 from WAN.
