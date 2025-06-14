#!/bin/sh

# --------------- [ PREREQUISITES ] ---------------

if [ -n "$BACKUP_ENCRYPTION_KEY" ]; then
    EXTENSION="tar.xz.enc"
else
    EXTENSION="tar.xz"
fi

TIMESTAMP=$(date +"%F_%H-%M-%S")
BACKUP_FILENAME="vaultwarden_backup_${TIMESTAMP}"

# New line defenition
NL='
'

# Error statuses:
# 0 = Success
# 1 = Network/API error
# 2 = File too large

send_telegram_message() {
    local message="$1"
    if [ -n "$TG_TOKEN" ] && [ -n "$TG_CHAT_ID" ]; then
        if [ "$VWDUMP_DEBUG" = "true" ]; then
            echo "[DEBUG] Sending Telegram message..."
        fi
        
        # Add timeout and retry logic
        local max_retries=3
        local retry_count=0
        
        while [ $retry_count -lt $max_retries ]; do
            response=$(curl -S -s --max-time 30 --connect-timeout 10 -X POST "https://api.telegram.org/bot${TG_TOKEN}/sendMessage" \
                -d "chat_id=${TG_CHAT_ID}" \
                -d "text=${message}" \
                -d "parse_mode=HTML" 2>&1)
            
            # Check if curl command succeeded
            if [ $? -eq 0 ] && echo "$response" | grep -q '"ok":true'; then
                if [ "$VWDUMP_DEBUG" = "true" ]; then echo "[DEBUG] Telegram message sent successfully"; fi
                return 0
            else
                echo "[ERROR] Telegram message send failed. Details: $response" >&2
            fi
            
            retry_count=$((retry_count + 1))
            if [ $retry_count -lt $max_retries ]; then
                echo "[INFO] Retrying Telegram message send (attempt $((retry_count + 1))/$max_retries)..." >&2
                sleep 5
            fi
        done
        
        echo "[ERROR] Failed to send Telegram message after $max_retries attempts" >&2
        return 1
    fi
    return 1
}

send_telegram_file() {
    local file_path="$1"
    local caption="$2"
    if [ -n "$TG_TOKEN" ] && [ -n "$TG_CHAT_ID" ] && [ -f "$file_path" ]; then
        # Check file size, Telegram limit is 50MB
        # See: https://core.telegram.org/bots/api#sending-files
        file_size=$(stat -c%s "$file_path" 2>/dev/null || stat -f%z "$file_path" 2>/dev/null)
        if [ "$file_size" -ge 52428800 ]; then  # 50MB in bytes
            echo "[ERROR] File too large for Telegram ($(echo "$file_size" | awk '{print int($1/1024/1024)}')MB)" >&2
            return 2
        fi
        
        echo "[INFO] Uploading file to Telegram ($(echo "$file_size" | awk '{print int($1/1024)}')KB)..."
        
        # Add timeout and retry logic for file uploads
        local max_retries=2
        local retry_count=0
        
        while [ $retry_count -lt $max_retries ]; do
            response=$(curl -S -s --max-time 120 --connect-timeout 30 -X POST "https://api.telegram.org/bot${TG_TOKEN}/sendDocument" \
                -F "chat_id=${TG_CHAT_ID}" \
                -F "document=@${file_path}" \
                -F "caption=${caption}" \
                -F "parse_mode=HTML" 2>&1)

            # Check if curl command succeeded
            if [ $? -eq 0 ] && echo "$response" | grep -q '"ok":true'; then
                if [ "$VWDUMP_DEBUG" = "true" ]; then echo "[DEBUG] Telegram file upload successful"; fi
                return 0
            else
                echo "[ERROR] Telegram file upload failed. Details: $response" >&2
                if echo "$response" | grep -q "Request Entity Too Large\|File too large"; then return 2; fi
            fi
            
            retry_count=$((retry_count + 1))
            if [ $retry_count -lt $max_retries ]; then
                echo "[INFO] Retrying Telegram file upload (attempt $((retry_count + 1))/$max_retries)..." >&2
                sleep 10
            fi
        done
        
        echo "[ERROR] Failed to upload file to Telegram after $max_retries attempts" >&2
        return 1
    fi
    return 1
}

