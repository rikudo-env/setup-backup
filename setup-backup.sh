#!/bin/bash

if ! sudo -n true 2>/dev/null; then
  echo "Ошибка: Требуются права sudo. Убедитесь, что пользователь имеет доступ к sudo и введите пароль." >&2
  exit 1
fi

CONFIG_FILE="/opt/backup/backup.conf"
DEFAULT_CONFIG=$(
  cat <<EOL
# Путь к файлу или папке для бэкапа (например, /home/su/dockerImg)
BACKUP_SRC="/home/su/backup"
# Протокол передачи: scp (простая копия по SSH) или rsync (синхронизация)
TRANSFER_PROTOCOL="scp"
# Адрес удаленного сервера: user@host:/path (например, tapochek@10.20.7.16:/home/tapochek)
BACKUP_DEST="su@192.168.168.0:/home/su"
# Расписание systemd-таймера (например, *-*-* 23:15:00 для ежедневного запуска в 23:15)
SCHEDULE="*-*-* 23:15:00"
# Тип сжатия: zip, tar.gz или none (без сжатия)
COMPRESSION="tar.gz"
# Ротация бэкапов: yes (удалять старые) или no (сохранять все)
ROTATION_ENABLED="yes"
# Максимальное количество бэкапов для хранения (0 = отключить ротацию)
MAX_BACKUPS="1"
# Формат имени архива (например, backup_%Y%m%d_%H%M%S для backup_20250908_231500)
ARCHIVE_NAME_FORMAT="backup_%Y%m%d_%H%M%S"
# Уведомления в Telegram: yes или no
TELEGRAM_NOTIFICATIONS="yes"
# Токен Telegram-бота (получите через @BotFather)
TELEGRAM_BOT_TOKEN="bot-token"
# ID чата для уведомлений (узнайте через @getmyid_bot)
TELEGRAM_CHAT_ID="chat_id"
# Путь к SSH-ключу (для root, использующего ключи пользователя su)
SSH_KEY="/home/su/.ssh/id_rsa"
EOL
)

DEPENDENCIES=("zip" "tar" "rsync" "curl")
for dep in "${DEPENDENCIES[@]}"; do
  if ! command -v "${dep%%-*}" &>/dev/null; then
    echo "Утилита $dep не установлена. Устанавливаю..." >&2
    sudo pacman -Sy --noconfirm "$dep" || {
      echo "Не удалось установить $dep. Установите вручную." >&2
      exit 1
    }
  fi
done

sudo mkdir -p /opt/backup
sudo chmod 755 /opt/backup
LOG_FILE="/opt/backup/backup.log"

if [[ ! -f "$CONFIG_FILE" ]]; then
  echo "Создаю конфигурационный файл: $CONFIG_FILE" >&2
  echo "$DEFAULT_CONFIG" | sudo tee "$CONFIG_FILE" >/dev/null
  sudo chmod 644 "$CONFIG_FILE"
  echo "Пожалуйста, отредактируйте $CONFIG_FILE и запустите скрипт снова."
  exit 0
fi

if [[ ! -r "$CONFIG_FILE" ]]; then
  echo "Ошибка: Конфигурационный файл $CONFIG_FILE не доступен для чтения" >&2
  exit 1
fi

source "$CONFIG_FILE" 2>/dev/null || {
  echo "Ошибка чтения конфигурационного файла $CONFIG_FILE" >&2
  exit 1
}

