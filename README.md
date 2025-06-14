# VWdump

A Docker-based backup solution for [Vaultwarden](https://github.com/dani-garcia/vaultwarden) with encryption and Telegram integration.

> Support only **sqlite3** database backend

## ✨ Key Features

- **Automated Backups**: Configurable backup schedule using cron.
- **SQLite Safety**: Creates proper SQLite backups using `.backup` command.
- **Encryption**: AES256 encryption with configurable PBKDF2 key derivation (defaults to **600,000** iterations).
- **Compression**: Uses XZ compression for all backups, resulting in smaller file sizes.
- **Telegram Integration**: Get detailed notifications. Encrypted backups are uploaded automatically (configurable) if under 50MB.
- **Reliable Networking**: Automatic retries and timeouts for all Telegram communications ensure messages and files get through on unstable networks.
- **Automated Cleanup**: Configurable retention policy to automatically delete old local backups.

## 🗄️ What Gets Backed Up

- `db.sqlite3` - Main SQLite database
- `rsa_key*` - RSA key files are used to sign authentication tokens
- `config.json` - Stores admin page config; only exists if the admin page has been enabled before.
- `attachments/` - Attachment store
- `sends/` - Send attachment store

## 🚀 Setup

### 1. Create a Telegram Bot (Optional)

1.  Message `@BotFather` on Telegram.
2.  Send `/newbot` and follow the instructions to get your **bot token**.
3.  Add the bot to your target chat or group.
4.  Get your **chat ID** by messaging `@userinfobot`.

### 2. Docker Compose Setup

```yaml
services:
  vaultwarden-backup:
    build: .
    container_name: vaultwarden-backup
    restart: unless-stopped
    environment:
      # Basic Config
      - CRON_TIME=0 2 * * * # Daily at 2 AM
      - DELETE_AFTER=30 # Keep 30 days of local backups
      - UID=1000 # Set to the owner of your vaultwarden data directory
      - GID=1000 # Set to the group of your vaultwarden data directory

      # Encryption (HIGHLY RECOMMENDED)
      - BACKUP_ENCRYPTION_KEY=your_very_secure_password_here
      # - PBKDF2_ITERATIONS=350000 # Optional: Lower for very slow CPUs (e.g., old Raspberry Pi), Bitwarden recommended 600,000 or more

      # Telegram Integration
      - TG_TOKEN=1234567890:ABCdefGHIjklMNOpqrsTUVwxyz
      - TG_CHAT_ID=123456789 # Can be user id, message to @userinfobot to get it

      # Optional Tweaks
      # - VWDUMP_DEBUG=true # Uncomment for detailed script logging
      # - DISABLE_WARNINGS=true # Uncomment to hide warnings for missing files
      # - DISABLE_TELEGRAM_UPLOAD=true # Uncomment to disable file uploads to Telegram

    volumes:
      - /path/to/vaultwarden/data:/data:ro
      - /path/to/backups:/backups
      - /etc/timezone:/etc/timezone:ro
      - /etc/localtime:/etc/localtime:ro
```

## ⚡ Manual Backups

There are two ways to run a manual backup, depending on your needs.

### Option 1: Triggering a Backup in a Running Container

If you are running the backup tool via `docker compose` and want to trigger an immediate backup without waiting for the cron schedule, this is the command to use. It executes the backup script inside your already-running container.

```bash
docker exec vaultwarden-backup /app/script.sh
```

### Option 2: Standalone One-Time Backup

This method is useful for testing your configuration, scripting, or running the backup from a different system. It starts a new, temporary container that runs the backup once and then removes itself.

Make sure to replace the placeholder values with your actual configuration.

```bash
docker run --rm \
  -v /path/to/vaultwarden/data:/data:ro \
  -v /path/to/backups:/backups \
  -e UID=1000 \
  -e GID=1000 \
  -e BACKUP_ENCRYPTION_KEY="your_very_secure_password_here" \
  -e TG_TOKEN="your_telegram_token" \
  -e TG_CHAT_ID="your_telegram_chat_id" \
  -e VWDUMP_DEBUG=true \
  your-image-name manual
```

## 📦 File Formats & Restoration

### Encrypted Backup (Recommended)

- **Format**: `vaultwarden_backup_YYYY-MM-DD_HH-MM-SS.tar.xz.enc`
- **To Restore**: This command will prompt you to enter your encryption password securely.

  > **Important**: If you have changed the `PBKDF2_ITERATIONS` variable, you **must** use that same number in the restore command below.

  ```bash
  # Create a directory for the restored files
  mkdir vaultwarden-restore

  # Decrypt and extract the XZ archive. You will be prompted for the password.
  # Replace 600000 with your custom value if you changed it.
  openssl enc -d -aes256 -salt -pbkdf2 -iter 600000 \
    -in /path/to/backup.tar.xz.enc | \
    tar xJ -C vaultwarden-restore
  ```

### Unencrypted Backup

- **Format**: `vaultwarden_backup_YYYY-MM-DD_HH-MM-SS.tar.xz`
- **To Restore**:
  ```bash
  tar -xJf /path/to/backup.tar.xz -C /path/to/restore/location
  ```

## 🕵️ Monitoring and Troubleshooting

### Logs

- Primary logs are available via `docker logs -f vaultwarden-backup`.
- For deep troubleshooting, set `VWDUMP_DEBUG=true` to see more logs.

## 🐳 Building the Image

### Simple Local Build

To build the image for your current system architecture:

```bash
docker build -t vaultwarden-backup .
```

## ⚙️ Environment Variables

### Basic Configuration

- `CRON_TIME`: Backup schedule in cron format (default: `0 */12 * * *`).
- `UID`: User ID for file ownership (default: `100`).
- `GID`: Group ID for file ownership (default: `100`).
- `DELETE_AFTER`: Days to keep local backups (default: `0` - no deletion).

### Encryption (Recommended)

- `BACKUP_ENCRYPTION_KEY`: Password for AES256 encryption. **Setting this enables encryption and Telegram file uploads.**
- `PBKDF2_ITERATIONS`: The number of iterations for the PBKDF2 key derivation. Higher numbers are more secure but slower. (Default: `600000`)

### Telegram Integration (Optional)

- `TG_TOKEN`: Your Telegram bot token.
- `TG_CHAT_ID`: The chat ID for notifications and uploads.
- `VWDUMP_DEBUG`: Set to `true` for verbose debug output from the script (default: `"false"`).
- `DISABLE_WARNINGS`: Set to `true` to suppress Telegram warnings for missing files (e.g., missing files and directories) (default: `"false"`).
- `DISABLE_TELEGRAM_UPLOAD`: Set to `true` to prevent the script from uploading backup files to Telegram. A detailed text notification will be sent instead. (Default: `"false"`)

> You can check default values of each variable in [Dockerfile](./Dockerfile)

---

## Acknowledgements

This project is a deeply modified [vaultwarden_backup](https://github.com/jmqm/vaultwarden_backup) script by [jmqm](https://github.com/jmqm)

## Disclaimer

This software is provided "as is" and without any warranty. The author and contributors are not liable for any damages or data loss that may arise from its use. You assume all responsibility and risk for the use of this software. Always test your backups.