# ------------------ [ PRINT CONFIGURATION ] ------------------

if [ "$VWDUMP_DEBUG" = "true" ]; then
    echo "[DEBUG] ----- VWDUMP CONFIGURATION -----"
    echo "[DEBUG]   Cron Schedule: ${CRON_TIME}"
    echo "[DEBUG]   User ID (UID): ${UID}"
    echo "[DEBUG]   Group ID (GID): ${GID}"
    echo "[DEBUG]   Delete After: ${DELETE_AFTER} days"
    
    if [ -n "$BACKUP_ENCRYPTION_KEY" ]; then
        echo "[DEBUG]   Encryption: Enabled"
        echo "[DEBUG]   PBKDF2 Iterations: ${PBKDF2_ITERATIONS}"
    else
        echo "[DEBUG]   Encryption: Disabled"
    fi
    
    if [ -n "$TG_TOKEN" ] && [ -n "$TG_CHAT_ID" ]; then
        echo "[DEBUG]   Telegram Notifications: Enabled"
        echo "[DEBUG]   Telegram Chat ID: ${TG_CHAT_ID}"
        echo "[DEBUG]   Telegram Token: [set, masked]"
        echo "[DEBUG]   Disable Warnings: ${DISABLE_WARNINGS}"
        echo "[DEBUG]   Disable Uploads: ${DISABLE_TELEGRAM_UPLOAD}"
    else
        echo "[DEBUG]   Telegram Notifications: Disabled"
    fi
    echo "[DEBUG] --------------------------------"
fi

# ------------------ [ BACKUP ] ------------------

cd /data || exit 1  # Exit with error if opening vw data file fails

# Ensure backup directory exists
mkdir -p /backups
BACKUP_LOCATION="/backups/${BACKUP_FILENAME}.${EXTENSION}"

BACKUP_ITEMS="db.sqlite3 rsa_key* config.json attachments sends"
WARNING_STATUS=""
FILES_TO_BACKUP=""
WARNING=""

# Verify which items are available to be backed up
for ITEM in $BACKUP_ITEMS; do
    if [ -e "$ITEM" ] || [ -d "$ITEM" ]; then
        FILES_TO_BACKUP="$FILES_TO_BACKUP $ITEM"
    else # if an item is missing, raise warning
        WARNING="$WARNING $ITEM"
    fi
done

# Print and set warnings
if [ -n "$WARNING" ]; then
    echo "[WARNING] The following expected files/directories are missing:$WARNING" >&2
    if [ "$DISABLE_WARNINGS" != "true" ]; then
        WARNING_STATUS="⚠️ Missing files:$WARNING"
    fi
fi

# Exit if there are no files to back up
if [ -z "$FILES_TO_BACKUP" ]; then
    OUTPUT="No files to back up"
    ERROR_MSG="<b>⚠️ Vaultwarden Backup Warning</b>${NL}No files found to back up"
    send_telegram_message "$ERROR_MSG"
    echo "[$(date +"%F %r")] ${OUTPUT}."
    exit 0
fi

# --- [ Backup Preparation ] ---

echo "[INFO] Creating backup..."

# Prepare a temporary directory for temp backup files
if [ "$VWDUMP_DEBUG" = "true" ]; then
    echo "[DEBUG] Preparing a backup temp directory"
fi
TEMP_DIR="/tmp/vw_backup_$$"
mkdir -p "$TEMP_DIR"

# Always use safe .backup for sqlite3 if it exists
if [ -f "db.sqlite3" ]; then
    if [ "$VWDUMP_DEBUG" = "true" ]; then
        echo "[DEBUG] Creating SQLite backup..."
    fi
    sqlite3 db.sqlite3 ".backup '$TEMP_DIR/db.sqlite3'"