validate_config() {
  [[ -z "$BACKUP_SRC" ]] && {
    echo "Ошибка: BACKUP_SRC не указан в $CONFIG_FILE" >&2
    exit 1
  }
  [[ ! -e "$BACKUP_SRC" ]] && {
    echo "Ошибка: Путь $BACKUP_SRC не существует" >&2
    exit 1
  }
  [[ -z "$BACKUP_DEST" ]] && {
    echo "Ошибка: BACKUP_DEST не указан в $CONFIG_FILE" >&2
    exit 1
  }
  [[ -z "$SCHEDULE" ]] && {
    echo "Ошибка: SCHEDULE не указан в $CONFIG_FILE" >&2
    exit 1
  }
  if ! systemd-analyze calendar "$SCHEDULE" >/dev/null 2>&1; then
    echo "Ошибка: Неверный формат SCHEDULE в $CONFIG_FILE (пример: *-*-* 23:15:00)" >&2
    exit 1
  fi
  [[ -z "$COMPRESSION" || ! "$COMPRESSION" =~ ^(zip|tar.gz|none)$ ]] && {
    echo "Ошибка: Неверный COMPRESSION (zip, tar.gz, none) в $CONFIG_FILE" >&2
    exit 1
  }
  [[ -z "$TRANSFER_PROTOCOL" || ! "$TRANSFER_PROTOCOL" =~ ^(scp|rsync)$ ]] && {
    echo "Ошибка: Неверный TRANSFER_PROTOCOL (scp, rsync) в $CONFIG_FILE" >&2
    exit 1
  }
  [[ -z "$ROTATION_ENABLED" || ! "$ROTATION_ENABLED" =~ ^(yes|no)$ ]] && {
    echo "Ошибка: Неверный ROTATION_ENABLED (yes, no) в $CONFIG_FILE" >&2
    exit 1
  }
  [[ "$ROTATION_ENABLED" == "yes" && ! "$MAX_BACKUPS" =~ ^[0-9]+$ ]] && {
    echo "Ошибка: MAX_BACKUPS должен быть числом в $CONFIG_FILE" >&2
    exit 1
  }
  [[ "$TELEGRAM_NOTIFICATIONS" == "yes" && (-z "$TELEGRAM_BOT_TOKEN" || -z "$TELEGRAM_CHAT_ID") ]] && {
    echo "Ошибка: TELEGRAM_BOT_TOKEN или TELEGRAM_CHAT_ID не указаны в $CONFIG_FILE" >&2
    exit 1
  }
  [[ -z "$SSH_KEY" ]] && {
    echo "Ошибка: SSH_KEY не указан в $CONFIG_FILE" >&2
    exit 1
  }
  [[ ! -f "$SSH_KEY" ]] && {
    echo "Ошибка: SSH_KEY ($SSH_KEY) не существует" >&2
    exit 1
  }
  [[ "$(stat -c %a "$SSH_KEY")" != "600" ]] && {
    echo "Ошибка: Неверные права на $SSH_KEY, должны быть 600" >&2
    exit 1
  }
}

test_ssh_connection() {
  echo "Проверяю SSH-соединение с ключом $SSH_KEY к ${BACKUP_DEST%%:*}..." >&2
  sudo mkdir -p /root/.ssh
  sudo ssh-keyscan -H "${BACKUP_DEST%%:*}" 2>/dev/null | sudo tee -a /root/.ssh/known_hosts >/dev/null
  sudo chmod 600 /root/.ssh/known_hosts
  sudo ssh -i "$SSH_KEY" -o BatchMode=yes -o ConnectTimeout=5 "${BACKUP_DEST%%:*}" exit 2>/tmp/ssh_error.log
  if [[ $? -ne 0 ]]; then
    echo "Ошибка: Не удалось подключиться к $BACKUP_DEST с ключом $SSH_KEY." >&2
    echo "Детали ошибки:" >&2
    cat /tmp/ssh_error.log >&2
    echo "Проверьте SSH-ключи, права доступа, конфигурацию сервера и сетевую доступность." >&2
    exit 1
  fi
  rm -f /tmp/ssh_error.log
  sudo ssh -i "$SSH_KEY" "${BACKUP_DEST%%:*}" "mkdir -p ${BACKUP_DEST#*:} && chmod 700 ${BACKUP_DEST#*:}" 2>>$LOG_FILE
}

validate_config
test_ssh_connection

BACKUP_SCRIPT="/opt/backup/backup.sh"
sudo bash -c "cat > $BACKUP_SCRIPT" <<EOL
#!/bin/bash
LOG_FILE="$LOG_FILE"
BACKUP_SRC="$BACKUP_SRC"
BACKUP_DEST="$BACKUP_DEST"
TRANSFER_PROTOCOL="$TRANSFER_PROTOCOL"
COMPRESSION="$COMPRESSION"
ROTATION_ENABLED="$ROTATION_ENABLED"
MAX_BACKUPS="$MAX_BACKUPS"
ARCHIVE_NAME_FORMAT="$ARCHIVE_NAME_FORMAT"
TELEGRAM_NOTIFICATIONS="$TELEGRAM_NOTIFICATIONS"
TELEGRAM_BOT_TOKEN="$TELEGRAM_BOT_TOKEN"
TELEGRAM_CHAT_ID="$TELEGRAM_CHAT_ID"
SSH_KEY="$SSH_KEY"
TIMESTAMP=\$(date +%Y%m%d_%H%M%S)
ARCHIVE_NAME=\$(date +"$ARCHIVE_NAME_FORMAT")

