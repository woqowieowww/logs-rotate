set -euo pipefail

ARCHIVE_BASE="/var/log/archive"
ARCHIVE_DIR="${ARCHIVE_BASE}/$(date +%Y-%m-%d_%H-%M-%S)"
LOG_DIR="/var/log"
SERVICE_NAME="rsyslog"

# Кастомные коды ошибок
ERR_ROOT=1
ERR_LOG_DIR=2
ERR_ARCH_DIR=3
ERR_MOVE=4
ERR_EMPTY_ARCH=5
ERR_LOCKED=6
ERR_GUI_ACCESS=7
ERR_CHOWN=8

# Функция диагностики
debug_info() {
    echo "=== Диагностическая информация ==="
    echo "Дата: $(date)"
    echo "Пользователь: $(whoami)"
    echo "Диск свободно: $(df -h ${ARCHIVE_BASE})"
    echo "Процессы с открытыми файлами:"
    lsof +D "${LOG_DIR}"
}

handle_error() {
    echo "ОШИБКА [$1] в строке $2: $3" >&2
    debug_info
    exit $1
}

trap 'handle_error $? $LINENO "$BASH_COMMAND"' ERR

# Проверка предварительных условий
check_prerequisites() {
    # Права root
    [[ $EUID -ne 0 ]] && handle_error $ERR_ROOT $LINENO "Требуются права root"

    # Существование исходной директории
    [[ -d "$LOG_DIR" ]] || handle_error $ERR_LOG_DIR $LINENO "Директория логов не существует"

    # Права на запись
    [[ -w "$LOG_DIR" ]] || handle_error $ERR_LOG_DIR $LINENO "Нет прав на запись в ${LOG_DIR}"
}

# Создание архивной директории
create_archive_dir() {
    mkdir -p "$ARCHIVE_DIR" || handle_error $ERR_ARCH_DIR $LINENO "Ошибка создания директории"
    chmod 0750 "$ARCHIVE_DIR" || handle_error $ERR_CHOWN $LINENO "Ошибка установки прав на архив"
    chown root:adm "$ARCHIVE_DIR" || handle_error $ERR_CHOWN $LINENO "Ошибка изменения владельца архива"
}

# Основная логика перемещения
move_files() {
    local files=()
    echo "Поиск файлов в ${LOG_DIR}..."

    # Поиск файлов с обработкой ошибок
    while IFS= read -r -d '' file; do
        # Игнорируем файлы в поддиректориях /var/log/archive и /var/log/journal
        if [[ "$file" == "${ARCHIVE_BASE}"* || "$file" == "/var/log/journal"* ]]; then
            echo "Пропускаем системный файл или файл из архива: $file"
            continue
        fi

        files+=("$file")
        echo "Найден файл: $file"
    done < <(find "$LOG_DIR" -maxdepth 1 -type f -print0 2>/dev/null)

    # Если файлов нет, завершаем выполнение
    if [[ ${#files[@]} -eq 0 ]]; then
        echo "Нет файлов для архивации."
        return 0
    fi

    # Попытка перемещения с повторением
    for file in "${files[@]}"; do
        for attempt in {1..3}; do
            if mv -fv "$file" "$ARCHIVE_DIR/"; then
                echo "Успешно перемещен: $(basename "$file")"
                break
            else
                echo "Попытка $attempt: ошибка перемещения $(basename "$file")" >&2
                [[ $attempt -eq 3 ]] && handle_error $ERR_MOVE $LINENO "Файл заблокирован: $file"
                sleep 1
            fi
        done
    done

    # Возвращаем список перемещенных файлов
    echo "${files[@]}"
}

# Обеспечение доступа через GUI
set_gui_permissions() {
    # Устанавливаем права доступа для группы adm
    find "$ARCHIVE_DIR" -type f -exec chmod 640 {} \;
    find "$ARCHIVE_DIR" -type d -exec chmod 750 {} \;
    chown -R root:adm "$ARCHIVE_DIR" || handle_error $ERR_GUI_ACCESS $LINENO "Ошибка настройки прав для GUI"
}

# Проверка результатов
verify_operation() {
    local moved_count=$(find "$ARCHIVE_DIR" -type f | wc -l)

    echo "Успешно перемещено файлов: $moved_count"
    echo "Размер архива: $(du -sh "$ARCHIVE_DIR")"
}

main() {
    check_prerequisites
    create_archive_dir

    # Перемещение файлов
    moved_files=$(move_files)
    if [[ -z "$moved_files" ]]; then
        echo "Архивация не требуется. Нет новых файлов для перемещения."
        return 0
    fi

    set_gui_permissions
    verify_operation

    # Очистка логов
    find "$LOG_DIR" -maxdepth 1 -type f -exec truncate -s 0 {} \;

    # Перезапуск сервиса
    if systemctl is-active "$SERVICE_NAME"; then
        systemctl restart "$SERVICE_NAME" || echo "Предупреждение: не удалось перезапустить $SERVICE_NAME" >&2
    fi

    debug_info
}

main