fi

# Copy all other files to the temp directory, preserving permissions
for ITEM in $FILES_TO_BACKUP; do
    if [ "$ITEM" != "db.sqlite3" ]; then
        cp -a "$ITEM" "$TEMP_DIR/"
    fi
done

# --- [ Archive Creation ] ---

# Create tar archive from temp directory
if [ -n "$BACKUP_ENCRYPTION_KEY" ]; then
    # Create encrypted backup
    if [ "$VWDUMP_DEBUG" = "true" ]; then
        echo "[DEBUG] Creating archive..."
    fi
    tar -Jcf - -C "$TEMP_DIR" . | openssl enc -e -aes256 -salt -pbkdf2 -iter "$PBKDF2_ITERATIONS" -pass pass:"$BACKUP_ENCRYPTION_KEY" -out "$BACKUP_LOCATION"
    BACKUP_SUCCESS=$?
else
    # Create unencrypted backup
    if [ "$VWDUMP_DEBUG" = "true" ]; then
        echo "[DEBUG] Creating archive..."
    fi
    tar -Jcf "$BACKUP_LOCATION" -C "$TEMP_DIR" .
    BACKUP_SUCCESS=$?
fi

# --- [ Cleanup ] ---

echo "[INFO] Cleaning up..."
rm -rf "$TEMP_DIR"

# --- [ Build clean up message ] ---

CLEANUP_STATUS_MSG=""
if [ -n "$DELETE_AFTER" ] && [ "$DELETE_AFTER" -gt 0 ]; then
    cd /backups
    TO_DELETE=$(find . -iname "*.${EXTENSION}" -type f -mtime +$DELETE_AFTER)
    DELETED_COUNT=0
    if [ -n "$TO_DELETE" ]; then DELETED_COUNT=$(echo "$TO_DELETE" | wc -l); fi

    if [ "$DELETED_COUNT" -gt 0 ]; then
        if [ "$DELETED_COUNT" -eq 1 ]; then
            archive_word="archive"
            file_word="file"
        else
            archive_word="archives"
            file_word="files"
        fi
        echo "$TO_DELETE" | xargs rm -f
        OUTPUT_SUFFIX=", deleted ${DELETED_COUNT} ${archive_word} older than ${DELETE_AFTER} days"
        CLEANUP_STATUS_MSG="🗑️ Deleted ${DELETED_COUNT} old backup ${file_word} (older than ${DELETE_AFTER} days)."
    else
        OUTPUT_SUFFIX=", no archives older than ${DELETE_AFTER} days to delete"
    fi
fi

# --- [ Telegram Notification ] ---