echo "Начало бэкапа: \$TIMESTAMP" >> \$LOG_FILE

send_telegram() {
    local message=\$1
    if [[ "\$TELEGRAM_NOTIFICATIONS" == "yes" ]]; then
        curl -s -X POST "https://api.telegram.org/bot\$TELEGRAM_BOT_TOKEN/sendMessage" \
            -d chat_id="\$TELEGRAM_CHAT_ID" \
            -d text="\$message" >> \$LOG_FILE 2>&1 || {
            echo "Ошибка отправки уведомления в Telegram: \$TIMESTAMP" >> \$LOG_FILE
        }
    fi
}

BACKUP_FILE="/tmp/\$ARCHIVE_NAME"
case \$COMPRESSION in
    "zip")
        zip -r "\$BACKUP_FILE.zip" "\$BACKUP_SRC" >> \$LOG_FILE 2>&1
        BACKUP_FILE="\$BACKUP_FILE.zip"
        ;;
    "tar.gz")
        tar -czf "\$BACKUP_FILE.tar.gz" "\$BACKUP_SRC" >> \$LOG_FILE 2>&1
        BACKUP_FILE="\$BACKUP_FILE.tar.gz"
        ;;
    "none")
        BACKUP_FILE="\$BACKUP_SRC"
        ;;
esac

case \$TRANSFER_PROTOCOL in
    "scp")
        scp -i "\$SSH_KEY" "\$BACKUP_FILE" "\$BACKUP_DEST" >> \$LOG_FILE 2>&1
        ;;
    "rsync")
        rsync -az --progress -e "ssh -i \$SSH_KEY" "\$BACKUP_FILE" "\$BACKUP_DEST" >> \$LOG_FILE 2>&1
        ;;
esac
if [[ \$? -eq 0 ]]; then
    echo "Бэкап успешно отправлен: \$TIMESTAMP" >> \$LOG_FILE
    send_telegram "Бэкап \$TIMESTAMP успешно отправлен на \$BACKUP_DEST"
else
    echo "Ошибка отправки бэкапа: \$TIMESTAMP" >> \$LOG_FILE
    send_telegram "Ошибка бэкапа \$TIMESTAMP. Проверьте \$LOG_FILE"
    [[ "\$COMPRESSION" != "none" ]] && rm "\$BACKUP_FILE"
    exit 1
fi

if [[ "\$ROTATION_ENABLED" == "yes" ]]; then
    ssh -i "\$SSH_KEY" "${BACKUP_DEST%%:*}" "ls -t ${BACKUP_DEST#*:}/\$ARCHIVE_NAME* | tail -n +\$((MAX_BACKUPS + 1)) | xargs -I {} rm -f ${BACKUP_DEST#*:}/{}" >> \$LOG_FILE 2>&1
fi

[[ "\$COMPRESSION" != "none" ]] && rm "\$BACKUP_FILE"

echo "Бэкап завершен: \$TIMESTAMP" >> \$LOG_FILE
EOL

sudo chmod +x $BACKUP_SCRIPT

sudo rm -f /etc/cron.d/backup

SERVICE_FILE="/etc/systemd/system/backup.service"
sudo bash -c "cat > $SERVICE_FILE" <<EOL
[Unit]
Description=Backup Service
After=network.target

[Service]
ExecStart=$BACKUP_SCRIPT
Type=oneshot
User=root
EOL

TIMER_FILE="/etc/systemd/system/backup.timer"
sudo bash -c "cat > $TIMER_FILE" <<EOL
[Unit]
Description=Run Backup Service on schedule

[Timer]
OnCalendar=$SCHEDULE
Persistent=true

[Install]
WantedBy=timers.target
EOL

sudo systemctl daemon-reload
sudo systemctl enable backup.timer
sudo systemctl start backup.timer

echo "Бэкап успешно настроен!"
echo "Конфигурация: $CONFIG_FILE"
echo "Скрипт: $BACKUP_SCRIPT"
echo "Логи: $LOG_FILE"
echo "Таймер: backup.timer (запускается по расписанию: $SCHEDULE)"
echo "Сервис: backup.service"
echo "Проверьте статус: sudo systemctl status backup.timer"
echo "Для уведомлений в Telegram настройте TELEGRAM_BOT_TOKEN и TELEGRAM_CHAT_ID в $CONFIG_FILE"
echo "Для изменения времени бэкапа отредактируйте SCHEDULE в $CONFIG_FILE (формат: *-*-* HH:MM:SS)"