if [ $BACKUP_SUCCESS -eq 0 ]; then
    file_size=$(stat -c%s "$BACKUP_LOCATION" 2>/dev/null || stat -f%z "$file_path" 2>/dev/null)
    file_size_kb=$(echo "$file_size" | awk '{print int($1/1024)}')
    if [ "$file_size_kb" -ge 1024 ]; then
        size_display="$(echo "$file_size_kb" | awk '{print int($1/1024)}')MB"
    else
        size_display="${file_size_kb}KB"
    fi

    if [ -n "$BACKUP_ENCRYPTION_KEY" ]; then
        # Encrypted backup notification logic
        decrypt_cmd="openssl enc -d -aes256 -salt -pbkdf2 -iter ${PBKDF2_ITERATIONS} -in ${BACKUP_FILENAME}.${EXTENSION} | tar xJ -C restore-dir"
        file_caption="✅ <b>Vaultwarden Backup Complete</b>${NL}${NL}📁 File: <code>${BACKUP_FILENAME}.${EXTENSION}</code>${NL}📏 Size: ${size_display}"
        if [ -n "$WARNING_STATUS" ]; then file_caption="${file_caption}${NL}${WARNING_STATUS}"; fi
        if [ -n "$CLEANUP_STATUS_MSG" ]; then file_caption="${file_caption}${NL}${NL}${CLEANUP_STATUS_MSG}"; fi
        file_caption="${file_caption}${NL}${NL}🔓 <b>Decrypt with:</b>${NL}<code>${decrypt_cmd}</code>"
        
        if [ "$DISABLE_TELEGRAM_UPLOAD" = "true" ]; then
            echo "[INFO] Telegram file upload is disabled by user setting."
            upload_result=3 # Use a unique code for "disabled by user"
        else
            send_telegram_file "$BACKUP_LOCATION" "$file_caption"
            upload_result=$?
        fi
        
        if [ $upload_result -eq 0 ]; then
            OUTPUT="New backup created and sent to Telegram"
        else
            # Build the fallback text-only notification
            TELEGRAM_MSG="<b>✅ Vaultwarden Backup Complete</b>${NL}"
            TELEGRAM_MSG="${TELEGRAM_MSG}${NL}📁 File: <code>${BACKUP_FILENAME}.${EXTENSION}</code>"
            TELEGRAM_MSG="${TELEGRAM_MSG}${NL}📏 Size: ${size_display}"
            
            if [ $upload_result -eq 2 ]; then
                TELEGRAM_MSG="${TELEGRAM_MSG}${NL}⚠️ <b>File too large for Telegram</b>, saved locally only."
                OUTPUT="New backup created (too large for Telegram)"
            elif [ $upload_result -eq 3 ]; then
                TELEGRAM_MSG="${TELEGRAM_MSG}${NL}ℹ️ <b>File upload disabled by user</b>, saved locally only."
                OUTPUT="New backup created (upload disabled by user)"
            else
                TELEGRAM_MSG="${TELEGRAM_MSG}${NL}❌ <b>File upload failed</b>, saved locally only."
                OUTPUT="New backup created (Telegram upload failed)"
            fi
            
            if [ -n "$WARNING_STATUS" ]; then TELEGRAM_MSG="${TELEGRAM_MSG}${NL}${WARNING_STATUS}"; fi
            if [ -n "$CLEANUP_STATUS_MSG" ]; then TELEGRAM_MSG="${TELEGRAM_MSG}${NL}${NL}${CLEANUP_STATUS_MSG}"; fi
            TELEGRAM_MSG="${TELEGRAM_MSG}${NL}${NL}🔓 <b>Decrypt with:</b>${NL}<code>${decrypt_cmd}</code>"
            send_telegram_message "$TELEGRAM_MSG"
        fi
    else
        # Unencrypted backup notification logic
        TELEGRAM_MSG="<b>✅ Vaultwarden Backup Complete</b>"
        TELEGRAM_MSG="${TELEGRAM_MSG}${NL}📁 File: <code>${BACKUP_FILENAME}.${EXTENSION}</code>"
        TELEGRAM_MSG="${TELEGRAM_MSG}${NL}📏 Size: ${size_display}"
        if [ -n "$WARNING_STATUS" ]; then TELEGRAM_MSG="${TELEGRAM_MSG}${NL}${WARNING_STATUS}"; fi
        if [ -n "$CLEANUP_STATUS_MSG" ]; then TELEGRAM_MSG="${TELEGRAM_MSG}${NL}${NL}${CLEANUP_STATUS_MSG}"; fi

        if send_telegram_message "$TELEGRAM_MSG"; then
            OUTPUT="New backup created (notification sent)"
        else
            OUTPUT="New backup created (notification failed)"
        fi
    fi
else
    OUTPUT="Failed to create backup"
    ERROR_MSG="<b>❌ Vaultwarden Backup Failed</b>${NL}Could not create archive: ${BACKUP_FILENAME}"
    if [ -n "$WARNING_STATUS" ]; then ERROR_MSG="${ERROR_MSG}${NL}${WARNING_STATUS}"; fi
    send_telegram_message "$ERROR_MSG"
fi

# ------------------ [ EXIT ] ------------------

# Append the cleanup message to the final console log message
echo "[$(date +"%F %r")] ${OUTPUT}${OUTPUT_SUFFIX}."